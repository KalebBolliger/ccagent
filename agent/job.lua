--[[ agent/job.lua -------------------------------------------------------
  The contract between a generated script and the thing running it.

  A script talks to the operator through job.say / job.progress instead of
  print(), so the controller can route that output anywhere (terminal,
  monitor, rednet, a log file) without the script knowing or caring.

  job.checkpoint / job.recall persist small values across a reboot, which is
  what will let the future session manager resume a half-finished quarry
  after a chunk unload. Today they are just a durable scratchpad -- but
  scripts written against them now will resume correctly later.
--------------------------------------------------------------------------]]

local util  = require("agent.util")
local state = require("agent.state")

local job = {}

job.name     = "job"
job.sink     = nil     -- function(kind, text, extra) installed by the runner
job.abortFlag = false
job.result   = nil

--- The abort signal is a unique table, not a string. A generated program
--- that wraps work in pcall will swallow a plain error and carry on after
--- the operator pressed stop twice; library code that catches this sentinel
--- re-raises it, and every lib.run boundary re-checks the flag, so an abort
--- cannot be lost inside a nested routine.
job.ABORT = setmetatable({}, { __tostring = function() return "aborted by operator" end })

function job.isAbort(err)
  return err == job.ABORT or tostring(err) == "aborted by operator"
end

--- Re-raise if `err` is the abort sentinel; otherwise return it. Wrap any
--- pcall in library code with this.
function job.rethrowAbort(err)
  if job.isAbort(err) then error(job.ABORT, 0) end
  return err
end

--- Nesting. lib.run pushes a frame so a called routine gets its own
--- checkpoint namespace and its own result slot; without this a nested
--- job.report() silently overwrites its caller's return value, and nested
--- checkpoints collide with the parent's -- which would corrupt exactly the
--- reboot-resume mechanism the checkpoints exist for.
local frames = {}

function job.push(name)
  frames[#frames + 1] = { name = job.name, result = job.result }
  job.name = name or job.name
  job.result = nil
  return #frames
end

function job.pop()
  local f = table.remove(frames)
  if not f then return nil end
  local inner = job.result
  job.name, job.result = f.name, f.result
  return inner
end

function job.depth() return #frames end

function job.stack()
  local out = {}
  for _, f in ipairs(frames) do out[#out + 1] = f.name end
  out[#out + 1] = job.name
  return out
end

function job.reset(name)
  job.name = name or "job"
  job.abortFlag = false
  job.result = nil
  frames = {}
end

local function emit(kind, text, extra)
  if job.sink then
    job.sink(kind, text, extra)
  else
    print(text)
  end
end

--- Narrate. Keep it to things a human would want to read.
function job.say(fmt, ...)
  local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  emit("say", text)
  return text
end

function job.warn(fmt, ...)
  local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  emit("warn", text)
  return text
end

--- Progress for long loops. The runner decides how to render it.
function job.progress(done, total, label)
  emit("progress", ("%s %d/%d"):format(label or "", done, total or 0),
       { done = done, total = total, label = label })
end

--- Hand a structured result back to the controller (and, if the operator
--- asks a follow-up question, back to Claude as context).
function job.report(value)
  job.result = value
  emit("report", type(value) == "table" and textutils and textutils.serialise
       and textutils.serialise(value) or tostring(value), value)
  return value
end

--- Cooperative cancellation. Long loops should call this.
function job.aborted()
  return job.abortFlag == true
end

--- Raise if the operator pressed stop. One call at the top of a loop body
--- makes any script interruptible.
function job.checkAbort()
  if job.abortFlag then error(job.ABORT, 0) end
end

function job.sleep(n)
  job.checkAbort()
  util.sleep(n or 0.05)
  job.checkAbort()
end

------------------------------------------------------------ checkpoints ---

local function key(k) return "ckpt:" .. job.name .. ":" .. tostring(k) end

function job.checkpoint(k, value)
  state.set(key(k), value)
  state.flush()
  return value
end

function job.recall(k, default)
  local v = state.get(key(k))
  if v == nil then return default end
  return v
end

function job.clearCheckpoints()
  local all = state.all()
  local prefix = "ckpt:" .. job.name .. ":"
  for k in pairs(all) do
    if util.startsWith(k, prefix) then all[k] = nil end
  end
  state.flush()
end

return job
