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

------------------------------------------------------------- crafting ----

-- A turtle crafts from the left 3x3 of its 4x4 inventory. The fourth
-- column is not part of the grid, which is what makes crafting fiddly:
-- ingredients sitting in slots 4, 8, 12 or 16 are invisible to
-- turtle.craft, and anything else left in the grid is part of the recipe
-- whether you meant it or not.
--
--     1  2  3 | 4
--     5  6  7 | 8      <- grid          spare ->
--     9 10 11 | 12
--    13 14 15 | 16
--
-- Recipes are positional. Three wheat stacked in one slot is not bread;
-- three wheat in three adjacent grid slots is. Nothing in a generated
-- script can be expected to know that, so it lives here.
inv.GRID  = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
inv.SPARE = { 4, 8, 12, 16 }

local function gridSlot(row, col) return inv.GRID[(row - 1) * 3 + col] end

local function isGridSlot(n)
  for _, s in ipairs(inv.GRID) do if s == n then return true end end
  return false
end

--- Move everything out of the crafting grid into the spare column.
--- Returns true, or false plus what would not fit.
function inv.clearGrid()
  if not _G.turtle then return false, "not a turtle" end
  for _, slot in ipairs(inv.GRID) do
    if inv.slot(slot) then
      local moved = false
      for _, spare in ipairs(inv.SPARE) do
        local there = inv.slot(spare)
        if not there or (there.name == inv.slot(slot).name) then
          turtle.select(slot)
          if turtle.transferTo(spare) and not inv.slot(slot) then
            moved = true
            break
          end
        end
      end
      if not moved then
        return false, ("slot %d is in the crafting grid and the spare " ..
                       "column is full"):format(slot)
      end
    end
  end
  return true
end

--- Lay a recipe out in the crafting grid and craft it.
---
---   inv.craft({ { "*wheat", "*wheat", "*wheat" } })          -- bread
---   inv.craft({ { "*_planks", "*_planks" },
---               { "*_planks", "*_planks" } })                -- crafting table
---
--- `pattern` is up to three rows of up to three cells. A cell is an item
--- spec (globs allowed) or nil for "leave empty". Cells are placed in the
--- grid exactly as written, because recipes are shaped: three wheat in one
--- slot is not bread, three wheat across three cells is.
---
--- opts.limit  craft at most this many times (default: as many as fit)
---
--- Returns true, or false plus a reason. Needs a crafting table equipped.
function inv.craft(pattern, opts)
  opts = opts or {}
  if not _G.turtle then return false, "not a turtle" end
  if not turtle.craft then
    return false, "no crafting upgrade -- equip a crafting table first"
  end
  if type(pattern) ~= "table" or #pattern == 0 then
    return false, "craft needs a pattern: rows of item specs"
  end
  if #pattern > 3 then return false, "a recipe is at most 3 rows" end

  local target, order = {}, {}
  for row = 1, #pattern do
    local cells = pattern[row]
    if type(cells) ~= "table" then return false, "each row must be a table" end
    if #cells > 3 then return false, "a recipe row is at most 3 cells" end
    for col = 1, #cells do
      if cells[col] then
        local slot = gridSlot(row, col)
        target[slot] = cells[col]
        order[#order + 1] = slot
      end
    end
  end
  if #order == 0 then return false, "the pattern asks for nothing" end

  local function describe(spec)
    return type(spec) == "string" and spec or "that item"
  end

  --- Move `count` items out of `slot` into the spare column. Only the
  --- spare column will do: anything parked in the grid joins the recipe.
  local function stash(slot, count)
    local moved = 0
    for _, spare in ipairs(inv.SPARE) do
      if moved >= count then break end
      local here = inv.slot(slot)
      if not here then break end
      local there = inv.slot(spare)
      if spare ~= slot and (not there or there.name == here.name) then
        turtle.select(slot)
        if turtle.transferTo(spare, count - moved) then
          inv.invalidate()
          local after = inv.slot(slot)
          moved = moved + (here.count - (after and after.count or 0))
        end
      end
    end
    if moved >= count then return true end
    return false, ("slot %d must be emptied and the spare column " ..
                   "(4, 8, 12, 16) is full"):format(slot)
  end

  -- Clear the grid of everything the recipe did not ask for, including
  -- surplus in cells it did: a cell holds exactly one item.
  for _, slot in ipairs(inv.GRID) do
    local here = inv.slot(slot)
    if here then
      local spec = target[slot]
      if spec and inv.matches(here, spec) then
        if here.count > 1 then
          local ok, err = stash(slot, here.count - 1)
          if not ok then return false, err end
        end
      else
        local ok, err = stash(slot, here.count)
        if not ok then return false, err end
        if inv.slot(slot) then
          return false, ("could not clear slot %d"):format(slot)
        end
      end
    end
  end

  -- Fill each cell from somewhere that is not itself a cell, so a source
  -- is never a place we have already put an item.
  for _, slot in ipairs(order) do
    if not inv.slot(slot) then
      local spec, from = target[slot], nil
      for i = 1, inv.SLOTS do
        if not target[i] then
          local d = inv.slot(i, needsDetail(spec))
          if d and inv.matches(d, spec) then from = i; break end
        end
      end
      if not from then
        return false, ("no %s left to put in slot %d -- the recipe needs " ..
                       "one per cell"):format(describe(spec), slot)
      end
      turtle.select(from)
      local moved = turtle.transferTo(slot, 1)
      inv.invalidate()
      if not moved then
        return false, ("could not move %s into slot %d")
          :format(describe(spec), slot)
      end
    end
  end

  local ok, err = turtle.craft(opts.limit)
  inv.invalidate()
  if not ok then
    return false, (err or "no matching recipe") ..
      " -- check the shape, one item per cell"
  end
  return true
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
