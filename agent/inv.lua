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

-------------------------------------------------------------- equipping ---

--- Put an item from the inventory onto a side. Equipping swaps: whatever
--- was on that side lands in the slot the item came from, so the returned
--- slot is how you put things back -- select it and equip the same side
--- again. An empty selected slot unequips, which is how the item comes
--- home.
---
--- Changes what the machine can do, so capabilities are re-probed here.
function inv.equip(spec, side)
  if not _G.turtle then return false, "not a turtle" end
  side = (side == "left") and "left" or "right"
  local fn = (side == "left") and turtle.equipLeft or turtle.equipRight
  if not fn then return false, "this turtle cannot equip" end

  local slot = inv.find(spec)
  if not slot then
    return false, ("nothing matching %s to equip")
      :format(type(spec) == "string" and spec or "that")
  end
  turtle.select(slot)
  local ok, err = fn()
  inv.invalidate()
  caps.refresh()
  if not ok then return false, err or "the turtle refused to equip it" end
  return true, slot
end

--- Take whatever is on a side off, into the first free slot.
function inv.unequip(side)
  if not _G.turtle then return false, "not a turtle" end
  side = (side == "left") and "left" or "right"
  local fn = (side == "left") and turtle.equipLeft or turtle.equipRight
  if not fn then return false, "this turtle cannot equip" end
  local free = inv.firstFreeSlot()
  if not free then return false, "no free slot to unequip into" end
  turtle.select(free)
  local ok, err = fn()
  inv.invalidate()
  caps.refresh()
  if not ok then return false, err or "nothing to unequip" end
  return true, free
end

------------------------------------------------------------- crafting ----

-- A turtle crafts from the left 3x3 of its 4x4 inventory. The fourth
-- column is not part of the grid, which is what makes crafting fiddly:
-- ingredients sitting in slots 4, 8, 12 or 16 are invisible to
-- turtle.craft, and anything else left in the grid is part of the recipe
-- whether you meant it or not.
--
--     1  2  3 | 4
--     5  6  7 | 8      <- the 3x3 a recipe is read from
--     9 10 11 | 12
--    13 14 15 | 16
--
-- The 3x3 is where the recipe goes, but the *whole* inventory is the
-- crafting area: an item in any other slot makes the arrangement
-- unmatchable, however right the cells are. Confirmed in game -- three
-- wheat in 1,2,3 with the surplus in slot 4 gives "No matching recipes",
-- and the same layout crafts the moment slot 4 is emptied. So there is
-- no spare column and nowhere to park anything; column 4 is scratch
-- space during setup and must be clear before crafting.
--
-- Recipes are positional and take stacks: three wheat in one slot is not
-- bread, three cells of five wheat is five loaves.
inv.GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

local function gridSlot(row, col) return inv.GRID[(row - 1) * 3 + col] end

--- Is a crafting table actually on a side?
---
--- `turtle.craft` existing is not the same question. On at least some
--- builds the method outlives the upgrade that added it: unequip the
--- table and turtle.craft is still there, still callable, and returns
--- false with no message -- which reads as "your recipe is wrong" when
--- the truth is "there is no crafting table attached".
---
--- Returns true, false, or nil when this build cannot say (older CC has
--- no getEquipped*). Callers must treat nil as "find out by trying".
function inv.craftingTableEquipped()
  if not _G.turtle then return false end
  for _, side in ipairs({ "left", "right" }) do
    local item = caps.equipped(side)
    if item == nil then return nil end
    if item and tostring(item.name or ""):find("crafting_table", 1, true) then
      return true
    end
  end
  return false
end

--- What the crafting grid holds right now, for error messages: a craft
--- that failed is only debuggable if you can see the layout it refused.
function inv.gridSummary()
  local bits = {}
  for _, slot in ipairs(inv.GRID) do
    local d = inv.slot(slot)
    if d then
      bits[#bits + 1] = ("%d=%s%s"):format(slot, (d.name:gsub("^.*:", "")),
                                           d.count > 1 and ("x" .. d.count) or "")
    end
  end
  if #bits == 0 then return "an empty grid" end
  return table.concat(bits, " ")
end

