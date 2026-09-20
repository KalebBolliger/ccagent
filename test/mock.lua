--[[ test/mock.lua ------------------------------------------------------
  A small CC:Tweaked stand-in so the core can be exercised outside
  Minecraft: a voxel world, a turtle with an inventory and fuel, and just
  enough of fs/textutils/os to let state, world memory and the executor run.

  Run the suite with:  lua5.3 test/run.lua   (from /ccagent)
--------------------------------------------------------------------------]]

local mock = {}

local W = {}   -- "x,y,z" -> block name

local T = {
  x = 0, y = 64, z = 0, f = 0,   -- 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x)
  fuel = 20000,
  sel = 1,
  slots = {},
  hasTool = true,
}

mock.world, mock.turtle = W, T

local DELTA = { [0] = { 0, 0, -1 }, [1] = { 1, 0, 0 }, [2] = { 0, 0, 1 }, [3] = { -1, 0, 0 } }

local function key(x, y, z) return x .. "," .. y .. "," .. z end

function mock.set(x, y, z, name) W[key(x, y, z)] = name end

function mock.fill(a, b, name)
  for x = math.min(a[1], b[1]), math.max(a[1], b[1]) do
    for y = math.min(a[2], b[2]), math.max(a[2], b[2]) do
      for z = math.min(a[3], b[3]), math.max(a[3], b[3]) do
        mock.set(x, y, z, name)
      end
    end
  end
end

function mock.get(x, y, z) return W[key(x, y, z)] end

local function frontPos()
  local d = DELTA[T.f]
  return T.x + d[1], T.y, T.z + d[3]
end

local function posFor(dir)
  if dir == "up" then return T.x, T.y + 1, T.z end
  if dir == "down" then return T.x, T.y - 1, T.z end
  return frontPos()
end

---------------------------------------------------------------- turtle ----

local turtle = {}

local function move(dx, dy, dz)
  local nx, ny, nz = T.x + dx, T.y + dy, T.z + dz
  if W[key(nx, ny, nz)] then return false, "Movement obstructed" end
  if T.fuel <= 0 then return false, "Out of fuel" end
  T.x, T.y, T.z = nx, ny, nz
  T.fuel = T.fuel - 1
  return true
end

function turtle.forward() local d = DELTA[T.f]; return move(d[1], 0, d[3]) end
function turtle.back()    local d = DELTA[T.f]; return move(-d[1], 0, -d[3]) end
function turtle.up()      return move(0, 1, 0) end
function turtle.down()    return move(0, -1, 0) end
function turtle.turnLeft()  T.f = (T.f + 3) % 4; return true end
function turtle.turnRight() T.f = (T.f + 1) % 4; return true end

local function detect(dir) local x, y, z = posFor(dir); return W[key(x, y, z)] ~= nil end
function turtle.detect()     return detect("forward") end
function turtle.detectUp()   return detect("up") end
function turtle.detectDown() return detect("down") end

local function inspect(dir)
  local x, y, z = posFor(dir)
  local n = W[key(x, y, z)]
  if not n then return false, "No block to inspect" end
  return true, { name = n, state = {}, tags = {} }
end
function turtle.inspect()     return inspect("forward") end
function turtle.inspectUp()   return inspect("up") end
function turtle.inspectDown() return inspect("down") end

local function dig(dir)
  if not T.hasTool then return false, "No tool to dig with" end
  local x, y, z = posFor(dir)
  local n = W[key(x, y, z)]
  if not n then return false, "Nothing to dig here" end
  if n == "minecraft:bedrock" then return false, "Unbreakable block detected" end
  W[key(x, y, z)] = nil
  -- loot goes to the first slot that fits
  for i = 1, 16 do
    local s = T.slots[i]
    if s and s.name == n and s.count < 64 then s.count = s.count + 1; return true end
  end
  for i = 1, 16 do
    if not T.slots[i] then T.slots[i] = { name = n, count = 1 }; return true end
  end
  return true
end
function turtle.dig()     return dig("forward") end
function turtle.digUp()   return dig("up") end
function turtle.digDown() return dig("down") end

local function place(dir)
  local s = T.slots[T.sel]
  if not s or s.count <= 0 then return false, "No items to place" end
  local x, y, z = posFor(dir)
  if W[key(x, y, z)] then return false, "Cannot place block here" end
  W[key(x, y, z)] = s.name
  s.count = s.count - 1
  if s.count <= 0 then T.slots[T.sel] = nil end
  return true
end
function turtle.place()     return place("forward") end
function turtle.placeUp()   return place("up") end
function turtle.placeDown() return place("down") end

function turtle.attack()     return false, "Nothing to attack here" end
function turtle.attackUp()   return false, "Nothing to attack here" end
function turtle.attackDown() return false, "Nothing to attack here" end

function turtle.select(n) T.sel = n; return true end
function turtle.getSelectedSlot() return T.sel end
function turtle.getItemCount(n) local s = T.slots[n or T.sel]; return s and s.count or 0 end
function turtle.getItemSpace(n) local s = T.slots[n or T.sel]; return s and (64 - s.count) or 64 end
function turtle.getItemDetail(n, detailed)
  local s = T.slots[n or T.sel]
  if not s then return nil end
  local d = { name = s.name, count = s.count, damage = 0 }
  if detailed then d.tags = s.tags or {} end
  return d
