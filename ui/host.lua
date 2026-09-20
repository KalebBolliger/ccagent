--[[ ui/host.lua --------------------------------------------------------
  The fleet front-end. Runs on a stationary computer that holds the API key.

      /ccagent host

  Workers announce themselves; you address one (or all of them) and the host
  does the thinking, then ships the resulting program out over rednet.

  Why bother, when ui/controller already works: one key instead of N, one
  place to update the library, and a separate conversation per turtle so a
  follow-up like "now do the same one chunk east" lands on the right one.

      > @3 mine out the room below you
      > all  come home and unload
      > /use 3
      > dig a 2x2 shaft down to y=-50
--------------------------------------------------------------------------]]

-- The tree lives at /ccagent (agent/lib.lua and claude/config.lua say so
-- too). CC also searches the running program's own directory, which is
-- why a wrong prefix here still works from /ccagent/install.lua and
-- fails from /ccagent/ui/ one level down.
package.path = "/ccagent/?.lua;/ccagent/?/init.lua;" .. (package.path or "")

local util     = require("agent.util")
local agent    = require("agent.init")
local caps     = require("agent.caps")
local registry = require("agent.registry")
local config   = require("claude.config")
local session  = require("claude.session")
local console  = require("ui.console")
local jobs     = require("ui.jobs")
local net      = require("ui.net")

local M = {}

local cfg, running = nil, true
local workers = {}     -- id -> { label, caps, situation, session, lastSeen }
local target  = nil    -- currently addressed worker id
local jobSeq  = 0

--------------------------------------------------------------- plumbing ---

local function events()
  return function(kind, text, extra)
    if kind == "status" then console.status(text)
    elseif kind == "code" then console.code(text)
    elseif kind == "warn" then console.warn(text)
    elseif kind == "usage" then console.dim(text)
    elseif kind == "output" then
      local k = extra and extra.kind
      if k == "warn" then console.warn(text)
      elseif k == "report" then console.head("= " .. text)
      else console.say(text) end
    else console.info(text) end
  end
end

--- Ask a worker for fresh state before we spend a request describing it.
local function poll(id, timeout)
  net.send(id, { t = "poll" }, cfg.protocol)
  local msg = net.await(id, { "state", "hello" }, timeout or 4, cfg.protocol)
  if msg then
    local w = workers[id] or {}
    w.caps, w.situation, w.label = msg.caps or w.caps, msg.situation, msg.label or w.label
    w.lastSeen = os.clock()
    workers[id] = w
    return w
  end
  return workers[id]
end

--- Send a program to a worker and pump its output until it reports back.
-- While a job is in flight the background listener must not also consume
-- and re-print that worker's traffic: rednet events are delivered to every
-- coroutine, so without this you see every line twice.
local busyWith = {}

local function remoteRun(id)
  return function(code, opts)
    jobSeq = jobSeq + 1
    local jobId = ("j%d"):format(jobSeq)
    busyWith[id] = true
    net.send(id, { t = "run", job = jobId, src = code }, cfg.protocol)

    local deadline = os.clock() + (cfg.jobTimeout or 900)
    while os.clock() < deadline do
      local from, msg = net.receive(5, cfg.protocol)
      if from == id and msg then
        if msg.t == "output" then
          if opts and opts.onOutput then
            opts.onOutput(msg.kind or "say", msg.text, msg.extra)
          end
        elseif msg.t == "result" and msg.job == jobId then
          if msg.situation and workers[id] then workers[id].situation = msg.situation end
          busyWith[id] = nil
          return {
            ok = msg.ok, error = msg.error, output = msg.output,
            result = msg.result, aborted = msg.aborted, elapsed = msg.elapsed,
          }
        end
      elseif from and msg then
        M.handleStray(from, msg)
      end
    end
    busyWith[id] = nil
    return { ok = false, error = "worker did not report back in time" }
  end
end

