--[[ agent/geom.lua ------------------------------------------------------
  Coordinate and heading math. Minecraft convention:
    facing 0 = north = -Z    1 = east = +X
           2 = south = +Z    3 = west = -X
  Positions are plain tables {x=,y=,z=} so they serialise cleanly and can be
  written literally in generated scripts.
--------------------------------------------------------------------------]]

local geom = {}

geom.NORTH, geom.EAST, geom.SOUTH, geom.WEST = 0, 1, 2, 3

geom.FACING_NAME   = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }
geom.NAME_FACING   = { north = 0, east = 1, south = 2, west = 3 }
geom.FACING_DELTA  = {
  [0] = { x =  0, y = 0, z = -1 },
  [1] = { x =  1, y = 0, z =  0 },
  [2] = { x =  0, y = 0, z =  1 },
  [3] = { x = -1, y = 0, z =  0 },
}

--- Every direction word the rest of the library accepts.
geom.RELATIVE = { forward = true, back = true, left = true, right = true,
                  up = true, down = true }
geom.ABSOLUTE = { north = true, east = true, south = true, west = true }

function geom.v(x, y, z) return { x = x, y = y, z = z } end

function geom.copy(p) return { x = p.x, y = p.y, z = p.z } end

function geom.add(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end

function geom.sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end

function geom.eq(a, b)
  return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

function geom.key(p) return p.x .. "," .. p.y .. "," .. p.z end

function geom.fromKey(k)
  local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
  if not x then return nil end
  return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

function geom.tostring(p, facing)
  if not p then return "unknown" end
  local s = ("%d,%d,%d"):format(p.x, p.y, p.z)
  if facing then s = s .. " facing " .. (geom.FACING_NAME[facing] or "?") end
  return s
end

--- Manhattan distance: the real cost for a turtle, which cannot move
--- diagonally.
function geom.manhattan(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

function geom.ahead(p, facing, n)
  local d = geom.FACING_DELTA[facing % 4]
  n = n or 1
  return { x = p.x + d.x * n, y = p.y, z = p.z + d.z * n }
end

--- Number of turns (and their sign) to get from one heading to another.
--- Returns count 0..2 and "left"/"right"/nil.
function geom.turnsBetween(from, to)
  local diff = (to - from) % 4
  if diff == 0 then return 0, nil end
  if diff == 1 then return 1, "right" end
  if diff == 3 then return 1, "left" end
  return 2, "right"
end

--- Heading you would need to face to step from `a` toward `b` horizontally.
function geom.facingToward(a, b)
  local dx, dz = b.x - a.x, b.z - a.z
  if math.abs(dx) >= math.abs(dz) then
    if dx > 0 then return geom.EAST elseif dx < 0 then return geom.WEST end
  end
  if dz > 0 then return geom.SOUTH elseif dz < 0 then return geom.NORTH end
  return nil
end

--- Resolve any direction word into an absolute offset, given a heading.
--- Accepts forward/back/left/right/up/down and north/east/south/west.
--- Returns delta, and (for horizontal dirs) the facing it corresponds to.
function geom.resolve(dir, facing)
  dir = tostring(dir):lower()
  if dir == "up"   then return { x = 0, y =  1, z = 0 }, nil end
  if dir == "down" then return { x = 0, y = -1, z = 0 }, nil end
  local f
  if geom.NAME_FACING[dir] then
    f = geom.NAME_FACING[dir]
  elseif dir == "forward" then f = facing
  elseif dir == "back"    then f = (facing + 2) % 4
  elseif dir == "left"    then f = (facing + 3) % 4
  elseif dir == "right"   then f = (facing + 1) % 4
  else return nil, nil end
  return geom.FACING_DELTA[f % 4], f % 4
end

--- The six neighbours of a position, in a stable order.
function geom.neighbours(p)
  return {
    { x = p.x,     y = p.y,     z = p.z - 1 },
    { x = p.x + 1, y = p.y,     z = p.z     },
    { x = p.x,     y = p.y,     z = p.z + 1 },
    { x = p.x - 1, y = p.y,     z = p.z     },
    { x = p.x,     y = p.y + 1, z = p.z     },
    { x = p.x,     y = p.y - 1, z = p.z     },
  }
end

--- Normalise a pair of corners into min/max corners.
function geom.box(a, b)
  return
    { x = math.min(a.x, b.x), y = math.min(a.y, b.y), z = math.min(a.z, b.z) },
    { x = math.max(a.x, b.x), y = math.max(a.y, b.y), z = math.max(a.z, b.z) }
end

--- Iterate a box in a turtle-friendly order: layer by layer, boustrophedon
--- within each layer, so consecutive positions are adjacent.
---
--- Genuinely lazy. The obvious version builds the whole list first and hands
--- back a closure over it, which is invisible at 5x5x5 and a problem at
--- 48x48x48: a hundred thousand table allocations in one stretch, before the
--- turtle has dug a single block, on a runtime that kills a computer for
--- going ten seconds without yielding. Constant memory instead, and the
--- first cell comes back immediately.
function geom.iterBox(a, b, opts)
  opts = opts or {}
  local lo, hi = geom.box(a, b)
  local stepY = opts.topDown and -1 or 1
  local lastY = opts.topDown and lo.y or hi.y
  local y = opts.topDown and hi.y or lo.y
  local x = lo.x
  local flip, done = false, false
  local z, zEnd, zStep

  local function startColumn()
    if flip then z, zEnd, zStep = hi.z, lo.z, -1
    else         z, zEnd, zStep = lo.z, hi.z,  1 end
  end
  startColumn()

  return function()
    if done then return nil end
    local cell = { x = x, y = y, z = z }
    if z == zEnd then
      flip = not flip
      if x == hi.x then
        x = lo.x
        if y == lastY then done = true else y = y + stepY end
      else
        x = x + 1
      end
      startColumn()
    else
      z = z + zStep
    end
    return cell
  end
end

function geom.boxVolume(a, b)
  local lo, hi = geom.box(a, b)
  return (hi.x - lo.x + 1) * (hi.y - lo.y + 1) * (hi.z - lo.z + 1)
end

function geom.inBox(p, a, b)
  local lo, hi = geom.box(a, b)
  return p.x >= lo.x and p.x <= hi.x
     and p.y >= lo.y and p.y <= hi.y
     and p.z >= lo.z and p.z <= hi.z
end

return geom
