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

-- What a hoe does to what. CC:Tweaked's TurtleTool.dig asks the tool
-- whether it has a use for the block and performs that INSTEAD of
-- breaking it, which is why tilling goes through dig and not place.
mock.toolUse = {
  ["minecraft:diamond_hoe"] = {
    ["minecraft:dirt"]       = "minecraft:farmland",
    ["minecraft:grass_block"] = "minecraft:farmland",
  },
  ["minecraft:diamond_shovel"] = {
    ["minecraft:grass_block"] = "minecraft:dirt_path",
  },
}

local function dig(dir)
  if not T.hasTool then return false, "No tool to dig with" end
  local x, y, z = posFor(dir)

  -- Tool use comes first, and consumes the dig without dropping loot.
  -- Two rules, both from CC:Tweaked's TurtleTool:
  --   * vanilla will not till a block that has anything above it, and the
  --     turtle itself is a block, so it can never till what it stands on;
  --   * digging DOWN reaches one block further when the one directly
  --     below is air, which is the only geometry that ever works.
  -- This runs BEFORE the "is there a block here" check, exactly as
  -- TurtleTool.dig does -- its own comment says the reach matters.
  local eq = T.equipped or {}
  local ux, uy, uz = x, y, z
  if dir == "down" and not W[key(x, y, z)] then uy = y - 1 end

  local target = W[key(ux, uy, uz)]
  local aboveIsTurtle = (ux == T.x and uy + 1 == T.y and uz == T.z)
  if target and not W[key(ux, uy + 1, uz)] and not aboveIsTurtle then
    for _, side in ipairs({ "left", "right" }) do
      local uses = eq[side] and mock.toolUse[eq[side]]
      if uses and uses[target] then
        W[key(ux, uy, uz)] = uses[target]
        return true
      end
    end
  end

  -- A tool that has a use for blocks but could not apply it here is also
  -- refused the fall-through break: dirt is not in a hoe's breakable tag.
  for _, side in ipairs({ "left", "right" }) do
    if eq[side] and mock.toolUse[eq[side]] then
      return false, "Cannot break block with this tool"
    end
  end

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

-- Equipping is the one operation that changes what the turtle *is*.
-- CC only gives a turtle `craft` once a crafting table is on a side, so
-- the mock adds and removes the method the same way.
-- Craft against the real grid, so tests prove the layout rather than
-- trusting it: the left 3x3 (1,2,3 / 5,6,7 / 9,10,11), positional, one
-- item per cell. Only the recipes the tests need.
function mock.craftImpl(limit)
  -- The failure seen in game: the method is callable with no crafting
  -- table attached, and returns a bare false -- no message at all, which
  -- is what distinguishes it from a genuine recipe mismatch.
  local on = T.equipped or {}
  if on.left ~= "minecraft:crafting_table"
     and on.right ~= "minecraft:crafting_table" then
    return false
  end
  -- The rule, confirmed in game: the whole inventory is the crafting
  -- area. Anything in a slot outside the 3x3 -- column 4, bottom row,
  -- anywhere -- makes the arrangement unmatchable, however correct the
  -- recipe cells are. Stacks inside the cells are fine: they craft
  -- min(cell) times.
  local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
  local inGrid = {}
  for _, slot in ipairs(GRID) do inGrid[slot] = true end
  for slot = 1, 16 do
    if T.slots[slot] and not inGrid[slot] then
      return false, "No matching recipes"
    end
  end
  local cell, counts = {}, {}
  for i, slot in ipairs(GRID) do
    local s = T.slots[slot]
    cell[i] = s and s.name or false
    counts[i] = s and s.count or 0
  end
  local function only(...)
    local set = {}
    for _, i in ipairs({ ... }) do set[i] = true end
    for i = 1, 9 do
      if set[i] and not cell[i] then return false end
      if not set[i] and cell[i] then return false end
    end
    return true
  end
  local wheat = cell[1] == "minecraft:wheat" and cell[2] == "minecraft:wheat"
                and cell[3] == "minecraft:wheat"
  if wheat and only(1, 2, 3) then
    local n = math.min(counts[1], counts[2], counts[3], limit or 64)
    if n < 1 then return false, "No matching recipes" end
    for _, slot in ipairs({ 1, 2, 3 }) do
      local s = T.slots[slot]
      s.count = s.count - n
      if s.count <= 0 then T.slots[slot] = nil end
    end
    for slot = 1, 16 do
      if not T.slots[slot] then
        T.slots[slot] = { name = "minecraft:bread", count = n }
        break
      end
    end
    mock.crafted = (mock.crafted or 0) + n
    return true
  end
  return false, "No matching recipes"