--- Lay a recipe out in the crafting grid and craft it.
---
---   inv.craft({ { "wheat", "wheat", "wheat" } })             -- bread
---   inv.craft({ { "*_planks", "*_planks" },
---               { "*_planks", "*_planks" } })                -- crafting table
---
--- `pattern` is up to three rows of up to three cells. A cell is an item
--- spec (globs allowed) or nil for "leave empty". Recipes are shaped, so
--- cells are placed exactly as written.
---
--- The whole inventory is the crafting area, not just the 3x3. Anything
--- in any other slot -- column 4, the bottom row, a tool displaced by
--- equipping -- makes the arrangement unmatchable however right the cells
--- are. So every ingredient is spread across the cells that want it
--- rather than parked, and anything that is not an ingredient is a
--- refusal with its name in it, not a silent failure later.
---
--- Surplus goes into the cells too and crafts repeatedly: sixteen wheat
--- over three cells is 6/5/5, which is five loaves.
---
--- opts.limit  craft at most this many times
--- opts.side   which side to put the crafting table on
--- opts.restore = false  leave the table equipped
---
--- Returns true, or false plus a reason.
function inv.craft(pattern, opts)
  opts = opts or {}
  if not _G.turtle then return false, "not a turtle" end
  if type(pattern) ~= "table" or #pattern == 0 then
    return false, "craft needs a pattern: rows of item specs"
  end
  if #pattern > 3 then return false, "a recipe is at most 3 rows" end

  local function describe(spec)
    return type(spec) == "string" and spec or "that item"
  end

  ---------------------------------------------------------------- cells --
  local target, order = {}, {}
  local groups, groupOf = {}, {}
  for row = 1, #pattern do
    local cells = pattern[row]
    if type(cells) ~= "table" then return false, "each row must be a table" end
    if #cells > 3 then return false, "a recipe row is at most 3 cells" end
    for col = 1, #cells do
      local spec = cells[col]
      if spec then
        local slot = gridSlot(row, col)
        target[slot], order[#order + 1] = spec, slot
        local gi
        for i, g in ipairs(groups) do if g.spec == spec then gi = i end end
        if not gi then
          groups[#groups + 1] = { spec = spec, cells = {} }
          gi = #groups
        end
        local cellsOfGroup = groups[gi].cells
        cellsOfGroup[#cellsOfGroup + 1] = slot
        groupOf[slot] = gi
      end
    end
  end
  if #order == 0 then return false, "the pattern asks for nothing" end

  --- Which group, if any, an item belongs to.
  local function groupFor(detail)
    for i, g in ipairs(groups) do
      if inv.matches(detail, g.spec) then return i end
    end
    return nil
  end

  -- Refuse before touching anything if the turtle is carrying something
  -- the recipe does not use: it cannot be parked, and dropping the
  -- operator's belongings to make room is not ours to decide.
  local strays = {}
  for slot = 1, inv.SLOTS do
    local d = inv.slot(slot)
    if d and not groupFor(d) and not util.glob(d.name, "*crafting_table") then
      strays[#strays + 1] = (d.name:gsub("^.*:", ""))
      if #strays >= 3 then break end
    end
  end
  if #strays > 0 then
    return false, ("the whole inventory is the crafting area, so it must " ..
                   "hold only the ingredients -- drop or deposit %s first")
      :format(table.concat(strays, ", "))
  end

  --------------------------------------------------------------- equip ---
  local equippedHere, displaced, side = false, nil, opts.side

  if not side then          -- prefer a side that is not already carrying one
    for _, try in ipairs({ "right", "left" }) do
      if caps.equipped(try) == false then side = try; break end
    end
  end
  side = (side == "left") and "left" or "right"

  local function equipTable()
    local ok, slotOrErr = inv.equip("crafting_table", side)
    if not ok then return false, tostring(slotOrErr) end
    equippedHere = true
    local was = inv.slot(slotOrErr)
    displaced = was and was.name or nil
    return true
  end

  local attached = inv.craftingTableEquipped()
  if attached == false or (attached == nil and not turtle.craft) then
    if not inv.find("crafting_table") then
      return false, "no crafting table attached, and none carried"
    end
    local ok, err = equipTable()
    if not ok then return false, "could not equip the crafting table: " .. err end
    if not turtle.craft then
      return false, "equipped the crafting table but crafting is still unavailable"
    end
  end

  local function finish(ok, err)
    if equippedHere and opts.restore ~= false then
      if displaced then inv.equip(displaced, side) else inv.unequip(side) end
    end
    return ok, err
  end

  ------------------------------------------------------------- arrange ---
  -- Share every ingredient out across the cells that want it. The
  -- remainder goes to the earliest cells rather than anywhere outside,
  -- which would break the recipe; an uneven cell just crafts fewer times.
  local want = {}
  for _, g in ipairs(groups) do
    local total = 0
    for slot = 1, inv.SLOTS do
      local d = inv.slot(slot, needsDetail(g.spec))
      if d and inv.matches(d, g.spec) then total = total + d.count end
    end
    local n = #g.cells
    local per = math.floor(total / n)
    if per < 1 then
      return finish(false, ("only %d %s for %d cells -- the recipe needs " ..
                            "one per cell"):format(total, describe(g.spec), n))
    end
    local extra = total - per * n
    for i, slot in ipairs(g.cells) do
      want[slot] = per + ((i <= extra) and 1 or 0)
    end
  end

  --- Move `n` items matching `spec` into `dest` from anywhere else,
  --- taking first from slots that are not cells.
  local function fill(dest, spec, n)
    local function take(from)
      if n <= 0 or from == dest then return end
      local d = inv.slot(from, needsDetail(spec))
      if not d or not inv.matches(d, spec) then return end
      local spare = target[from] and (d.count - (want[from] or 0)) or d.count
      if spare <= 0 then return end
      turtle.select(from)
      turtle.transferTo(dest, math.min(n, spare))
      inv.invalidate()
      local now = inv.slot(dest)
      n = want[dest] - ((now and now.count) or 0)
    end
    for slot = 1, inv.SLOTS do if not target[slot] then take(slot) end end
    for slot = 1, inv.SLOTS do if target[slot] then take(slot) end end
    return n <= 0
  end

  -- Empty any cell holding the wrong ingredient first; a slot outside the
  -- grid is fine as scratch, it only has to be clear before we craft.
  for _, slot in ipairs(order) do
    local d = inv.slot(slot)
    if d and not inv.matches(d, target[slot]) then
      for scratch = 1, inv.SLOTS do
        if not target[scratch] and not inv.slot(scratch) then
          turtle.select(slot)
          turtle.transferTo(scratch)
          inv.invalidate()
          break
        end
      end
      if inv.slot(slot) then
        return finish(false, ("slot %d holds the wrong ingredient and there " ..
                              "is nowhere to put it"):format(slot))
      end
    end
  end

  for _, slot in ipairs(order) do
    local d = inv.slot(slot)
    local have = (d and inv.matches(d, target[slot])) and d.count or 0
    if have < want[slot] then
      fill(slot, target[slot], want[slot] - have)
    end
  end

  -- A crafting table still in the inventory is itself outside the recipe,
  -- so it has to go somewhere, and the side is where it belongs. This is
  -- also the retry for builds that cannot say what is attached: if we
  -- were wrong about having one on, equipping now fixes both problems.
  if not equippedHere then
    local carried = inv.find("crafting_table")
    if carried and not target[carried] then equipTable() end
  end

  -- Nothing may remain outside the recipe, including a tool the equip
  -- displaced. This is the check that the game itself applies.
  for slot = 1, inv.SLOTS do
    if not target[slot] and inv.slot(slot) then
      local d = inv.slot(slot)
      return finish(false, ("%s in slot %d is outside the recipe, and the " ..
                            "whole inventory is the crafting area")
        :format((d.name:gsub("^.*:", "")), slot))
    end
  end

  --------------------------------------------------------------- craft ---
  local ok, err = turtle.craft(opts.limit)
  inv.invalidate()

  if not ok and not equippedHere and inv.craftingTableEquipped() == nil
     and inv.find("crafting_table") then
    if equipTable() then
      ok, err = turtle.craft(opts.limit)
      inv.invalidate()
    end
  end

  if not ok then
    return finish(false, (err or "no matching recipe") ..
      " -- laid out " .. inv.gridSummary())
  end
  return finish(true)
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