end
function turtle.transferTo(dst, count)
  local src = T.slots[T.sel]
  if not src then return false end
  count = math.min(count or src.count, src.count)
  local d = T.slots[dst]
  if d and d.name ~= src.name then return false end
  if not d then T.slots[dst] = { name = src.name, count = 0 }; d = T.slots[dst] end
  local room = 64 - d.count
  local n = math.min(count, room)
  d.count = d.count + n
  src.count = src.count - n
  if src.count <= 0 then T.slots[T.sel] = nil end
  return n > 0
end
function turtle.getFuelLevel() return T.fuel end
function turtle.getFuelLimit() return 100000 end
function turtle.refuel(n)
  local s = T.slots[T.sel]
  if not s or not s.name:find("coal") then return false, "Items not combustible" end
  local burn = math.min(n or s.count, s.count)
  s.count = s.count - burn
  if s.count <= 0 then T.slots[T.sel] = nil end
  T.fuel = T.fuel + burn * 80
  return true
end
local function dropDir(dir)
  return function(n)
    local s = T.slots[T.sel]
    if not s then return false end
    local x, y, z = posFor(dir)
    n = math.min(n or s.count, s.count)
    s.count = s.count - n
    if s.count <= 0 then T.slots[T.sel] = nil end
    mock.dropped = (mock.dropped or 0) + n
    return true
  end
end
turtle.drop, turtle.dropUp, turtle.dropDown =
  dropDir("forward"), dropDir("up"), dropDir("down")
turtle.suck = function() return false end
turtle.suckUp, turtle.suckDown = turtle.suck, turtle.suck

------------------------------------------------------------ environment ---

local files = {}

local fs = {}
function fs.exists(p) return files[p] ~= nil end
function fs.getDir(p) return (p:match("^(.*)/[^/]*$")) or "" end
function fs.makeDir() end
function fs.list() return {} end
function fs.delete(p) files[p] = nil end
function fs.open(p, mode)
  if mode == "r" then
    if not files[p] then return nil end
    local data = files[p]
    return { readAll = function() return data end, close = function() end,
             readLine = function() return (data:gmatch("[^\n]+")()) end }
  end
  local buf = mode == "a" and (files[p] or "") or ""
  return {
    write = function(_, s) if s == nil then s = _ end; buf = buf .. tostring(s) end,
    writeLine = function(_, s) if s == nil then s = _ end; buf = buf .. tostring(s) .. "\n" end,
    close = function() files[p] = buf end,
  }
end
mock.files = files

-- Minimal JSON good enough for the state file.
local function encodeJSON(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "string" then return '"' .. v:gsub('[%c"\\]', function(c)
      return ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r",
                ["\t"] = "\\t" })[c] or string.format("\\u%04x", c:byte())
    end) .. '"' end
  local isArray, n = true, 0
  for k in pairs(v) do n = n + 1; if type(k) ~= "number" then isArray = false end end
  if isArray and n == #v then
    local out = {}
    for _, x in ipairs(v) do out[#out + 1] = encodeJSON(x) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local out = {}
  for k, x in pairs(v) do out[#out + 1] = encodeJSON(tostring(k)) .. ":" .. encodeJSON(x) end
  return "{" .. table.concat(out, ",") .. "}"
end

local decodeJSON
do
  local pos, src
  local function skip() pos = src:find("[^ \n\r\t]", pos) or #src + 1 end
  local function value()
    skip()
    local c = src:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local o = {}
      skip()
      if src:sub(pos, pos) == "}" then pos = pos + 1; return o end
      while true do
        skip(); local k = value(); skip()
        pos = pos + 1 -- ':'
        o[k] = value(); skip()
        local d = src:sub(pos, pos); pos = pos + 1
        if d == "}" then return o end
      end
    elseif c == "[" then
      pos = pos + 1; local a = {}
      skip()
      if src:sub(pos, pos) == "]" then pos = pos + 1; return a end
      while true do
        a[#a + 1] = value(); skip()
        local d = src:sub(pos, pos); pos = pos + 1
        if d == "]" then return a end
      end
    elseif c == '"' then
      local out, i = {}, pos + 1
      while true do
        local ch = src:sub(i, i)
        if ch == '"' then break end
        if ch == "\\" then
          local n = src:sub(i + 1, i + 1)
          out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" })[n] or n
          i = i + 2
        else out[#out + 1] = ch; i = i + 1 end
      end
      pos = i + 1
      return table.concat(out)
    elseif src:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif src:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif src:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local s, e = src:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      local num = tonumber(src:sub(s, e)); pos = e + 1; return num
    end
  end
  decodeJSON = function(s) src, pos = s, 1; return value() end
end

function mock.install()
  _G.turtle = turtle
  _G.fs = fs
  _G.textutils = {
    serialiseJSON = encodeJSON, serializeJSON = encodeJSON,
    unserialiseJSON = decodeJSON, unserializeJSON = decodeJSON,
    serialise = encodeJSON, serialize = encodeJSON,
  }
  _G.sleep = function() end
  _G.gps = nil
  _G.peripheral = { getNames = function() return {} end,
                    getType = function() return nil end,
                    find = function() return nil end }
  _G.os.epoch = function() return math.floor(os.clock() * 1000) end
  _G.parallel = nil
  return mock
end

function mock.reset()
  for k in pairs(W) do W[k] = nil end
  for k in pairs(files) do files[k] = nil end
  T.x, T.y, T.z, T.f = 0, 64, 0, 0
  T.fuel, T.sel, T.hasTool = 20000, 1, true
  T.slots = {}
  mock.dropped = 0
end

return mock