end

-- Equipping swaps: what is selected goes onto the side, what was on the
-- side comes back into that slot, so an empty selected slot unequips.
-- turtle.craft exists only while a crafting table is actually on a side,
-- which is the whole reason the capability cache has to be invalidated.
-- mock.staleCraft reproduces a build where turtle.craft outlives the
-- upgrade: the method stays callable after the table comes off.
local function syncCraft()
  T.equipped = T.equipped or {}
  if T.equipped.left == "minecraft:crafting_table"
     or T.equipped.right == "minecraft:crafting_table"
     or mock.staleCraft then
    turtle.craft = mock.craftImpl
  else
    turtle.craft = nil
  end
end

-- Newer CC can say what is on a side; older builds have no such call at
-- all. A test models the old build by removing these, which mock.reset
-- puts back -- returning nil from a present function means "nothing is
-- equipped", a different answer from "this build cannot tell you".
function mock.equippedLeft()
  local n = (T.equipped or {}).left
  -- A turtle that can dig has something to dig with. T.hasTool is what
  -- the mock's dig() consults, so the sides have to agree with it, or
  -- the capability probe and the behaviour it describes drift apart.
  if not n and T.hasTool then n = "minecraft:diamond_pickaxe" end
  return n and { name = n, count = 1 } or nil
end
function mock.equippedRight()
  local n = (T.equipped or {}).right
  return n and { name = n, count = 1 } or nil
end
turtle.getEquippedLeft, turtle.getEquippedRight =
    mock.equippedLeft, mock.equippedRight

local function equip(side)
  T.equipped = T.equipped or {}
  local held = T.slots[T.sel]
  local was = T.equipped[side]

  if not held then
    if not was then return false, "Nothing to equip" end
    T.equipped[side] = nil
    T.slots[T.sel] = { name = was, count = 1 }
    syncCraft()
    return true
  end

  -- CC:Tweaked registers every vanilla tool as a turtle upgrade, not just
  -- the pickaxe. The old list here said otherwise, which made a hoe
  -- impossible to equip in tests while working fine in the game.
  local UPGRADES = { "pickaxe", "axe", "shovel", "hoe", "sword",
                     "modem", "crafting_table" }
  local valid = false
  for _, u in ipairs(UPGRADES) do
    if held.name:find(u, 1, true) then valid = true; break end
  end
  if not valid then return false, "Not a valid upgrade" end

  if held.count > 1 then
    held.count = held.count - 1
    if was then
      local free
      for i = 1, 16 do if not T.slots[i] then free = i; break end end
      if not free then return false, "No space for the displaced tool" end
      T.slots[free] = { name = was, count = 1 }
    end
  else
    T.slots[T.sel] = was and { name = was, count = 1 } or nil
  end
  T.equipped[side] = held.name
  syncCraft()
  return true
end

function turtle.equipLeft()  return equip("left") end
function turtle.equipRight() return equip("right") end

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
-- mock.fuelNames decides what burns. It deliberately does not care what
-- the item is called in any particular mod: refuel(0) is how the game is
-- asked, and asking is the whole point.
mock.fuelNames = { "coal", "charcoal", "lignite", "lava_bucket", "_planks" }

local function burnable(name)
  for _, f in ipairs(mock.fuelNames) do
    if name:find(f, 1, true) then return true end
  end
  return false
end

function turtle.refuel(n)
  local s = T.slots[T.sel]
  if not s or not burnable(s.name) then
    return false, "Items not combustible"
  end
  if n == 0 then return true end          -- "is this fuel?", consuming none
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

----------------------------------------------------------------- http ----
-- Enough of the CC event loop and http API to drive claude/client.lua.
-- The queue is deterministic: os.pullEvent drains queued events first and
-- only then fires the earliest outstanding timer, so a scripted reply
-- always wins the race and an unscripted one always times out.

