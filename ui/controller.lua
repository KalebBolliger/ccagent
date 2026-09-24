--[[ ui/controller.lua ---------------------------------------------------
  Standalone front-end: one turtle, its own API key, its own conversation.

      /ccagent            (the launcher; /ccagent solo does the same)
      /ccagent/ui/controller               (the long way round)

  Type what you want. Slash commands do the housekeeping; /help lists them.

  This is one of the two front-ends over the same core -- see ui/host.lua
  for the fleet version. Nothing in agent/ or claude/ knows which one is
  driving, which is the point.
--------------------------------------------------------------------------]]

-- The tree lives at /ccagent (agent/lib.lua and claude/config.lua say so
-- too). CC also searches the running program's own directory, which is
-- why a wrong prefix here still works from /ccagent/install.lua and
-- fails from /ccagent/ui/ one level down.
package.path = "/ccagent/?.lua;/ccagent/?/init.lua;" .. (package.path or "")

local util     = require("agent.util")
local agent    = require("agent.init")
local registry = require("agent.registry")
local config   = require("claude.config")
local session  = require("claude.session")
local executor = require("claude.executor")
local console  = require("ui.console")
local jobs     = require("ui.jobs")

local M = {}

local function firstRun(cfg)
  if config.hasKey(cfg) then return cfg end
  console.head("ccagent needs an Anthropic API key.")
  console.dim("It is stored in " .. config.paths.key .. " and nowhere else.")
  local key = console.ask("key> ")
  if not key or util.trim(key) == "" then
    console.err("no key given; exiting")
    return nil
  end
  config.saveKey(key)
  return config.load()
end

local function events(sess)
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

local function showResult(r)
  if not r then return end
  if r.ok then
    console.head(("done in %.1fs"):format(r.elapsed or 0))
  elseif r.aborted then
    console.warn("stopped")
  else
    console.err(util.clip(tostring(r.error), 400))
  end
end

local HELP = {
  "/state          what the turtle can see and carry",
  "/caps           capability probe results",
  "/manifest       the API Claude is shown, and its token cost",
  "/code           full source of the last program",
  "/again          re-run the last program (no API call)",
  "/dry <request>  generate a program but do not run it",
  "+<request>      ask for a REUSABLE routine (writes a contract header)",
  "/save <name>    save the last program",
  "/run <name>     run a saved program (no API call)",
  "/register <n>   make a saved program callable by Claude",
  "/expose <n> on|off   show or hide it in the prompt",
  "/unregister <n> revoke it",
  "/check <name>   lint a saved program without registering",
  "/jobs [name]    list saved programs, or describe one",
  "/del <name>     delete a saved program",
  "/calibrate      re-fix position and heading from GPS",
  "/sethome        mark this spot as home",
  "/home           go home",
  "/refuel [n]     burn carried fuel",
  "/notes <text>   house rules appended to the system prompt",
  "/model [id]     show or change the model",
  "/reset          forget the conversation (keeps world memory)",
  "/forget         wipe world memory and pose",
  "/stats          token usage this session",
  "/doctor         version, transport, one test call",
  "/exit",
}

-- The command words, taken from HELP so the two cannot drift apart.
local COMMAND_WORDS = {}
for _, entry in ipairs(HELP) do
  local name = entry:match("^/(%a[%w_]*)")
  if name then COMMAND_WORDS[name] = true end
end

