--[[ claude/executor.lua -------------------------------------------------
  Runs a generated program.

  Responsibilities, in order of how much they matter:
    1. Never let a generated script wedge the computer. It runs beside a
       watcher coroutine, so Q always gets you out.
    2. Give the script exactly the API the manifest promised and nothing
       else -- no fs, no http, no shell, no require.
    3. Capture the error *and* the output that led to it in a form worth
       sending back for repair, with line numbers that match the source
       Claude wrote.

  This is the deliberately simple version. The session manager the design
  is heading toward (pause/resume, job queue, checkpoint-resume after a
  chunk unload) slots in around this file without changing the contract:
  run(code) -> result table.
--------------------------------------------------------------------------]]

local util = require("agent.util")
local job  = require("agent.job")
local inv  = require("agent.inv")

local executor = {}

executor.outputLimit = 4000   -- chars of captured output kept for repair

--------------------------------------------------------------- sandbox ----

-- Anything that can change the inventory must bust the inventory cache.
local MUTATES_INVENTORY = {}
for _, name in ipairs({ "select", "drop", "dropUp", "dropDown", "suck",
                        "suckUp", "suckDown", "transferTo", "refuel",
                        "craft", "equipLeft", "equipRight", "place",
                        "placeUp", "placeDown", "dig", "digUp", "digDown" }) do
  MUTATES_INVENTORY[name] = true
end

-- Equipping changes what the machine *is*, not just what it holds.
local MUTATES_CAPABILITIES = { equipLeft = true, equipRight = true }

--- Movement through the raw turtle API would desync nav's position
--- tracking, so the `turtle` table the script sees has its movement
--- functions rerouted. Everything else passes through untouched.
---
--- Resolved live, through __index, rather than copied once: the turtle API
--- is not a fixed set. turtle.craft does not exist until a crafting table
--- is equipped, so a script that equips one and then crafts -- the whole
--- point of carrying a crafting table -- would find turtle.craft missing
--- from a snapshot taken before it equipped.
local function wrapTurtle(env)
  if not _G.turtle then return nil end
  local nav = require("agent.nav")
  local inv = require("agent.inv")
  local caps = require("agent.caps")

  local rerouted = {
    forward   = function() return nav.forward() end,
    back      = function() return nav.back() end,
    up        = function() return nav.up() end,
    down      = function() return nav.down() end,
    turnLeft  = function() return nav.turnLeft() end,
    turnRight = function() return nav.turnRight() end,
  }

  local wrapped = {}   -- name -> { orig = <fn seen>, fn = <wrapper> }

  return setmetatable({}, {
    __index = function(_, key)
      local route = rerouted[key]
      if route then return route end

      local fn = turtle[key]
      if type(fn) ~= "function" or not MUTATES_INVENTORY[key] then return fn end

      -- Re-wrap if the underlying function changed (or appeared).
      local seen = wrapped[key]
      if seen and seen.orig == fn then return seen.fn end
      local wrapper = function(...)
        local a, b = fn(...)
        inv.invalidate()
        if MUTATES_CAPABILITIES[key] then caps.refresh() end
        return a, b
      end
      wrapped[key] = { orig = fn, fn = wrapper }
      return wrapper
    end,
  })
end

local SAFE_OS = { "time", "clock", "day", "epoch", "sleep", "startTimer",
                  "cancelTimer", "queueEvent", "pullEvent", "pullEventRaw",
                  "getComputerID", "getComputerLabel", "date" }

function executor.sandbox(apiEnv)
  local env = {}

  -- Standard library subset.
  env.string, env.table, env.math = string, table, math
  env.pairs, env.ipairs, env.next, env.select = pairs, ipairs, next, select
  env.type, env.tostring, env.tonumber = type, tostring, tonumber
  env.pcall, env.xpcall, env.error, env.assert = pcall, xpcall, error, assert
  env.setmetatable, env.getmetatable = setmetatable, getmetatable
  env.rawget, env.rawset, env.rawequal, env.rawlen =
      rawget, rawset, rawequal, rawlen
  env.unpack = table.unpack or unpack
  env.tostring = tostring
  env.math = math

  env.os = {}
  for _, k in ipairs(SAFE_OS) do env.os[k] = os[k] end

  if _G.textutils then
    env.textutils = {
      serialise = textutils.serialise or textutils.serialize,
      serialize = textutils.serialise or textutils.serialize,
      formatTime = textutils.formatTime,
    }
  end
  if _G.colors then env.colors = colors end
  if _G.keys then env.keys = keys end
  if _G.vector then env.vector = vector end

  env.sleep = function(n) return job.sleep(n) end
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    job.say(table.concat(parts, " "))
  end
  env.write = env.print

  -- The agent API.
  for k, v in pairs(apiEnv) do env[k] = v end

  env.turtle = wrapTurtle(env)

  -- Explicitly absent, with a message that explains itself.
  for _, name in ipairs({ "require", "dofile", "loadfile", "loadstring",
                          "load", "fs", "http", "shell", "peripheral",
                          "rednet", "gps", "io", "package" }) do
    env[name] = nil
  end

  env._G = env
  env._ENV = env
  return env