local unpack = table.unpack or unpack
local events, timers, nextTimer = {}, {}, 0

mock.http = { requests = {}, replies = {} }

--- Script the next reply.
---   mock.http.reply({ status = 200, body = "..." })       -> http_success
---   mock.http.reply({ failure = "Timed out" })            -> http_failure
---   mock.http.reply({ failure = "...", status = 429, body = "..." })
---   (script nothing at all to exercise our own timer)
function mock.http.reply(r)
  mock.http.replies[#mock.http.replies + 1] = r
end

local function handleFor(r)
  local closed = false
  return {
    getResponseCode    = function() return r.status or 200 end,
    getResponseHeaders = function() return r.headers or {} end,
    readAll            = function() return r.body or "" end,
    close              = function() closed = true end,
    isClosed           = function() return closed end,
  }
end

local http = {}

--- Blocking POST, as ui/share.lua uses. Shares the scripted-reply queue.
function http.post(url, body, headers)
  mock.http.requests[#mock.http.requests + 1] =
    { url = url, body = body, headers = headers, method = "POST" }
  local r = table.remove(mock.http.replies, 1)
  if not r then return nil, "no reply scripted" end
  if r.failure then return nil, r.failure, r.status and handleFor(r) or nil end
  return handleFor(r)
end

function http.request(opts)
  mock.http.requests[#mock.http.requests + 1] = opts
  local r = table.remove(mock.http.replies, 1)
  if not r then return true end          -- nothing queued: let it time out
  if r.failure then
    events[#events + 1] = { "http_failure", opts.url, r.failure,
                            r.status and handleFor(r) or nil }
  else
    events[#events + 1] = { "http_success", opts.url, handleFor(r) }
  end
  return true
end

local function startTimer(t)
  nextTimer = nextTimer + 1
  timers[#timers + 1] = { id = nextTimer, at = t or 0 }
  return nextTimer
end

local function cancelTimer(id)
  for i = #timers, 1, -1 do
    if timers[i].id == id then table.remove(timers, i) end
  end
end

local function queueEvent(...)
  events[#events + 1] = { ... }
end

local function pullEvent()
  local e = table.remove(events, 1)
  if e then return unpack(e) end
  -- No events left: the soonest timer is what happens next.
  local soonest
  for _, t in ipairs(timers) do
    if not soonest or t.at < soonest.at then soonest = t end
  end
  if soonest then
    cancelTimer(soonest.id)
    return "timer", soonest.id
  end
  error("mock: pullEvent with nothing queued and no timer pending", 0)
end

function mock.resetHttp()
  for i = #events, 1, -1 do events[i] = nil end
  for i = #timers, 1, -1 do timers[i] = nil end
  for i = #mock.http.requests, 1, -1 do mock.http.requests[i] = nil end
  for i = #mock.http.replies, 1, -1 do mock.http.replies[i] = nil end
end

--- Build an SSE body from a list of {event, dataTable} pairs.
function mock.sse(parts)
  local out = {}
  for _, p in ipairs(parts) do
    out[#out + 1] = ("event: %s\ndata: %s\n"):format(p[1], encodeJSON(p[2]))
  end
  return table.concat(out, "\n")
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
  _G.http = http
  _G.os.epoch        = function() return math.floor(os.clock() * 1000) end
  _G.os.startTimer   = startTimer
  _G.os.cancelTimer  = cancelTimer
  _G.os.queueEvent   = queueEvent
  _G.os.pullEvent    = pullEvent
  _G.parallel = nil
  return mock
end

function mock.reset()
  for k in pairs(W) do W[k] = nil end
  for k in pairs(files) do files[k] = nil end
  T.x, T.y, T.z, T.f = 0, 64, 0, 0
  T.fuel, T.sel, T.hasTool = 20000, 1, true
  T.slots = {}
  T.equipped = nil
  turtle.craft = nil
  mock.staleCraft = nil
  turtle.getEquippedLeft, turtle.getEquippedRight =
      mock.equippedLeft, mock.equippedRight
  mock.dropped = 0
  mock.crafted = 0
  mock.resetHttp()
end

return mock
