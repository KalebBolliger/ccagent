--[[ claude/session.lua --------------------------------------------------
  A conversation with Claude about what this turtle should do next.

  The session is what makes "no, do it the other way round" cheap: the
  previous program is still in the history, so a follow-up is a diff in the
  model's head rather than a fresh description of the whole task. It also
  owns the repair loop -- a program that throws gets handed back with its
  error and the output that preceded it, which fixes most failures in one
  extra round trip.

  History is trimmed from the front, never the back, and never drops the
  system block, so the cached prefix stays valid.
--------------------------------------------------------------------------]]

local util     = require("agent.util")
local client   = require("claude.client")
local prompt   = require("claude.prompt")
local extract  = require("claude.extract")
local executor = require("claude.executor")
local lint     = require("agent.lint")

local session = {}
session.__index = session

--- Keep at most this many *exchanges* (user+assistant pairs) in history.
session.maxTurns = 8

--- `agent` only has to answer two things: situation() and env(). The
--- standalone controller passes the real agent; the host passes a proxy
--- that reports a remote turtle's state and refuses to execute locally.
--- `runner` is how a program gets executed -- locally by default, over
--- rednet in host mode. The repair loop works either way.
function session.new(cfg, agent, runner, opts)
  return setmetatable({
    cfg      = cfg,
    agent    = agent,
    runner   = runner,
    messages = {},
    system   = nil,
    lastCode = nil,
    lastResult = nil,
    fleet    = opts and opts.fleet or false,
    stats    = { requests = 0, inTokens = 0, outTokens = 0,
                 cacheRead = 0, cacheWrite = 0 },
  }, session)
end

function session:buildSystem(force)
  -- Registering or exposing a routine changes the cached prefix, so the
  -- listing is fingerprinted and the prompt rebuilt only when it actually
  -- moved. That costs one cache write, then rides free again.
  local okLib, lib = pcall(require, "agent.lib")
  local version = okLib and lib.listingVersion() or ""
  if self.system and not force and version == self.listingVersion then
    return self.system
  end
  local blocks = prompt.system({
    extra = self.cfg.operatorNotes,
    cache = self.cfg.cache ~= false,
    fleet = self.fleet,
  })
  self.system = blocks
  self.listingVersion = version
  return blocks
end

local function trim(self)
  -- Drop whole exchanges from the oldest end.
  while #self.messages > self.maxTurns * 2 do
    table.remove(self.messages, 1)
    if self.messages[1] and self.messages[1].role == "assistant" then
      table.remove(self.messages, 1)
    end
  end
end

