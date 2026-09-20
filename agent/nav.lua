--[[ agent/nav.lua -------------------------------------------------------
  Position tracking, movement, and pathfinding.

  The single most expensive thing a naive LLM-written turtle program does is
  re-invent movement: "turn left, forward, forward, if blocked dig, ..." in
  every script, in tokens, every time. Everything in this file exists so a
  generated script can instead say:

      nav.moveTo({x=104, y=64, z=-31})
      nav.face("east")
      nav.goHome()

  and get obstacle avoidance, gravel handling, mob shoving, fuel top-ups,
  world-memory updates, and crash recovery for free.

  Coordinates are absolute (GPS) when a GPS constellation is reachable, and
  otherwise a local frame anchored where the turtle first booted. Either
  way the numbers are stable across reboots because position is persisted.
--------------------------------------------------------------------------]]

local util  = require("agent.util")
local geom  = require("agent.geom")
local state = require("agent.state")
local world = require("agent.world")
local caps  = require("agent.caps")

local nav = {}

--------------------------------------------------------------- policy -----

nav.policy = {
  dig        = true,    -- may break blocks that are in the way
  attack     = true,    -- may hit entities that are in the way
  tries      = 6,       -- retries per blocked step (gravel, mobs, players)
  waitPerTry = 0.4,     -- seconds between retries
  fuelFloor  = 64,      -- refuel when below this before a long move
  maxNodes   = 12000,   -- A* expansion cap; keeps the server tick sane
  replans    = 4,       -- path recalculations before giving up
  -- Never dug through, even when dig = true. Extend freely.
  protect = {
    "minecraft:bedrock", "*shulker_box*", "*chest*", "*barrel*",
    "*spawner*", "*command_block*", "*portal*", "computercraft:*",
  },
}

function nav.protected(name)
  if not name then return false end
  for _, pat in ipairs(nav.policy.protect) do
    if util.glob(name, pat) then return true end
  end
  return false
end

------------------------------------------------------------- position -----

local function loadPose()
  local p = state.get("pose")
  if p and p.x then return p end
  return nil
end

function nav.pose()
  return loadPose()
end

function nav.pos()
  local p = loadPose()
  if not p then return nil end
  return { x = p.x, y = p.y, z = p.z }
end

function nav.facing()
  local p = loadPose()
  return p and p.f or nil
end

function nav.facingName()
  local f = nav.facing()
  return f and geom.FACING_NAME[f] or "unknown"
end

function nav.setPose(p, facing, frame)
  local cur = loadPose() or {}
  state.set("pose", {
    x = p.x, y = p.y, z = p.z,
    f = (facing or cur.f or geom.NORTH) % 4,
    frame = frame or cur.frame or "local",
  })
  return nav.pose()
end

local function bumpPose(dx, dy, dz, df)
  local p = loadPose()
  if not p then return end
  p.x, p.y, p.z = p.x + (dx or 0), p.y + (dy or 0), p.z + (dz or 0)
  if df then p.f = (p.f + df) % 4 end
  state.setLazy("pose", p)
end

function nav.frame()
  local p = loadPose()
  return p and p.frame or "none"
end

--------------------------------------------------------------- fuel -------

function nav.fuel()
  if not _G.turtle then return math.huge end
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end

--- Hook point: nav does not know how to refuel, inventory does. init.lua
--- wires inv.refuel in here so nav stays independent of it.
nav.refuelHook = nil

function nav.ensureFuel(needed)
  needed = needed or nav.policy.fuelFloor
  if nav.fuel() >= needed then return true end
  if nav.refuelHook then
    nav.refuelHook(needed)
  end
  if nav.fuel() >= needed then return true end
  return false, ("out of fuel (have %s, need %d)"):format(tostring(nav.fuel()), needed)
end

------------------------------------------------------- primitive moves ----

local MOVE = {
  forward = { fn = function() return turtle.forward() end,
              detect = function() return turtle.detect() end,
              dig = function() return turtle.dig() end,
              attack = function() return turtle.attack() end,
              inspect = function() return turtle.inspect() end },
  up      = { fn = function() return turtle.up() end,
              detect = function() return turtle.detectUp() end,
              dig = function() return turtle.digUp() end,
              attack = function() return turtle.attackUp() end,
              inspect = function() return turtle.inspectUp() end },
  down    = { fn = function() return turtle.down() end,
              detect = function() return turtle.detectDown() end,
              dig = function() return turtle.digDown() end,
              attack = function() return turtle.attackDown() end,
              inspect = function() return turtle.inspectDown() end },
  back    = { fn = function() return turtle.back() end },
}

