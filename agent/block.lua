--[[ agent/block.lua -----------------------------------------------------
  Block-level interaction in any of ten direction words.

  CC:Tweaked gives a turtle three directions: front, up, down. Everything
  else requires turning, remembering that you turned, and turning back.
  That bookkeeping is exactly the sort of thing an LLM gets subtly wrong on
  the fourth nested loop, so it lives here once:

      block.inspect("east")      -- turns, looks, (optionally) turns back
      block.dig("down")
      block.place("north", "*_planks")
      block.scan()               -- all six neighbours into world memory

  Accepts: forward, back, left, right, up, down, north, east, south, west.
  Every observation is written into the world model as a side effect.
--------------------------------------------------------------------------]]

local util  = require("agent.util")
local geom  = require("agent.geom")
local world = require("agent.world")
local nav   = require("agent.nav")
local inv   = require("agent.inv")
local caps  = require("agent.caps")

local block = {}

block.restoreFacing = true   -- turn back after a turn-requiring operation
block.gravelTries    = 12    -- dig retries for falling blocks

local API = {
  forward = { inspect = function() return turtle.inspect() end,
              detect  = function() return turtle.detect() end,
              dig     = function(s) return turtle.dig(s) end,
              place   = function(t) return turtle.place(t) end,
              attack  = function(s) return turtle.attack(s) end,
              compare = function() return turtle.compare() end,
              drop    = function(n) return turtle.drop(n) end,
              suck    = function(n) return turtle.suck(n) end },
  up      = { inspect = function() return turtle.inspectUp() end,
              detect  = function() return turtle.detectUp() end,
              dig     = function(s) return turtle.digUp(s) end,
              place   = function(t) return turtle.placeUp(t) end,
              attack  = function(s) return turtle.attackUp(s) end,
              compare = function() return turtle.compareUp() end,
              drop    = function(n) return turtle.dropUp(n) end,
              suck    = function(n) return turtle.suckUp(n) end },
  down    = { inspect = function() return turtle.inspectDown() end,
              detect  = function() return turtle.detectDown() end,
              dig     = function(s) return turtle.digDown(s) end,
              place   = function(t) return turtle.placeDown(t) end,
              attack  = function(s) return turtle.attackDown(s) end,
              compare = function() return turtle.compareDown() end,
              drop    = function(n) return turtle.dropDown(n) end,
              suck    = function(n) return turtle.suckDown(n) end },
}

--- Resolve a direction word into (api-table, absolute target position),
--- turning the turtle if the direction is horizontal but not forward.
--- Returns api, target, restore(function).
local function orient(dir)
  if not _G.turtle then return nil, nil, nil, "not a turtle" end
  dir = tostring(dir or "forward"):lower()
  local pos, facing = nav.pos(), nav.facing()

  if dir == "up" or dir == "down" then
    local target = pos and geom.add(pos, dir == "up" and { x = 0, y = 1, z = 0 }
                                                     or { x = 0, y = -1, z = 0 })
    return API[dir], target, function() end
  end

  if facing == nil then
    -- No pose yet: only forward is meaningful.
    if dir ~= "forward" then
      return nil, nil, nil, "position not initialised; call nav.calibrate() first"
    end
    return API.forward, nil, function() end
  end

  local delta, want = geom.resolve(dir, facing)
  if not delta then return nil, nil, nil, "unknown direction " .. dir end
  local target = pos and geom.add(pos, delta) or nil

  if want == facing then
    return API.forward, target, function() end
  end
  nav.face(want)
  local restore = function()
    if block.restoreFacing then nav.face(facing) end
  end
  return API.forward, target, restore
end

------------------------------------------------------------- observing ----

--- Look at a block. Returns the info table (name, state, tags) or nil, and
--- records the result -- including "it was air" -- in world memory.
function block.inspect(dir)
  local api, target, restore, err = orient(dir)
  if not api then return nil, err end
  local ok, info = api.inspect()
  if restore then restore() end
  if target then
    if ok and info then world.set(target, info.name, { state = info.state })
    else world.setAir(target) end
  end
  if not ok then return nil, "air" end
  return info
end

function block.detect(dir)
  local api, target, restore, err = orient(dir)
  if not api then return nil, err end
  local d = api.detect()
  if restore then restore() end
  if target and not d then world.setAir(target) end
  return d
end

--- `block.is("down", "*_ore")` -- the single most common question a mining
--- or farming script asks.
function block.is(dir, pattern)
  local info = block.inspect(dir)
  if not info then return false end
  return util.glob(info.name, pattern), info
end