function session:push(role, text)
  self.messages[#self.messages + 1] = { role = role, content = text }
  trim(self)
end

function session:reset()
  self.messages = {}
  self.lastCode, self.lastResult = nil, nil
end

local function recordUsage(self, usage)
  if not usage then return end
  self.stats.requests  = self.stats.requests + 1
  self.stats.inTokens  = self.stats.inTokens + (usage.input_tokens or 0)
  self.stats.outTokens = self.stats.outTokens + (usage.output_tokens or 0)
  self.stats.cacheRead = self.stats.cacheRead + (usage.cache_read_input_tokens or 0)
  self.stats.cacheWrite = self.stats.cacheWrite + (usage.cache_creation_input_tokens or 0)
end

--- One round trip: send the request, get a program back.
--- Returns code, meta or nil, err.
function session:ask(text, opts)
  opts = opts or {}
  local content = text
  if opts.withState ~= false then
    content = prompt.situation(self.agent) .. "\n\nREQUEST\n" .. text
  end
  if opts.reusable then content = content .. "\n" .. prompt.REUSABLE end
  self:push("user", content)

  local resp, err = client.message(self.cfg, {
    system   = self:buildSystem(),
    messages = self.messages,
  })
  if not resp then
    -- Do not leave a dangling user turn; the next attempt would double up.
    table.remove(self.messages)
    return nil, err
  end
  recordUsage(self, resp.usage)
  self:push("assistant", resp.text)

  local code, note = extract.code(resp.text)
  if not code then
    if resp.truncated then
      return nil, "the reply was cut off mid-program -- try a smaller job"
    end
    return nil, "could not read a program from the reply: " .. tostring(note)
  end
  local okSyntax, syntaxErr = extract.check(code)
  if not okSyntax then
    return nil, "the generated program has a syntax error: " .. tostring(syntaxErr),
           { code = code, usage = resp.usage }
  end
  self.lastCode = code
  return code, { note = note, usage = resp.usage, reply = resp.text,
                 thinking = resp.thinking }
end

--- How many times a program may be sent back for naming something that
--- does not exist. One: the answer is in the system prompt's own API
--- listing, so a model that gets it wrong twice is not going to get it
--- right on the third pass, and each attempt is a whole request.
session.staticRepairs = 1

--- The global surface of the machine that will run the program: the
--- names, and the tables behind them.
---
--- nil when it cannot be known from here, which is the host's case by
--- design -- its agent proxy raises on env(), because the program runs
--- on a worker whose capabilities, and therefore whose sandbox, are not
--- the host's to describe. A fleet therefore gets no static gate rather
--- than a gate answering about the wrong machine.
local function surface(self)
  local okEnv, apiEnv = pcall(self.agent.env)
  if not okEnv or type(apiEnv) ~= "table" then return nil end
  local okNames, names = pcall(executor.globalNames, apiEnv)
  if not okNames then return nil end
  local _, tables = pcall(executor.globalTables, apiEnv)
  return names, tables
end

--- Findings that are facts rather than predictions: a bare name, or a
--- field on a real namespace, that is not there. Lua resolves both at
--- the moment the line runs, so the program starts, works, changes the
--- world and only then dies -- which is why this is worth a round trip
--- before the first move rather than a repair after thirty blocks.
---
--- Everything else the lint reports is a judgement about style or about
--- a contract, and is not grounds for refusing to run anything.
function session:staticErrors(code)
  local names, tables = surface(self)
  if not names then return {} end
  local ok, findings = pcall(lint.check, code, names, tables)
  if not ok then return {} end
  local out = {}
  for _, f in ipairs(findings) do
    if f.kind == "undefined-global" or f.kind == "unknown-member" then
      out[#out + 1] = f
    end
  end
  return out
end

--- Execute a program wherever this session runs programs.
function session:execute(code, opts)
  if self.runner then return self.runner(code, opts) end
  return executor.run(code, self.agent.env(), opts)
end

--- Ask, run, and repair on failure. This is what the controllers call.
---   opts.onEvent(kind, text, extra)  -- "status" | "code" | "output" | "warn"
---   opts.maxRepairs                  -- default cfg.maxRepairs or 2
---   opts.dryRun                      -- fetch and show the code, do not run
function session:handle(text, opts)
  opts = opts or {}
  local emit = opts.onEvent or function() end
  local maxRepairs = opts.maxRepairs or self.cfg.maxRepairs or 2

  emit("status", opts.reusable and "asking Claude (reusable)..." or "asking Claude...")
  local code, meta = self:ask(text, { reusable = opts.reusable })
  if not code then
    emit("warn", tostring(meta))
    return { ok = false, error = meta }
  end
  if meta.note then emit("warn", meta.note) end
  if meta.usage then emit("usage", client.usageLine(meta.usage), meta.usage) end
  emit("code", code)

  if opts.dryRun then
    return { ok = true, code = code, dryRun = true }
  end

  -- Before anything moves. extract.check already refuses a program that
  -- will not parse; this refuses one that parses and then cannot work.
  local static = self:staticErrors(code)
  local staticTries = 0
  while #static > 0 do
    for n, f in ipairs(static) do
      if n > 3 then                       -- 39 columns, no scrollback
        emit("warn", ("+%d more"):format(#static - 3))
        break
      end
      emit("warn", ("line %s: %s"):format(tostring(f.line or "?"),
                                          tostring(f.detail)))
    end
    if staticTries >= (self.cfg.staticRepairs or session.staticRepairs) then
      -- Not run, and said plainly. Running it anyway would change the
      -- world up to the bad line for nothing.
      local why = ("names that do not exist: %s"):format(
        tostring(static[1] and static[1].detail or "?"))
      emit("warn", "not run")
      return { ok = false, error = why, code = code, notRun = true }
    end
    staticTries = staticTries + 1
    emit("status", "that names something missing; asking again...")
    local fixCode, fixMeta = self:ask(prompt.missing(static),
                                      { withState = false })
    if not fixCode then
      emit("warn", "repair request failed: " .. tostring(fixMeta))
      return { ok = false, error = tostring(fixMeta), code = code }
    end
    if fixMeta.usage then emit("usage", client.usageLine(fixMeta.usage), fixMeta.usage) end
    code = fixCode
    emit("code", code)
    static = self:staticErrors(code)
  end

  local attempt, result = 0, nil
  while true do
    attempt = attempt + 1
    emit("status", attempt == 1 and "running..." or ("running (repair %d)..."):format(attempt - 1))

    result = self:execute(code, {
      name = opts.name or "job",
      onOutput = function(kind, t, extra) emit("output", t, { kind = kind, extra = extra }) end,
      allowKeyAbort = opts.allowKeyAbort,
    })
    result.code = code
    self.lastResult = result

    if result.ok or result.aborted then break end
    if attempt > maxRepairs then break end

    emit("warn", ("failed: %s"):format(util.clip(result.error or "?", 300)))
    emit("status", "sending the error back for a fix...")

    local fixCode, fixMeta = self:ask(
      prompt.failure(result.error, util.clip(result.output or "", 800)),
      { withState = false })
    if not fixCode then
      emit("warn", "repair request failed: " .. tostring(fixMeta))
      break
    end
    if fixMeta.usage then emit("usage", client.usageLine(fixMeta.usage), fixMeta.usage) end
    code = fixCode
    emit("code", code)
  end

  return result
end

--- Promote a saved one-off into a routine. One API call, and it is the
--- price of not having decided upfront -- which is often the honest
--- situation, since you rarely know a program is worth keeping until you
--- have watched it work.
--- Returns newSource or nil, err.
function session:retrofit(name, source, findingsText, why)
  local text = prompt.retrofit(name, source, findingsText, why)
  local code, meta = self:ask(text, { withState = false })
  if not code then return nil, meta end
  return code, meta
end

--- Rewrite a saved program against the library as it stands now. One
--- request, and the system prompt it rides on already carries the current
--- API listing, so this is cheap.
--- Returns newSource or nil, err.
function session:revise(name, source, note, findingsText)
  local text = prompt.revise(name, source, note, findingsText)
  local code, meta = self:ask(text, { withState = false })
  if not code then return nil, meta end
  return code, meta
end

--- Re-run the last program without spending a request.
function session:rerun(opts)
  opts = opts or {}
  if not self.lastCode then return { ok = false, error = "nothing to re-run" } end
  local emit = opts.onEvent or function() end
  emit("status", "re-running the last program...")
  local result = self:execute(self.lastCode, {
    name = opts.name or "job",
    onOutput = function(kind, t, extra) emit("output", t, { kind = kind, extra = extra }) end,
  })
  result.code = self.lastCode
  self.lastResult = result
  return result
end

function session:statsLine()
  local s = self.stats
  return ("%d requests | in %d out %d | cache read %d write %d")
    :format(s.requests, s.inTokens, s.outTokens, s.cacheRead, s.cacheWrite)
end

return session