local function deltaFor(kind, facing)
  if kind == "up"   then return { x = 0, y =  1, z = 0 } end
  if kind == "down" then return { x = 0, y = -1, z = 0 } end
  local d = geom.FACING_DELTA[facing]
  if kind == "back" then return { x = -d.x, y = 0, z = -d.z } end
  return { x = d.x, y = 0, z = d.z }
end

--- The one place a turtle actually moves. Handles the full blocked-step
--- protocol and keeps pose + world memory in sync.
local function rawMove(kind, opts)
  if not _G.turtle then return false, "not a turtle" end
  opts = opts or {}
  local m = MOVE[kind]
  if not m then return false, "bad direction " .. tostring(kind) end

  local mayDig    = opts.dig    ~= false and nav.policy.dig
  local mayAttack = opts.attack ~= false and nav.policy.attack
  local tries     = opts.tries or nav.policy.tries

  local pos, facing = nav.pos(), nav.facing()
  local target = pos and geom.add(pos, deltaFor(kind, facing or 0)) or nil

  for attempt = 1, tries do
    if nav.fuel() <= 0 then
      local ok = nav.ensureFuel(1)
      if not ok then return false, "out of fuel" end
    end

    local moved, err = m.fn()
    if moved then
      local d = deltaFor(kind, facing or 0)
      bumpPose(d.x, d.y, d.z, nil)
      if target then world.setAir(target) end
      return true
    end

    -- `back` is blind: no detect/dig/attack facing backwards. Turn around,
    -- clear the way properly, and come back.
    if kind == "back" then
      nav.turnRight(); nav.turnRight()
      local ok2, why = rawMove("forward", opts)
      nav.turnRight(); nav.turnRight()
      if ok2 then return true end
      return false, why
    end

    if m.detect() then
      local okI, info = m.inspect()
      local name = okI and info and info.name or nil
      if target then world.set(target, name or "unknown") end
      if name and nav.protected(name) then
        return false, ("blocked by protected block %s"):format(name)
      end
      if not mayDig then
        return false, ("blocked by %s (digging disabled)"):format(name or "a block")
      end
      if caps.get("digging") == false then
        return false, "blocked and this turtle has no digging tool"
      end
      local dug, digErr = m.dig()
      if not dug then
        if digErr and digErr:lower():find("no tool") then
          caps.set("digging", false)
          return false, "no digging tool equipped"
        end
        if digErr and digErr:lower():find("unbreakable") then
          return false, "unbreakable block in the way"
        end
      else
        caps.set("digging", true)
      end
    elseif mayAttack then
      -- Nothing detected but the move failed: an entity, or a player.
      m.attack()
    end

    util.sleep(opts.waitPerTry or nav.policy.waitPerTry)
    if attempt == tries then
      return false, err or "blocked after " .. tries .. " attempts"
    end
  end
  return false, "blocked"
end

function nav.forward(opts) return rawMove("forward", opts) end
function nav.up(opts)      return rawMove("up", opts) end
function nav.down(opts)    return rawMove("down", opts) end
function nav.back(opts)    return rawMove("back", opts) end

function nav.turnLeft()
  if not _G.turtle then return false end
  local ok = turtle.turnLeft()
  if ok then bumpPose(0, 0, 0, -1) end
  return ok
end

function nav.turnRight()
  if not _G.turtle then return false end
  local ok = turtle.turnRight()
  if ok then bumpPose(0, 0, 0, 1) end
  return ok
end

function nav.turnAround()
  return nav.turnRight() and nav.turnRight()
end

--- Face an absolute heading (0-3), a compass word, or a relative word.
function nav.face(dir)
  local cur = nav.facing()
  if cur == nil then return false, "position not initialised (call nav.calibrate)" end
  local want
  if type(dir) == "number" then
    want = dir % 4
  elseif geom.NAME_FACING[tostring(dir):lower()] then
    want = geom.NAME_FACING[tostring(dir):lower()]
  else
    local _, f = geom.resolve(dir, cur)
    want = f
  end
  if want == nil then return false, "cannot face " .. tostring(dir) end
  local n, side = geom.turnsBetween(cur, want)
  for _ = 1, n do
    if side == "left" then nav.turnLeft() else nav.turnRight() end
  end
  return true