--- A session per worker, with that worker's capabilities baked into the
--- manifest. Switching between turtles of different builds re-caches the
--- system prompt once; identical turtles share a cache hit.
local function sessionFor(id)
  local w = workers[id]
  if not w then return nil, "unknown worker " .. tostring(id) end
  if not w.session then
    local proxy = {
      situation = function()
        return w.situation or ("worker " .. id .. " (state unknown)")
      end,
      env = function() error("the host does not execute programs", 0) end,
    }
    w.session = session.new(cfg, proxy, remoteRun(id))
  end
  -- Make the manifest reflect *this* turtle before the prompt is built.
  if w.caps then
    local flags = caps.detect()
    for k, v in pairs(w.caps) do flags[k] = v end
  end
  return w.session
end

function M.handleStray(id, msg)
  if busyWith[id] and (msg.t == "output" or msg.t == "result") then
    return   -- remoteRun owns this worker's stream right now
  end
  if msg.t == "hello" or msg.t == "state" then
    local isNew = workers[id] == nil
    workers[id] = workers[id] or {}
    workers[id].caps      = msg.caps or workers[id].caps
    workers[id].situation = msg.situation or workers[id].situation
    workers[id].label     = msg.label or workers[id].label
    workers[id].lastSeen  = os.clock()
    if isNew then
      console.head(("worker %d (%s) joined"):format(id, workers[id].label or "?"))
      target = target or id
      net.send(id, { t = "ack", text = "host " .. os.getComputerID() .. " here" },
               cfg.protocol)
    end
  elseif msg.t == "ask" then
    console.head(("worker %d asks: %s"):format(id, tostring(msg.text)))
    if msg.situation then
      workers[id] = workers[id] or {}
      workers[id].situation = msg.situation
    end
    M.dispatch(id, msg.text)
  elseif msg.t == "output" then
    console.say(("[%d] %s"):format(id, tostring(msg.text)))
  end
end

net.onStray = function(id, msg) M.handleStray(id, msg) end

--------------------------------------------------------------- dispatch ---

function M.dispatch(id, text)
  local sess, err = sessionFor(id)
  if not sess then console.err(tostring(err)); return end
  local reusable = text:sub(1, 1) == "+"
  if reusable then text = util.trim(text:sub(2)) end
  poll(id)
  local r = sess:handle(text, { onEvent = events(), name = "w" .. id,
                                reusable = reusable })
  if not r then return end
  if r.ok then console.head(("[%d] done in %.1fs"):format(id, r.elapsed or 0))
  elseif r.aborted then console.warn(("[%d] stopped"):format(id))
  else console.err(("[%d] %s"):format(id, util.clip(tostring(r.error), 300))) end
end

---------------------------------------------------------------- commands --

local HELP = {
  "@<id> <request>   send a request to one worker",
  "all <request>     send the same request to every worker",
  "/use <id>         set the default worker",
  "/who              list workers",
  "/poll             refresh every worker's state",
  "/state [id]       show a worker's state",
  "@<id> +<request>  ask for a REUSABLE routine",
  "/code             last program for the current worker",
  "/again            re-run it (no API call)",
  "/save <name>      save it",
  "/run <name> [id]  send a saved program (no API call)",
  "/register <name>  make a saved program callable by Claude",
  "/expose <n> on|off   show or hide it in the prompt",
  "/unregister <n>   revoke it",
  "/check <name>     lint a saved program without registering",
  "/jobs [name]      list saved programs, or describe one",
  "/stop [id]        abort a running job",
  "/manifest         the API workers are given, and its token cost",
  "/notes <text>     house rules appended to the system prompt",
  "/model [id]       show or change the model",
  "/reset [id]       clear a worker's conversation",
  "/stats",
  "/exit",
}

