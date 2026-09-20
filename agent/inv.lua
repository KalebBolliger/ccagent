--[[ agent/inv.lua -------------------------------------------------------
  Inventory as a queryable model instead of sixteen numbered boxes.

  Two things make this worth abstracting:

  1. Ticks. `turtle.getItemDetail` is a server round-trip. A script that
     asks "do I have cobblestone?" by looping 1..16 and calling it does 16
     round-trips, and most scripts ask several times. This module keeps a
     cache that is invalidated only by operations that can actually change
     the inventory, so repeated queries are free.

  2. Tokens. Item matching (`"*_log"`, `{tag="minecraft:logs"}`, a predicate
     function) is written once here rather than re-derived in every
     generated script.

  Detailed lookups (which carry NBT and tags, and are noticeably slower) are
  only performed when a spec actually asks about tags.
--------------------------------------------------------------------------]]

local util = require("agent.util")
local caps = require("agent.caps")

local inv = {}

inv.SLOTS = 16

inv.fuelItems = {
  "minecraft:coal", "minecraft:charcoal", "minecraft:coal_block",
  "minecraft:lava_bucket", "minecraft:blaze_rod", "minecraft:dried_kelp_block",
  "*_planks", "*_log", "*_wood", "minecraft:stick", "minecraft:bamboo",
}

---------------------------------------------------------------- cache -----

local cache, cacheDetailed = {}, {}

function inv.invalidate(slot)
  if slot then
    cache[slot], cacheDetailed[slot] = nil, nil
  else
    cache, cacheDetailed = {}, {}
  end
end

--- Raw detail for a slot. `detailed` pulls tags/NBT (slower).
function inv.slot(n, detailed)
  if not _G.turtle then return nil end
  local store = detailed and cacheDetailed or cache
  local v = store[n]
  if v ~= nil then
    if v == false then return nil end
    return v
  end
  local d = turtle.getItemDetail(n, detailed and true or false)
  store[n] = d or false
  if d and not detailed then cache[n] = d end
  return d
end

function inv.slots(detailed)
  local out = {}
  for i = 1, inv.SLOTS do out[i] = inv.slot(i, detailed) end
  return out
end

--------------------------------------------------------------- matching ---

--- Does an item detail match a spec?
---   "minecraft:stone"      exact
---   "*log*"                glob on the item id
---   {"a","b"}              any of
---   {name="*log*", tag="minecraft:logs", min=8}
---   function(detail) -> boolean
function inv.matches(detail, spec)
  if not detail then return false end
  if spec == nil then return true end
  if type(spec) == "function" then return spec(detail) and true or false end
  if type(spec) == "string" then return util.glob(detail.name, spec) end
  if type(spec) == "table" then
    if spec[1] ~= nil then
      for _, s in ipairs(spec) do
        if inv.matches(detail, s) then return true end
      end
      return false
    end
    if spec.name and not util.glob(detail.name, spec.name) then return false end
    if spec.tag then
      local tags = detail.tags or {}
      if not tags[spec.tag] then return false end
    end
    if spec.min and (detail.count or 0) < spec.min then return false end
    if spec.damage and detail.damage ~= spec.damage then return false end
    return true
  end
  return false
end

local function needsDetail(spec)
  if type(spec) == "table" then
    if spec.tag then return true end
    if spec[1] ~= nil then
      for _, s in ipairs(spec) do if needsDetail(s) then return true end end
    end
  end
  if type(spec) == "function" then return true end
  return false
end

----------------------------------------------------------------- queries --

--- First slot holding a matching item, or nil.
function inv.find(spec, opts)
  opts = opts or {}
  local detailed = needsDetail(spec)
  local from, to = opts.from or 1, opts.to or inv.SLOTS
  for i = from, to do
    local d = inv.slot(i, detailed)
    if d and inv.matches(d, spec) then return i, d end
  end
  return nil
end