end

--- Face a position and be ready to act on it (used by block/inv helpers).
function nav.faceToward(target)
  local p = nav.pos()
  if not p then return false, "position not initialised" end
  local f = geom.facingToward(p, target)
  if not f then return false, "target is directly above/below or at our position" end
  return nav.face(f)
end

--- Move one block in any direction word, turning first if needed.
function nav.step(dir, opts)
  dir = tostring(dir):lower()
  if dir == "up" or dir == "down" then return rawMove(dir, opts) end
  if dir == "forward" then return rawMove("forward", opts) end
  if dir == "back" and (opts and opts.noTurn) then return rawMove("back", opts) end
  local ok, err = nav.face(dir)
  if not ok then return false, err end
  return rawMove("forward", opts)
end

--------------------------------------------------------- calibration ------

--- Establish absolute coordinates and heading using GPS. Costs up to two
--- moves. Falls back to a local frame if there is no GPS.
function nav.calibrate(opts)
  opts = opts or {}
  if not _G.turtle then return false, "not a turtle" end

  if not _G.gps then return nav.localFrame() end
  local x, y, z = gps.locate(opts.timeout or 3)
  if not x then
    if opts.requireGPS then return false, "no GPS fix" end
    return nav.localFrame()
  end
  local start = geom.v(x, y, z)

  -- If we already know our heading and GPS agrees with our tracked position,
  -- nothing to do.
  local pose = loadPose()
  if pose and pose.frame == "gps" and geom.eq(pose, start) and not opts.force then
    return true, nav.pose()
  end

  nav.setPose(start, pose and pose.f or geom.NORTH, "gps")

  -- Derive heading: move one block, compare, move back.
  local moved, undo = false, nil
  for _, try in ipairs({ "forward", "back" }) do
    local ok = (try == "forward") and turtle.forward() or turtle.back()
    if ok then moved, undo = true, try; break end
  end
  if not moved then
    -- Boxed in horizontally: try shuffling up, then re-run.
    if turtle.up() then
      local ok2, res = nav.calibrate({ timeout = opts.timeout, force = true })
      turtle.down()
      nav.setPose(start, nav.facing(), "gps")
      return ok2, res
    end
    return false, "cannot calibrate heading: turtle is boxed in"
  end

  local x2, y2, z2 = gps.locate(opts.timeout or 3)
  if undo == "forward" then turtle.back() else turtle.forward() end
  if not x2 then return false, "lost GPS mid-calibration" end

  local d = geom.sub(geom.v(x2, y2, z2), start)
  if undo == "back" then d = { x = -d.x, y = -d.y, z = -d.z } end
  local f
  if     d.x ==  1 then f = geom.EAST
  elseif d.x == -1 then f = geom.WEST
  elseif d.z ==  1 then f = geom.SOUTH
  elseif d.z == -1 then f = geom.NORTH
  else return false, "calibration move produced no horizontal displacement" end

  nav.setPose(start, f, "gps")
  state.flush()
  return true, nav.pose()
end

--- No GPS: anchor a private coordinate system here. Everything else in the
--- library works identically, the numbers just are not shared with the world.
---
--- Establishing a NEW local frame stamps a fresh id. This matters more than
--- it looks: a saved routine holding literal coordinates was written against
--- one local frame, and if the turtle is later re-placed and boots a new one,
--- those same numbers point somewhere else entirely. Nothing would throw --
--- the turtle would confidently drive to the wrong place. The id is what
--- lets lib.run catch that.
function nav.localFrame(origin, facing)
  local pose = loadPose()
  if pose and pose.frame == "local" and not origin then return true, pose end
  nav.setPose(origin or geom.v(0, 0, 0), facing or geom.NORTH, "local")
  state.set("frameId", ("local:%s:%s"):format(
    tostring(_G.os and os.getComputerID and os.getComputerID() or 0),
    tostring(util.now())))
  state.flush()
  return true, nav.pose()