--- Look in all six directions and fold the result into world memory.
--- Costs up to four turns; call it once at the start of a survey loop
--- rather than per-decision.
function block.scan(opts)
  opts = opts or {}
  local out = {}
  local dirs = opts.dirs or { "forward", "right", "back", "left", "up", "down" }
  local facing = nav.facing()
  local saved = block.restoreFacing
  block.restoreFacing = false           -- one sweep, not four there-and-backs
  for _, d in ipairs(dirs) do
    local info = block.inspect(d)
    out[d] = info and info.name or false
  end
  block.restoreFacing = saved
  if facing ~= nil and saved then nav.face(facing) end
  return out
end

--------------------------------------------------------------- digging ----

--- Dig, and keep digging while gravel or sand keeps falling into the hole.
function block.dig(dir, opts)
  opts = opts or {}
  local api, target, restore, err = orient(dir)
  if not api then return false, err end
  local result, reason = false, nil

  if target then
    local rec = world.get(target)
    if rec and rec.n and nav.protected(rec.n) and not opts.force then
      if restore then restore() end
      return false, "refusing to dig protected block " .. rec.n
    end
  end

  if opts.only then
    local ok, info = api.inspect()
    if not ok or not util.glob(info.name, opts.only) then
      if restore then restore() end
      return false, "block does not match " .. tostring(opts.only)
    end
  end

  for _ = 1, (opts.tries or block.gravelTries) do
    if not api.detect() then result = true; break end
    local ok, e = api.dig(opts.side)
    reason = e
    if not ok then
      if e and e:lower():find("no tool") then caps.set("digging", false) end
      break
    end
    caps.set("digging", true)
    result = true
    if not opts.repeatWhileFalling then break end
    util.sleep(0.15)
  end

  if target then
    if api.detect() then
      local ok, info = api.inspect()
      world.set(target, ok and info and info.name or "unknown")
    else
      world.setAir(target)
    end
  end
  if restore then restore() end
  if not result then return false, reason or "nothing to dig" end
  return true
end

--- Dig every connected block matching a pattern, moving through the hole.
--- This is the "mine the whole ore vein" primitive; generated scripts get
--- vein mining for one line instead of thirty.
function block.digVein(pattern, opts)
  opts = opts or {}
  local maxBlocks = opts.max or 64
  local origin = nav.pos()
  if not origin then return false, "position not initialised" end
  local mined, seen = 0, {}
  local dirs = { "forward", "right", "back", "left", "up", "down" }

  local function recurse(depth)
    if mined >= maxBlocks then return end
    if opts.maxDepth and depth > opts.maxDepth then return end
    for _, d in ipairs(dirs) do
      if mined >= maxBlocks then return end
      local api, target, restore = orient(d)
      if api and target and not seen[geom.key(target)] then
        local ok, info = api.inspect()
        seen[geom.key(target)] = true
        if ok and info and util.glob(info.name, pattern) then
          if api.dig() then
            mined = mined + 1
            world.setAir(target)
            local moveDir = d
            if nav.step(moveDir, { dig = true }) then
              recurse(depth + 1)
              -- come back the way we came
              local backDir = ({ forward = "back", back = "forward",
                                 left = "right", right = "left",
                                 up = "down", down = "up" })[moveDir]
              nav.step(backDir, { dig = true })
            end
          end
        end
        if restore then restore() end
      end
    end
  end

  local saved = block.restoreFacing
  block.restoreFacing = false
  local ok, err = pcall(recurse, 1)
  block.restoreFacing = saved
  if origin then nav.moveTo(origin, { dig = true }) end
  if not ok then return false, err end
  return mined
end

--------------------------------------------------------------- placing ----

--- Place a block from the inventory. `spec` is any inv spec ("*_planks",
--- {tag=...}, a slot number, or nil to use the selected slot).
--- Clears the space first if `opts.replace` is set.
function block.place(dir, spec, opts)
  opts = opts or {}
  if spec ~= nil then
    local slot, err = inv.select(spec)
    if not slot then return false, err end
  end
  local api, target, restore, err = orient(dir)
  if not api then return false, err end

  if api.detect() then
    if not opts.replace then
      if restore then restore() end
      return false, "space is occupied"
    end
    api.dig()
  end

  local ok, why = api.place(opts.text)
  if ok then
    inv.invalidate()
    if target then
      local d = inv.slot(turtle.getSelectedSlot())
      world.set(target, d and d.name or "placed")
    end
  end
  if restore then restore() end
  if not ok then return false, why or "could not place" end
  return true
end