function inv.findAll(spec)
  local detailed = needsDetail(spec)
  local out = {}
  for i = 1, inv.SLOTS do
    local d = inv.slot(i, detailed)
    if d and inv.matches(d, spec) then out[#out + 1] = { slot = i, detail = d } end
  end
  return out
end

--- Total item count matching a spec (0 if none).
function inv.count(spec)
  local n = 0
  for _, e in ipairs(inv.findAll(spec)) do n = n + (e.detail.count or 0) end
  return n
end

function inv.has(spec, atLeast)
  return inv.count(spec) >= (atLeast or 1)
end

function inv.freeSlots()
  local n = 0
  for i = 1, inv.SLOTS do if not inv.slot(i) then n = n + 1 end end
  return n
end

function inv.firstFreeSlot()
  for i = 1, inv.SLOTS do if not inv.slot(i) then return i end end
  return nil
end

function inv.isFull() return inv.freeSlots() == 0 end

function inv.isEmpty() return inv.freeSlots() == inv.SLOTS end

--- Distinct item names currently carried, with counts.
function inv.contents()
  local tally = {}
  for i = 1, inv.SLOTS do
    local d = inv.slot(i)
    if d then tally[d.name] = (tally[d.name] or 0) + (d.count or 0) end
  end
  return tally
end

--- Compact one-liner for prompts: "cobblestone x183 oak_log x24 (5 free)".
function inv.summary(limit)
  local tally = inv.contents()
  local list = {}
  for name, c in pairs(tally) do list[#list + 1] = { name = name, c = c } end
  table.sort(list, function(a, b) return a.c > b.c end)
  local out = {}
  for i = 1, math.min(#list, limit or 10) do
    out[#out + 1] = list[i].name:gsub("^minecraft:", "") .. " x" .. list[i].c
  end
  if #list > (limit or 10) then out[#out + 1] = ("+%d more"):format(#list - (limit or 10)) end
  if #out == 0 then out[1] = "empty" end
  return table.concat(out, ", ") .. (" (%d free slots)"):format(inv.freeSlots())
end

---------------------------------------------------------------- actions ---

--- Select the slot holding a matching item. Returns slot or false, reason.
function inv.select(spec)
  if not _G.turtle then return false, "not a turtle" end
  if type(spec) == "number" then
    turtle.select(spec)
    return spec
  end
  local slot = inv.find(spec)
  if not slot then
    return false, ("no item matching %s in inventory"):format(
      type(spec) == "string" and spec or "spec")
  end
  turtle.select(slot)
  return slot
end

--- Merge partial stacks so free slots are actually free.
function inv.consolidate()
  if not _G.turtle then return false end
  local moved = 0
  for dst = 1, inv.SLOTS do
    local d = inv.slot(dst)
    if d and turtle.getItemSpace(dst) > 0 then
      for src = dst + 1, inv.SLOTS do
        local s = inv.slot(src)
        if s and s.name == d.name then
          turtle.select(src)
          if turtle.transferTo(dst) then moved = moved + 1 end
          inv.invalidate(src); inv.invalidate(dst)
          d = inv.slot(dst)
          if not d or turtle.getItemSpace(dst) == 0 then break end
        end
      end
    end
  end
  inv.invalidate()
  return moved
end

local DIROPS = {
  forward = { drop = function(n) return turtle.drop(n) end,
              suck = function(n) return turtle.suck(n) end },
  up      = { drop = function(n) return turtle.dropUp(n) end,
              suck = function(n) return turtle.suckUp(n) end },
  down    = { drop = function(n) return turtle.dropDown(n) end,
              suck = function(n) return turtle.suckDown(n) end },
}

--- Drop matching items in a direction ("forward"/"up"/"down"). Into a chest
--- if one is there, onto the floor otherwise -- that is Minecraft's call,
--- not ours.
--- `keep` is a spec (or count map) of things to hold back.
function inv.drop(dir, spec, opts)
  opts = opts or {}
  local ops = DIROPS[tostring(dir):lower()]
  if not ops then return false, "drop direction must be forward, up or down" end
  local dropped = 0
  for _, e in ipairs(inv.findAll(spec)) do
    local keepN = 0
    if opts.keep then keepN = opts.keep end
    local avail = (e.detail.count or 0) - keepN
    if opts.limit then avail = math.min(avail, opts.limit - dropped) end
    if avail > 0 then
      turtle.select(e.slot)
      local ok = ops.drop(avail)
      if ok then dropped = dropped + avail end
      inv.invalidate(e.slot)
    end
    if opts.limit and dropped >= opts.limit then break end
  end
  inv.invalidate()
  return dropped
end

--- Pull items in. Repeats until the target count is reached or the source
--- runs dry.
function inv.suck(dir, count, opts)
  opts = opts or {}
  local ops = DIROPS[tostring(dir):lower()]
  if not ops then return false, "suck direction must be forward, up or down" end
  local before = inv.count(opts.spec)
  local pulls = 0
  while true do
    if inv.isFull() then break end
    local ok = ops.suck(opts.perPull)
    inv.invalidate()
    if not ok then break end
    pulls = pulls + 1
    if count and (inv.count(opts.spec) - before) >= count then break end
    if pulls > (opts.maxPulls or 64) then break end
  end
  return inv.count(opts.spec) - before
end

--- Dump everything except what you want to keep. The standard "come back
--- to base and unload" move.
function inv.deposit(dir, opts)
  opts = opts or {}
  local keep = opts.keep      -- spec of items to retain
  local total = 0
  for i = 1, inv.SLOTS do
    local d = inv.slot(i)
    if d and not (keep and inv.matches(d, keep)) then
      local ops = DIROPS[tostring(dir):lower()]
      if not ops then return false, "bad direction" end
      turtle.select(i)
      local n = d.count or 0
      if ops.drop() then total = total + n end
      inv.invalidate(i)
    end
  end
  inv.invalidate()
  return total
end

---------------------------------------------------------------- fuel ------

--- Burn fuel from the inventory until the level reaches `target`.
--- Returns the new fuel level.
function inv.refuel(target, opts)
  opts = opts or {}
  if not _G.turtle then return 0 end
  if caps.get("unlimitedFuel") then return math.huge end
  target = target or 1000
  local base = opts.spec or inv.fuelItems
  local rejected = {}   -- items that looked like fuel but the game refused
  local spec = function(d)
    return not rejected[d.name] and inv.matches(d, base)
  end
  local guard = 0
  while turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < target do
    guard = guard + 1
    if guard > inv.SLOTS * 4 then break end
    local slot, detail = inv.find(spec)
    if not slot then break end
    turtle.select(slot)
    local burned = turtle.refuel(opts.perItem or 1)
    inv.invalidate(slot)
    if not burned and detail then rejected[detail.name] = true end
  end
  local lvl = turtle.getFuelLevel()
  return lvl == "unlimited" and math.huge or lvl
end

function inv.fuelValue()
  -- Rough estimate of how far the carried fuel would take us.
  local per = { coal = 80, charcoal = 80, coal_block = 800, lava_bucket = 1000,
                planks = 15, log = 15, stick = 5, blaze_rod = 120,
                dried_kelp_block = 400, bamboo = 2 }
  local total = 0
  for name, c in pairs(inv.contents()) do
    for key, v in pairs(per) do
      if util.glob(name, "*" .. key) then total = total + c * v; break end
    end
  end
  return total
end

--------------------------------------------------- external inventories ---

--- Wrap an adjacent or networked inventory peripheral by name or type.
--- Returns the peripheral, which exposes list()/pushItems()/pullItems().
function inv.peripheralInventory(nameOrType)
  if not _G.peripheral then return nil, "no peripheral API" end
  local p = peripheral.wrap(nameOrType)
  if p and p.list then return p end
  p = peripheral.find(nameOrType or "inventory")
  if p and p.list then return p end
  return nil, "no inventory peripheral matching " .. tostring(nameOrType)
end

--- Summarise a chest's contents without moving a single item.
function inv.listExternal(nameOrType)
  local p, err = inv.peripheralInventory(nameOrType)
  if not p then return nil, err end
  local tally = {}
  for _, item in pairs(p.list()) do
    tally[item.name] = (tally[item.name] or 0) + item.count
  end
  return tally
end

return inv