end

--- Identity of the coordinate system the turtle is currently using.
--- GPS coordinates are globally consistent, so every GPS frame is the same
--- frame. Local frames are only comparable to themselves.
function nav.frameId()
  local p = loadPose()
  if not p then return nil end
  if p.frame == "gps" then return "gps" end
  return state.get("frameId") or "local:unknown"
end

--- Make sure we have *some* usable frame. Called by init and by moveTo.
function nav.ready()
  if nav.pos() then return true end
  return nav.calibrate()
end

------------------------------------------------------------- home ---------

function nav.setHome(p)
  p = p or nav.pos()
  if not p then return false, "no position" end
  state.set("home", { x = p.x, y = p.y, z = p.z, f = nav.facing() })
  state.flush()
  return true, p
end

function nav.home()
  return state.get("home")
end

function nav.goHome(opts)
  local h = nav.home()
  if not h then return false, "no home set (nav.setHome())" end
  local ok, err = nav.moveTo(h, opts)
  if ok and h.f then nav.face(h.f) end
  return ok, err
end

--------------------------------------------------------- pathfinding ------

local Heap = {}
Heap.__index = Heap

function Heap.new()
  return setmetatable({ n = 0, items = {} }, Heap)
end

function Heap:push(item, pri)
  self.n = self.n + 1
  self.items[self.n] = { item = item, pri = pri }
  local i = self.n
  while i > 1 do
    local p = math.floor(i / 2)
    if self.items[p].pri <= self.items[i].pri then break end
    self.items[p], self.items[i] = self.items[i], self.items[p]
    i = p
  end
end

function Heap:pop()
  if self.n == 0 then return nil end
  local top = self.items[1]
  self.items[1] = self.items[self.n]
  self.items[self.n] = nil
  self.n = self.n - 1
  local i = 1
  while true do
    local l, r, best = i * 2, i * 2 + 1, i
    if l <= self.n and self.items[l].pri < self.items[best].pri then best = l end
    if r <= self.n and self.items[r].pri < self.items[best].pri then best = r end
    if best == i then break end
    self.items[best], self.items[i] = self.items[i], self.items[best]
    i = best
  end
  return top.item
end

--- Cost of entering a cell given what we remember about it.
--- nil means impassable.
local function enterCost(p, opts)
  if opts.box and not geom.inBox(p, opts.box[1], opts.box[2]) then return nil end
  if opts.blocked and opts.blocked(p) then return nil end
  local rec = world.get(p)
  if not rec then return 1 end              -- unknown: assume open
  if rec.n == false then return 1 end       -- known air
  if nav.protected(rec.n) then return nil end
  if not opts.dig then return nil end
  if rec.hard then return nil end
  return 4                                  -- known solid, but we can dig it
end

--- A* from `from` to `to`. Returns a list of positions (excluding `from`).
function nav.findPath(from, to, opts)
  opts = opts or {}
  if opts.dig == nil then opts.dig = nav.policy.dig end
  local maxNodes = opts.maxNodes or nav.policy.maxNodes
  local goalKey = geom.key(to)

  local open = Heap.new()
  local gScore, cameFrom, closed = {}, {}, {}
  local startKey = geom.key(from)
  gScore[startKey] = 0
  open:push(from, geom.manhattan(from, to))

  local expanded = 0
  while true do
    local cur = open:pop()
    if not cur then break end
    local ck = geom.key(cur)
    if not closed[ck] then
      closed[ck] = true
      if ck == goalKey then
        local path, k = {}, ck
        while k ~= startKey do
          table.insert(path, 1, geom.fromKey(k))
          k = cameFrom[k]
          if not k then return nil, "path reconstruction failed" end
        end
        return path
      end
      expanded = expanded + 1
      if expanded > maxNodes then
        return nil, "no path found within search limit"
      end
      for _, nb in ipairs(geom.neighbours(cur)) do
        local nk = geom.key(nb)
        if not closed[nk] then
          local step = (nk == goalKey) and 1 or enterCost(nb, opts)
          if nk == goalKey and enterCost(nb, opts) == nil
             and not opts.enterGoalAnyway then
            step = nil
          end
          if step then
            local tentative = gScore[ck] + step
            if gScore[nk] == nil or tentative < gScore[nk] then
              gScore[nk] = tentative
              cameFrom[nk] = ck
              open:push(nb, tentative + geom.manhattan(nb, to))
            end
          end
        end
      end
    end
  end
  return nil, "no path found"