local function command(input)
  local cmd, rest = input:match("^/(%S+)%s*(.*)$")
  if not cmd then return false end
  cmd = cmd:lower()

  if cmd == "help" or cmd == "?" then
    for _, l in ipairs(HELP) do console.dim(l) end

  elseif cmd == "who" then
    if not next(workers) then console.dim("no workers yet") end
    for _, id in ipairs(util.keys(workers)) do
      local w = workers[id]
      console.dim(("%s%-4s %-14s %s"):format(
        tonumber(id) == target and "*" or " ", tostring(id),
        w.label or "?", (w.situation or ""):match("^[^\n]*") or ""))
    end

  elseif cmd == "use" then
    local id = tonumber(rest)
    if not id then console.warn("usage: /use <id>")
    else target = id; workers[id] = workers[id] or {}; poll(id)
         console.head("addressing worker " .. id) end

  elseif cmd == "poll" then
    for id in pairs(workers) do poll(id, 2) end
    console.dim("polled " .. util.count(workers) .. " workers")

  elseif cmd == "state" then
    local id = tonumber(rest) or target
    local w = id and poll(id)
    console.info(w and (w.situation or "(no state)") or "no such worker")

  elseif cmd == "manifest" then
    local tokens, chars = registry.manifestCost()
    console.info(registry.manifest())
    console.head(("~%d tokens (%d chars), cached after the first request")
      :format(tokens, chars))

  elseif cmd == "code" or cmd == "again" or cmd == "save" or cmd == "reset" then
    local sess = target and sessionFor(target)
    if not sess then console.warn("no worker selected (/use <id>)")
    elseif cmd == "code" then
      if sess.lastCode then console.code(sess.lastCode, 200) else console.warn("nothing yet") end
    elseif cmd == "again" then
      local r = sess:rerun({ onEvent = events() })
      if r and not r.ok then console.err(tostring(r.error)) end
    elseif cmd == "save" then
      if rest == "" or not sess.lastCode then console.warn("usage: /save <name> (after a run)")
      else jobs.save(rest, sess.lastCode); console.head("saved as " .. rest) end
    elseif cmd == "reset" then
      sess:reset(); console.head("conversation cleared")
    end

  elseif cmd == "run" then
    local name, idStr = rest:match("^(%S+)%s*(%S*)$")
    local id = tonumber(idStr) or target
    local src = name and jobs.load(name)
    if not src then console.err("no saved job called " .. tostring(name))
    elseif not id then console.warn("no worker selected")
    else
      console.status(("sending %s to worker %d"):format(name, id))
      local r = remoteRun(id)(src, { onOutput = function(k, t) console.say(t) end })
      if r.ok then console.head("done") else console.err(tostring(r.error)) end
    end

  elseif cmd == "jobs" then
    if rest ~= "" then
      local doc = agent.lib.doc(rest)
      console.info(doc or (rest .. " has no contract (saved as a one-off)"))
    else
      local rows = jobs.table()
      if #rows == 0 then console.dim("no saved jobs")
      else for _, e in ipairs(rows) do console.dim(jobs.row(e)) end end
    end

  elseif cmd == "register" or cmd == "unregister" or cmd == "expose"
         or cmd == "check" then
    -- The library is shared by the whole fleet, so these are host-level,
    -- not per-worker. Every worker's cached prefix is rebuilt after a
    -- change; that costs one cache write each, then rides free again.
    local out = { head = console.head, warn = console.warn,
                  err = console.err, dim = console.dim }
    if cmd == "register" then
      local res = jobs.register(rest)
      jobs.report(rest, res, out)
      if res.needsRetrofit then
        local sess = target and sessionFor(target)
        if not sess then console.warn("select a worker first to retrofit (/use <id>)")
        else
          local yn = console.ask("promote it? one API call. [y/N] ")
          if yn and yn:lower():sub(1, 1) == "y" then
            local newSrc, err = sess:retrofit(rest, jobs.load(rest),
              agent.lint.report(res.findings or {}))
            if not newSrc then console.err(tostring(err))
            else
              console.code(newSrc)
              jobs.save(rest, newSrc)
              agent.lib.invalidate()
              jobs.report(rest, jobs.register(rest), out)
            end
          end
        end
      end
    elseif cmd == "unregister" then
      local ok, err = jobs.unregister(rest)
      console.info(ok and ("unregistered " .. rest) or tostring(err))
    elseif cmd == "expose" then
      local name, onoff = rest:match("^(%S+)%s*(%S*)$")
      local on = onoff == "" or onoff == "on" or onoff == "true"
      local ok, err = jobs.expose(name, on)
      console.info(ok and ((name or "?") .. " is now " ..
                   (on and "listed" or "unlisted")) or tostring(err))
    else
      local res, err = jobs.check(rest)
      if not res then console.err(tostring(err))
      else
        console.info(agent.lint.report(res.findings))
        for _, e in ipairs(res.errors or {}) do console.err(e) end
        for _, w in ipairs(res.warnings or {}) do console.warn(w) end
      end
    end
    for _, w in pairs(workers) do
      if w.session then w.session:buildSystem() end
    end

  elseif cmd == "stop" then
    local id = tonumber(rest) or target
    if id then net.send(id, { t = "abort" }, cfg.protocol); console.warn("abort sent to " .. id) end

  elseif cmd == "notes" then
    if rest == "" then console.dim(cfg.operatorNotes or "(none)")
    else
      cfg.operatorNotes = rest
      for _, w in pairs(workers) do if w.session then w.session:buildSystem(true) end end
      console.head("notes updated")
    end

  elseif cmd == "model" then
    if rest == "" then console.dim(cfg.model) else cfg.model = rest; console.head("model: " .. rest) end

  elseif cmd == "stats" then
    for _, id in ipairs(util.keys(workers)) do
      local w = workers[id]
      if w.session then console.dim(("%s: %s"):format(tostring(id), w.session:statsLine())) end
    end

  elseif cmd == "exit" or cmd == "quit" then
    running = false

  else
    console.warn("unknown command: /" .. cmd .. "  (/help)")
  end
  return true