--- Slash commands. Returns true if the input was handled.
local function command(input, ctx)
  local cmd, rest = input:match("^/(%S+)%s*(.*)$")
  if not cmd then return false end
  cmd = cmd:lower()
  local sess, cfg = ctx.sess, ctx.cfg

  if cmd == "help" or cmd == "?" then
    for _, l in ipairs(HELP) do console.dim(l) end

  elseif cmd == "state" then
    console.info(agent.situation())

  elseif cmd == "caps" then
    local flags = agent.caps.detect(true)
    for _, k in ipairs(util.keys(flags)) do
      local v = flags[k]
      if type(v) == "table" then
        local bits = {}
        for kk, vv in pairs(v) do bits[#bits + 1] = tostring(kk) .. "=" .. tostring(vv) end
        v = table.concat(bits, " ")
      end
      console.dim(("%-16s %s"):format(k, tostring(v)))
    end

  elseif cmd == "manifest" then
    local tokens, chars = registry.manifestCost()
    console.info(registry.manifest())
    console.head(("~%d tokens (%d chars), cached after the first request")
      :format(tokens, chars))

  elseif cmd == "code" then
    if sess.lastCode then
      console.code(sess.lastCode, 200)
    else console.warn("no program yet") end

  elseif cmd == "again" then
    showResult(sess:rerun({ onEvent = events(sess) }))

  elseif cmd == "dry" then
    if rest == "" then console.warn("usage: /dry <request>")
    else
      local r = sess:handle(rest, { onEvent = events(sess), dryRun = true })
      if not r.ok then console.err(tostring(r.error)) end
    end

  elseif cmd == "save" then
    if rest == "" then console.warn("usage: /save <name>")
    elseif not sess.lastCode then console.warn("no program to save")
    else
      jobs.save(rest, sess.lastCode, ctx.lastRequest)
      console.head("saved as " .. rest)
    end

  elseif cmd == "run" then
    local src, err = jobs.load(rest)
    if not src then console.err(tostring(err))
    else
      console.status("running saved job " .. rest)
      local r = executor.run(src, agent.env(), {
        name = rest,
        onOutput = function(k, t, e) events(sess)("output", t, { kind = k, extra = e }) end,
      })
      showResult(r)
    end

  elseif cmd == "jobs" then
    if rest ~= "" then
      local doc = agent.lib.doc(rest)
      if doc then console.info(doc)
      else console.warn(rest .. " has no contract (saved as a one-off)") end
    else
      local rows = jobs.table()
      if #rows == 0 then console.dim("no saved jobs")
      else for _, e in ipairs(rows) do console.dim(jobs.row(e)) end end
    end

  elseif cmd == "register" then
    if rest == "" then console.warn("usage: /register <name>")
    else
      local res = jobs.register(rest)
      jobs.report(rest, res, { head = console.head, warn = console.warn,
                               err = console.err, dim = console.dim })
      if res.needsRetrofit then
        console.dim("no contract header -- it was written as a one-off.")
        local yn = console.ask("promote it? one API call. [y/N] ")
        if yn and yn:lower():sub(1, 1) == "y" then
          console.status("asking Claude to parameterise it...")
          local src = jobs.load(rest)
          local newSrc, err = sess:retrofit(rest, src,
            agent.lint.report(res.findings or {}), ctx.lastRequest)
          if not newSrc then console.err(tostring(err))
          else
            console.code(newSrc)
            jobs.save(rest, newSrc, ctx.lastRequest)
            agent.lib.invalidate()
            local res2 = jobs.register(rest)
            jobs.report(rest, res2, { head = console.head, warn = console.warn,
                                      err = console.err, dim = console.dim })
            if res2.ok then sess:buildSystem() end
          end
        end
      elseif res.ok then
        sess:buildSystem()
      end
    end

  elseif cmd == "unregister" then
    local ok, err = jobs.unregister(rest)
    if ok then sess:buildSystem(); console.head("unregistered " .. rest)
    else console.warn(tostring(err)) end

  elseif cmd == "expose" then
    local name, onoff = rest:match("^(%S+)%s*(%S*)$")
    local on = onoff == "" or onoff == "on" or onoff == "true"
    local ok, err = jobs.expose(name, on)
    if ok then
      sess:buildSystem()
      console.head(("%s is now %s"):format(name, on and "listed" or "unlisted"))
    else console.warn(tostring(err)) end

  elseif cmd == "check" then
    local res, err = jobs.check(rest)
    if not res then console.err(tostring(err))
    else
      console.info(agent.lint.report(res.findings))
      if res.contract then
        console.dim("declares frame: " .. res.contract.frame)
        for _, e in ipairs(res.errors) do console.err(e) end
        for _, w in ipairs(res.warnings) do console.warn(w) end
        if #res.errors == 0 then console.head("contract is consistent") end
      else
        console.dim("no contract header")
      end
    end

  elseif cmd == "del" then
    local ok = jobs.delete(rest)
    if ok then sess:buildSystem() end
    console.dim(ok and ("deleted " .. rest) or "no such job")

  elseif cmd == "calibrate" then
    local ok, err = agent.nav.calibrate({ force = true })
    console.info(ok and agent.nav.status() or ("calibration failed: " .. tostring(err)))

  elseif cmd == "sethome" then
    agent.nav.setHome()
    console.head("home set to " .. agent.geom.tostring(agent.nav.home()))

  elseif cmd == "home" then
    local ok, err = agent.nav.goHome()
    console.info(ok and "home" or ("could not get home: " .. tostring(err)))

  elseif cmd == "refuel" then
    local lvl = agent.inv.refuel(tonumber(rest) or 5000)
    console.info("fuel: " .. tostring(lvl))

  elseif cmd == "notes" then
    if rest == "" then console.dim(cfg.operatorNotes or "(none)")
    else
      cfg.operatorNotes = rest
      sess:buildSystem(true)
      console.head("notes updated (system prompt will re-cache once)")
    end

  elseif cmd == "model" then
    if rest == "" then console.dim(cfg.model)
    else cfg.model = rest; console.head("model: " .. rest) end

  elseif cmd == "reset" then
    sess:reset()
    console.head("conversation cleared")

  elseif cmd == "forget" then
    agent.world.clear()
    agent.state.clear()
    agent.boot()
    console.head("world memory and pose cleared")

  elseif cmd == "stats" then
    console.info(sess:statsLine())

  elseif cmd == "doctor" then
    -- Answers one question: is this turtle running the code you think it
    -- is, and does a request actually complete? Both halves matter --
    -- a stale install and a broken transport look identical from the
    -- outside, and "Timed out" is printed by CC, not by us.
    local client = require("claude.client")
    local s = client.settings(cfg)
    console.head("ccagent " .. agent.VERSION)
    console.info(("stream %s  read %ds  wait %ds"):format(
      s.stream and "on" or "OFF", s.readTimeout, s.timeout))
    console.info(("%s  %d tok"):format(
      (s.model:gsub("^claude%-", "")), s.maxTokens))
    console.info(("think %s  effort %s"):format(s.thinking, s.effort))
    if not s.stream then
      console.warn("streaming off: long jobs will fail")
    end
    console.info(("http %s   key %s"):format(
      _G.http and "ok" or "OFF",
      config.hasKey(cfg) and "ok" or "missing"))
    console.status("one test request...")
    local took, err = client.ping(cfg)
    if took then
      console.say(("ok, %.1fs"):format(took))
    else
      console.err(tostring(err))
    end

  elseif cmd == "exit" or cmd == "quit" then
    ctx.running = false

  else
    console.warn("unknown command: /" .. cmd .. "  (/help)")
  end
  return true
end

function M.run(argv)
  local cfg = config.load()
  cfg = firstRun(cfg)
  if not cfg then return end

  console.head("ccagent " .. agent.VERSION)
  console.status("probing...")
  agent.boot()
  console.info(agent.situation())
  console.dim("type a request at cc>, or /help.")
  console.dim("press Q while a job runs to stop it.")
  console.rule()

  local sess = session.new(cfg, agent)
  local ctx = { sess = sess, cfg = cfg, running = true, lastRequest = nil }
  local history = {}

  -- A request passed on the command line runs once and exits, which makes
  -- ccagent usable from other programs and from a startup file.
  if argv and #argv > 0 then
    local request = table.concat(argv, " ")
    showResult(sess:handle(request, { onEvent = events(sess) }))
    agent.state.flush()
    return
  end

  while ctx.running do
    local input = console.ask(console.PROMPT, history)
    if input == nil then break end
    input = util.trim(input)
    if input ~= "" then
      history[#history + 1] = input
      local slipped = console.forgottenSlash(input, COMMAND_WORDS)
      if slipped then
        console.warn(("'%s' is a command: /%s"):format(slipped, slipped))
        local yn = console.ask("ask Claude instead? [y/N] ")
        if not tostring(yn or ""):lower():match("^y") then
          input = ""                      -- typed the slash off; do nothing
        end
      end
      if input == "" then                 -- nothing to do this round
      elseif not command(input, ctx) then
        -- A leading + asks for a routine rather than a one-off. This has to
        -- be decided before generation: writing for reuse changes the whole
        -- program, not just its header.
        local reusable = input:sub(1, 1) == "+"
        local request = reusable and util.trim(input:sub(2)) or input
        ctx.lastRequest = request
        local ok, r = pcall(function()
          return sess:handle(request, { onEvent = events(sess), reusable = reusable })
        end)
        if ok then
          showResult(r)
          if r and r.ok and reusable and agent.contract.extract(r.code or "") then
            local c = agent.contract.parse(r.code)
            if c then
              console.dim(("it carries a contract for '%s' -- /save %s then /register %s")
                :format(c.name, c.name, c.name))
            end
          end
        else console.err("controller error: " .. tostring(r)) end
        agent.state.flush()
      end
    end
  end
  agent.world.save()
  console.dim("bye. " .. sess:statsLine())
end

if not _TEST then
  M.run({ ... })
end

return M