end

--- Walk a precomputed path, one step per cell. Stops at the first failure
--- and reports where.
function nav.follow(path, opts)
  opts = opts or {}
  for i, cell in ipairs(path) do
    local p = nav.pos()
    if not p then return false, "lost position" end
    local d = geom.sub(cell, p)
    local dir
    if d.y == 1 and d.x == 0 and d.z == 0 then dir = "up"
    elseif d.y == -1 and d.x == 0 and d.z == 0 then dir = "down"
    elseif d.y == 0 then
      local f = geom.facingToward(p, cell)
      if not f then return false, "path contains a non-adjacent step" end
      dir = geom.FACING_NAME[f]
    else
      return false, "path contains a diagonal step"
    end
    local ok, err = nav.step(dir, opts)
    if not ok then
      return false, err, i, cell
    end
    if opts.onStep then opts.onStep(nav.pos(), i, #path) end
  end
  return true
end

--- The workhorse. Plan, walk, and replan when reality disagrees.
---
---   opts.dig       may break blocks (default nav.policy.dig)
---   opts.box       {cornerA, cornerB} confine the search
---   opts.blocked   function(pos) -> true to treat as impassable
---   opts.adjacent  stop on any cell next to the target instead of on it
---   opts.onStep    progress callback(pos, i, total)
function nav.moveTo(target, opts)
  opts = opts or {}
  local ok, err = nav.ready()
  if not ok then return false, err end

  local goal = geom.copy(target)
  if opts.adjacent then
    -- Pick the neighbour of the target that is cheapest to stand in.
    local best, bestCost
    for _, nb in ipairs(geom.neighbours(goal)) do
      local c = enterCost(nb, { dig = opts.dig ~= false and nav.policy.dig, box = opts.box })
      if c then
        local d = geom.manhattan(nav.pos(), nb) + c
        if not bestCost or d < bestCost then best, bestCost = nb, d end
      end
    end
    if not best then return false, "nowhere to stand next to the target" end
    goal = best
  end

  if geom.eq(nav.pos(), goal) then return true end

  local budget = geom.manhattan(nav.pos(), goal)
  if not nav.ensureFuel(math.max(budget * 2, nav.policy.fuelFloor)) then
    -- Not fatal: we may still make it. Warn and continue.
    util.log.warn("low fuel (%s) for a %d-block move", tostring(nav.fuel()), budget)
  end

  for attempt = 1, (opts.replans or nav.policy.replans) + 1 do
    local path, perr = nav.findPath(nav.pos(), goal, opts)
    if not path then
      return false, perr or "no path"
    end
    local fok, ferr, idx, cell = nav.follow(path, opts)
    if fok then
      state.flush()
      return true
    end
    -- Record the obstruction so the next plan routes around it, then retry.
    if cell then
      local rec = world.get(cell)
      world.set(cell, rec and rec.n or "unknown",
                { hard = (ferr or ""):find("protected") ~= nil
                      or (ferr or ""):find("unbreakable") ~= nil })
    end
    if attempt > (opts.replans or nav.policy.replans) then
      state.flush()
      return false, ("stuck at step %d/%d: %s"):format(idx or 0, #path, ferr or "?")
    end
    util.log.debug("replanning (%s)", tostring(ferr))
  end
  return false, "gave up"
end

--- Convenience: relative move without pathfinding intent.
function nav.moveBy(dx, dy, dz, opts)
  local p = nav.pos()
  if not p then return false, "position not initialised" end
  return nav.moveTo({ x = p.x + dx, y = p.y + dy, z = p.z + dz }, opts)
end

function nav.distanceTo(p)
  local cur = nav.pos()
  if not cur then return nil end
  return geom.manhattan(cur, p)
end

--- Compact status line for prompts and the controller UI.
function nav.status()
  local p = nav.pos()
  return ("%s | fuel %s | frame %s"):format(
    p and geom.tostring(p, nav.facing()) or "position unknown",
    nav.fuel() == math.huge and "unlimited" or tostring(nav.fuel()),
    nav.frame())
end

return nav
