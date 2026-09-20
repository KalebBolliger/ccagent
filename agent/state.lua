--[[ agent/state.lua -----------------------------------------------------
  Durable key/value store for things that must survive a chunk unload, a
  server restart, or the turtle being broken and re-placed: position,
  home, world memory, saved jobs.

  Writes are buffered and flushed on a dirty-count / time threshold so a
  long movement loop is not doing one disk write per block, but position
  is never more than `flushEvery` moves stale. Callers that are about to
  do something irreversible should call state.flush() first.
--------------------------------------------------------------------------]]

local util = require("agent.util")

local state = {}

state.path       = "/.ccagent/state.json"
state.flushEvery = 8      -- dirty ops before an automatic flush
state.flushAfter = 3000   -- ms before an automatic flush

local data, dirty, lastFlush = nil, 0, 0

local function ensure()
  if data then return end
  data = util.readJSON(state.path) or {}
  lastFlush = util.now()
end

function state.load()
  data = nil
  ensure()
  return data
end

function state.flush()
  ensure()
  if dirty == 0 then return true end
  local ok = util.writeJSON(state.path, data)
  if ok then dirty, lastFlush = 0, util.now() end
  return ok
end

local function touch()
  dirty = dirty + 1
  if dirty >= state.flushEvery or (util.now() - lastFlush) >= state.flushAfter then
    state.flush()
  end
end

function state.get(key, default)
  ensure()
  local v = data[key]
  if v == nil then return default end
  return v
end

function state.set(key, value)
  ensure()
  data[key] = value
  touch()
  return value
end

--- Set without scheduling a flush; use inside hot loops, then flush yourself.
function state.setLazy(key, value)
  ensure()
  data[key] = value
  dirty = dirty + 1
end

function state.delete(key)
  ensure()
  data[key] = nil
  touch()
end

function state.all()
  ensure()
  return data
end

--- Wipe everything (used by `reset` in the controllers).
function state.clear()
  data = {}
  dirty = 1
  return state.flush()
end

return state
