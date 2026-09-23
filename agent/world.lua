--[[ agent/world.lua -----------------------------------------------------
  A sparse, persistent memory of what the turtle has seen.

  Why this exists: `turtle.inspect()` costs a server tick and, more to the
  point, a re-inspection costs the *model* nothing but costs the *job* time,
  while a block the turtle looked at two seconds ago is almost certainly
  still there. Every observation the library makes anywhere -- a successful
  move, a blocked move, an inspect, a dig, a place -- lands here, so:

    * the pathfinder plans around walls it has already bumped into
      instead of re-discovering them,
    * `world.find("*chest*")` answers from memory with no server calls,
    * a generated script can ask "have I been here?" for free.

  Entries are {n = blockName | false, t = timestamp}. `false` means known
  air. Absent means never observed, which the pathfinder treats as
  optimistically passable.
--------------------------------------------------------------------------]]

local util  = require("agent.util")
local geom  = require("agent.geom")
local state = require("agent.state")

local world = {}

world.maxEntries = 6000    -- prune oldest beyond this
world.staleAfter = 600000  -- ms; observations older than this are advisory

local blocks = nil

local function ensure()
  if blocks then return blocks end
  blocks = state.get("world", {})
  return blocks
end

------------------------------------------------------------- recording ----

--- Record an observation. `name` is a block id, or false for air.
function world.set(p, name, extra)
  local b = ensure()
  local rec = { n = name or false, t = util.now() }
  if extra then for k, v in pairs(extra) do rec[k] = v end end
  b[geom.key(p)] = rec
  state.setLazy("world", b)
  return rec
end

function world.setAir(p) return world.set(p, false) end

function world.forget(p)
  local b = ensure()
  b[geom.key(p)] = nil
  state.setLazy("world", b)
end

function world.clear()
  blocks = {}
  state.set("world", blocks)
end

------------------------------------------------------------- frames -------

--- Which coordinate frame these observations belong to, and forget them
--- if that frame is no longer the one we are in.
---
--- Every entry here is keyed by coordinate, and without GPS coordinates
--- are local to wherever the turtle booted. Break a turtle and put it
--- back down and it starts a fresh local frame: the same keys now name
--- different blocks in the world, so a remembered "solid at 0,64,-3"
--- becomes a claim about somewhere else entirely -- and callers that
--- trust it skip work they should have done. `lib.run` already refuses to
--- run a frame-bound routine across that boundary; this is the same
--- reasoning applied to the memory the routines read.
---
--- GPS frames are mutually consistent, so they share the id "gps" and
--- survive reboots, which is the whole point of having GPS.
---
--- Returns true when memory was dropped. world does not ask nav for the
--- id -- nav reads world for pathfinding, and that way lies a require
--- cycle -- so the caller passes it in.
function world.useFrame(id)
  if id == nil then return false end
  local known = state.get("worldFrame")
  if known == id then return false end
  local had = known ~= nil and next(ensure()) ~= nil
  if had then world.clear() end
  state.set("worldFrame", id)
  return had
end

--- The frame the current memory was recorded in, if any.
function world.frame() return state.get("worldFrame") end

--------------------------------------------------------------- reading ----

function world.get(p)
  return ensure()[geom.key(p)]
end

--- true / false / nil (unknown)
function world.isSolid(p)
  local r = world.get(p)
  if not r then return nil end
  return r.n ~= false
end

function world.isKnownAir(p)
  local r = world.get(p)
  return r ~= nil and r.n == false
end

function world.age(p)
  local r = world.get(p)
  if not r then return nil end
  return util.now() - (r.t or 0)
end

function world.isStale(p)
  local a = world.age(p)
  return a == nil or a > world.staleAfter
end

--- Search remembered blocks by name glob. Returns a list of
--- {pos = {...}, name = "...", age = ms}, nearest-first if `near` given.
function world.find(pattern, opts)
  opts = opts or {}
  local out = {}
  for k, rec in pairs(ensure()) do
    if rec.n and util.glob(rec.n, pattern) then
      local p = geom.fromKey(k)
      if p and (not opts.box or geom.inBox(p, opts.box[1], opts.box[2])) then
        out[#out + 1] = { pos = p, name = rec.n, age = util.now() - (rec.t or 0) }
      end
    end
  end
  if opts.near then
    table.sort(out, function(a, b)
      return geom.manhattan(a.pos, opts.near) < geom.manhattan(b.pos, opts.near)
    end)
  end
  if opts.limit then
    while #out > opts.limit do table.remove(out) end
  end
  return out
end

--- Count of remembered blocks, optionally matching a pattern.
function world.count(pattern)
  local n = 0
  for _, rec in pairs(ensure()) do
    if rec.n and (not pattern or util.glob(rec.n, pattern)) then n = n + 1 end
  end
  return n
end

------------------------------------------------------------- bookkeeping --

--- Drop the oldest observations when memory grows past the cap. Called
--- automatically by save(); safe to call by hand in a long job.
function world.prune(target)
  local b = ensure()
  target = target or world.maxEntries
  local n = util.count(b)
  if n <= target then return 0 end
  local list = {}
  for k, rec in pairs(b) do list[#list + 1] = { k = k, t = rec.t or 0 } end
  table.sort(list, function(x, y) return x.t < y.t end)
  local drop = n - target
  for i = 1, drop do b[list[i].k] = nil end
  state.setLazy("world", b)
  return drop
end

function world.save()
  world.prune()
  state.set("world", ensure())
  return state.flush()
end

--- Compact summary for the prompt -- a few dozen tokens that tell Claude
--- what the turtle already knows about, so it does not write a search
--- routine for a chest it has been standing next to.
function world.summary(near, limit)
  local b = ensure()
  local tally = {}
  for _, rec in pairs(b) do
    if rec.n then tally[rec.n] = (tally[rec.n] or 0) + 1 end
  end
  local names = {}
  for name, c in pairs(tally) do names[#names + 1] = { name = name, c = c } end
  table.sort(names, function(x, y) return x.c > y.c end)
  local out = {}
  for i = 1, math.min(#names, limit or 8) do
    local short = names[i].name:gsub("^minecraft:", "")
    out[#out + 1] = short .. "x" .. names[i].c
  end
  if #out == 0 then return "nothing observed yet" end
  return table.concat(out, " ")
end

return world