end

---------------------------------------------------------------- running ---

local function annotate(code, err)
  local line = tostring(err):match("^job:(%d+):")
  if not line then return err end
  line = tonumber(line)
  local lines, n = {}, 0
  for l in (code .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if n >= line - 2 and n <= line + 2 then
      lines[#lines + 1] = ("%s%4d | %s"):format(n == line and ">" or " ", n, l)
    end
  end
  if #lines == 0 then return err end
  return tostring(err) .. "\n" .. table.concat(lines, "\n")
end

--- Run a program.
---   code    Lua source
---   apiEnv  the table from agent.env()
---   opts    { name, onOutput(kind, text, extra), allowKeyAbort = true }
--- Returns a result table:
---   { ok, error, output, result, aborted, elapsed }
function executor.run(code, apiEnv, opts)
  opts = opts or {}
  job.reset(opts.name or "job")

  -- Anything cached about the inventory is a guess by now. The operator
  -- can open the turtle's GUI between jobs and take the bread out, and
  -- nothing in here would hear about it -- the cache is only invalidated
  -- by operations this library performs. A program that starts from a
  -- remembered inventory reasons about a turtle that no longer exists.
  inv.invalidate()

  local captured, capturedLen = {}, 0
  local prevSink = job.sink
  job.sink = function(kind, text, extra)
    if capturedLen < executor.outputLimit then
      captured[#captured + 1] = text
      capturedLen = capturedLen + #text + 1
    end
    if opts.onOutput then opts.onOutput(kind, text, extra) end
  end

  local env = executor.sandbox(apiEnv)
  -- Nested routines compile against a child of this environment.
  local okLib, lib = pcall(require, "agent.lib")
  if okLib then lib.bind(env) end

  local chunk, compileErr = load(code, "@job", "t", env)
  if not chunk then
    job.sink = prevSink
    return { ok = false, error = "syntax error: " .. tostring(compileErr),
             output = "", compile = true }
  end

  local started = util.now()
  local ok, err, hardStop = true, nil, false

  local function runner()
    ok, err = pcall(chunk)
    if not ok then err = annotate(code, err) end
  end

  local function watcher()
    local presses = 0
    while true do
      local ev, p1 = os.pullEvent()
      if ev == "ccagent_abort" then
        job.abortFlag = true
        presses = presses + 1
      elseif ev == "key" and opts.allowKeyAbort ~= false and _G.keys
             and p1 == keys.q then
        presses = presses + 1
        job.abortFlag = true
        if opts.onOutput then
          opts.onOutput("warn", presses == 1
            and "stop requested -- finishing the current step (press Q again to force)"
            or  "forcing stop")
        end
      end
      if presses >= 2 then hardStop = true; return end
    end
  end

  if _G.parallel then
    parallel.waitForAny(runner, watcher)
  else
    runner()   -- plain-Lua test harness
  end

  job.sink = prevSink
  local elapsed = (util.now() - started) / 1000

  local result = {
    ok       = ok and not hardStop,
    error    = (not ok) and tostring(err) or (hardStop and "force-stopped" or nil),
    output   = table.concat(captured, "\n"),
    result   = job.result,
    aborted  = job.abortFlag,
    elapsed  = elapsed,
  }
  -- An abort that surfaced as an error is a stop, not a failure -- and the
  -- sentinel survives a nested pcall, so this is reliable even when the
  -- program wrapped its own work.
  if not ok and job.isAbort(err) then
    result.aborted = true
    result.error = "aborted by operator"
  end
  return result
end

--- Ask for a stop from outside the executor (rednet command, monitor
--- button, another coroutine).
function executor.requestAbort()
  job.abortFlag = true
  if _G.os and os.queueEvent then os.queueEvent("ccagent_abort") end
end

return executor