--- Fill a whole box with blocks from the inventory, walking it efficiently.
--- Skips cells that are already solid unless `replace` is set.
--- Fill a box with `spec`.
---
--- Returns placed, skipped, info. `skipped` is cells that were already
--- solid; `info` accounts for everything else that did not get placed,
--- because placed + skipped used to be all the caller saw and a cell the
--- turtle could not reach was counted in neither. Nine cells coming back
--- as "placed 0, skipped 2" reads as a job that did nothing for no
--- reason, when in fact seven moves failed and nobody said so.
---
---   info = { cells = 9, unreachable = 7, unplaceable = 0,
---            stopped = true, reason = "..." }
---
--- opts.giveUpAfter  consecutive failures before stopping (default 3);
---                   a turtle that cannot reach the first three cells is
---                   not going to reach the next five hundred.
function block.fill(cornerA, cornerB, spec, opts)
  opts = opts or {}
  local placed, skipped = 0, 0
  local info = { cells = 0, unreachable = 0, unplaceable = 0 }
  local consecutive = 0
  local limit = opts.giveUpAfter or 3

  for cell in geom.iterBox(cornerA, cornerB, { topDown = opts.topDown }) do
    info.cells = info.cells + 1
    if opts.limit and placed >= opts.limit then break end
    if world.isSolid(cell) == true and not opts.replace then
      skipped = skipped + 1
    else
      local ok, err = nav.moveTo(cell, { adjacent = true, dig = opts.dig })
      if not ok then
        if opts.strict then return false, err end
        info.unreachable = info.unreachable + 1
        info.reason = info.reason or ("could not reach " .. geom.tostring(cell) ..
                                      (err and (": " .. tostring(err)) or ""))
        consecutive = consecutive + 1
      else
        local p = nav.pos()
        local d = geom.sub(cell, p)
        local dir
        if d.y == 1 then dir = "up"
        elseif d.y == -1 then dir = "down"
        else dir = geom.FACING_NAME[geom.facingToward(p, cell)] end
        if block.place(dir, spec, { replace = opts.replace }) then
          placed = placed + 1
          consecutive = 0
        elseif opts.strict then
          return false, "could not place at " .. geom.tostring(cell)
        else
          info.unplaceable = info.unplaceable + 1
          info.reason = info.reason or ("could not place at " ..
                                        geom.tostring(cell))
          consecutive = consecutive + 1
        end
      end
    end
    if opts.onCell then opts.onCell(cell, placed) end
    if consecutive >= limit then
      info.stopped = true
      info.reason = ("gave up after %d cells in a row failed -- %s")
        :format(consecutive, info.reason or "no reason recorded")
      break
    end
  end
  return placed, skipped, info
end

--- Clear a box of blocks. The quarry/excavation primitive.
--- Excavate a box. Returns dug, info -- see block.fill for why the
--- failures are counted rather than dropped.
function block.clear(cornerA, cornerB, opts)
  opts = opts or {}
  local dug = 0
  local info = { cells = 0, unreachable = 0 }
  local consecutive = 0
  local limit = opts.giveUpAfter or 3

  for cell in geom.iterBox(cornerA, cornerB, { topDown = true }) do
    info.cells = info.cells + 1
    if world.isSolid(cell) ~= false then
      local ok, err = nav.moveTo(cell, { dig = true, box = opts.box })
      if ok then
        dug = dug + 1
        consecutive = 0
      else
        info.unreachable = info.unreachable + 1
        info.reason = info.reason or ("could not reach " .. geom.tostring(cell) ..
                                      (err and (": " .. tostring(err)) or ""))
        consecutive = consecutive + 1
      end
    end
    if opts.onCell then opts.onCell(cell, dug) end
    if opts.dumpWhenFull and inv.freeSlots() == 0 then opts.dumpWhenFull() end
    if consecutive >= limit then
      info.stopped = true
      info.reason = ("gave up after %d cells in a row failed -- %s")
        :format(consecutive, info.reason or "no reason recorded")
      break
    end
  end
  return dug, info
end

--------------------------------------------------------------- entities ---

function block.attack(dir, opts)
  opts = opts or {}
  local api, _, restore, err = orient(dir)
  if not api then return false, err end
  local hits = 0
  for _ = 1, (opts.times or 1) do
    if api.attack(opts.side) then hits = hits + 1 else break end
    util.sleep(opts.delay or 0.1)
  end
  if restore then restore() end
  return hits
end

--------------------------------------------------------------- items ------

--- Drop / suck in any of the ten directions (inv handles only the three
--- native ones; this turns for you).
function block.drop(dir, spec, opts)
  local api, _, restore, err = orient(dir)
  if not api then return false, err end
  local n = 0
  for _, e in ipairs(inv.findAll(spec)) do
    turtle.select(e.slot)
    if api.drop(opts and opts.count or nil) then n = n + (e.detail.count or 0) end
    inv.invalidate(e.slot)
  end
  inv.invalidate()
  if restore then restore() end
  return n
end

function block.suck(dir, count)
  local api, _, restore, err = orient(dir)
  if not api then return false, err end
  local pulled = 0
  for _ = 1, (count and math.ceil(count / 64) or 1) do
    if not api.suck(count) then break end
    pulled = pulled + 1
  end
  inv.invalidate()
  if restore then restore() end
  return pulled > 0
end

return block