end

------------------------------------------------------------------- main ---

local function prompt()
  local history = {}
  while running do
    local input = console.ask(target and ("@" .. target .. "> ") or "> ", history)
    if input == nil then running = false; break end
    input = util.trim(input)
    if input ~= "" then
      history[#history + 1] = input
      if not command(input) then
        local id, rest = input:match("^@(%d+)%s+(.+)$")
        if id then
          target = tonumber(id)
          workers[target] = workers[target] or {}
          M.dispatch(target, rest)
        elseif input:match("^all%s+") then
          local text = input:match("^all%s+(.+)$")
          for wid in pairs(workers) do M.dispatch(wid, text) end
        elseif target then
          M.dispatch(target, input)
        else
          console.warn("no worker selected -- /who, then /use <id>")
        end
      end
    end
  end
end

--- Background listener so workers can join, and relay requests, while the
--- operator is typing.
local function listen()
  while running do
    local id, msg = net.receive(5, cfg.protocol)
    if id and msg then M.handleStray(id, msg) end
  end
end

function M.run()
  cfg = config.load()
  if not config.hasKey(cfg) then
    console.head("ccagent host needs an Anthropic API key.")
    local key = console.ask("key> ")
    if not key or util.trim(key) == "" then return end
    require("claude.config").saveKey(key)
    cfg = config.load()
  end

  console.head("ccagent host " .. agent.VERSION)
  agent.boot({ calibrate = false })
  net.protocol = cfg.protocol

  local ok, err = net.open()
  if not ok then console.err("no modem: " .. tostring(err)); return end
  if rednet.host then pcall(rednet.host, cfg.protocol, cfg.hostname) end

  net.broadcast({ t = "hostup" }, cfg.protocol)
  console.dim("announced as '" .. cfg.hostname .. "'. waiting for workers... (/help)")

  if _G.parallel then parallel.waitForAny(listen, prompt) else prompt() end
  console.dim("bye.")
end

if not _TEST then M.run() end

return M
