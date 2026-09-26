--[[ agent/caps.lua ------------------------------------------------------
  Runtime capability detection.

  Nothing in this library assumes a particular turtle. At boot we probe what
  this machine actually is and expose the answers as a flat table of flags.
  Generated scripts branch on these instead of guessing, and the manifest
  handed to Claude is filtered by them -- so the model is never shown, and
  never wastes tokens on, an ability this turtle does not have.

  Probes are non-destructive. Anything that could only be learned by
  breaking a block is left `nil` (unknown) and filled in lazily the first
  time a real operation succeeds or fails.

  Extending: caps.register("geoScanner", function() ... end) adds a flag.
--------------------------------------------------------------------------]]

local util = require("agent.util")

local caps = {}

local probes = {}   -- name -> function() -> value
local order  = {}
local costly = {}   -- probes too slow to re-run at every boundary
local flags  = nil

--- opts.expensive marks a probe that must not be re-run casually (the GPS
--- fix blocks for two seconds). Everything else is re-probed whenever the
--- world may have changed under us, because the operator is not a caller:
--- they can equip a pickaxe through the turtle's GUI and nothing here
--- would hear about it.
function caps.register(name, probe, opts)
  if not probes[name] then order[#order + 1] = name end
  probes[name] = probe
  costly[name] = (opts and opts.expensive) or nil
end

--------------------------------------------------------------- built-ins --

--- What is on a turtle's side, when the build can say. Returns the item
--- detail, false for "nothing", or nil for "this build has no such call".
function caps.equipped(side)
  if not _G.turtle then return false end
  local get = turtle[side == "left" and "getEquippedLeft" or "getEquippedRight"]
  if not get then return nil end
  local ok, item = pcall(get)
  if not ok then return nil end
  return type(item) == "table" and item or false
end

caps.register("turtle", function() return _G.turtle ~= nil end)

caps.register("http", function() return _G.http ~= nil end)

caps.register("unlimitedFuel", function()
  if not _G.turtle then return false end
  return turtle.getFuelLevel() == "unlimited"
end)

-- turtle.craft existing is weaker evidence than it looks: on at least
-- some builds the method outlives the upgrade that added it, so a turtle
-- with nothing on its sides still has a callable turtle.craft that
-- returns a bare false. Ask what is attached where the build can say,
-- and fall back to the method only when it cannot.
caps.register("crafting", function()
  if not _G.turtle then return false end
  for _, side in ipairs({ "left", "right" }) do
    local item = caps.equipped(side)
    if item == nil then return turtle.craft ~= nil end      -- cannot tell
    if item and tostring(item.name or ""):find("crafting_table", 1, true) then
      return true
    end
  end
  return false
end)

caps.register("equip", function()
  return _G.turtle ~= nil and turtle.equipLeft ~= nil
end)

--- Peripheral upgrades bolted to the turtle's sides (modem, etc).
--- Tool upgrades (pickaxe, sword, hoe) are NOT peripherals and do not
--- show up here -- see `digging` below.
caps.register("upgrades", function()
  if not _G.peripheral then return {} end
  local out = {}
  for _, side in ipairs({ "left", "right" }) do
    local ok, t = pcall(peripheral.getType, side)
    if ok and t then out[side] = t end
  end
  return out
end)

caps.register("modem", function()
  if not _G.peripheral then return false end
  local m = peripheral.find("modem")
  return m ~= nil
end)

caps.register("wirelessModem", function()
  if not _G.peripheral then return false end
  local m = peripheral.find("modem", function(_, o)
    return o.isWireless and o.isWireless()
  end)
  return m ~= nil
end)

local DIG_TOOLS = { "pickaxe", "axe", "shovel", "spade", "sword", "hoe" }

--- Can this turtle break blocks?
---
--- Ask what is on its sides first: a tool there is the answer, and it
--- stays the answer when the turtle is facing a wall. Only fall back to
--- the old probe -- dig the air in front and see whether it complains
--- about having no tool -- on builds that cannot report their upgrades.
--- That probe cannot answer at all with a block in front, since finding
--- out would mean destroying it, and returning nil there is honest:
--- "unknown" is a different answer from "no".
caps.register("digging", function()
  if not _G.turtle then return false end

  local left, right = caps.equipped("left"), caps.equipped("right")
  if left ~= nil and right ~= nil then
    for _, item in ipairs({ left or {}, right or {} }) do
      local name = tostring(item.name or ""):lower()
      for _, tool in ipairs(DIG_TOOLS) do
        if name:find(tool, 1, true) then return true end
      end
    end
    return false
  end

  if turtle.detect() then return nil end          -- unknown; learn lazily
  local _, err = turtle.dig()
  if err and err:lower():find("no tool") then return false end
  return true
end)

caps.register("gps", function()
  if not _G.gps then return false end
  local x = gps.locate(2)
  return x ~= nil
end, { expensive = true })            -- two seconds; not for every request

--- Anything else attached to the network / world, by peripheral type.
--- Modules and user extensions can look here rather than adding a probe.
caps.register("peripherals", function()
  if not _G.peripheral then return {} end
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    local ok, t = pcall(peripheral.getType, name)
    if ok and t then out[t] = name end
  end
  return out
end)

--------------------------------------------------------------------------

--- Run every probe. Cached; pass true to force a re-probe (e.g. after the
--- turtle equips a different tool or is placed next to a modem).
--- Run one probe into the flags table, keeping the difference between
--- "no" and "cannot tell". `nil` means unknown, and collapsing it to
--- false is how a turtle that booted facing a block -- so the digging
--- probe declined to destroy it to find out -- got recorded as unable to
--- dig for the rest of the session.
local function probe(name)
  local ok, val = pcall(probes[name])
  if ok then flags[name] = val else flags[name] = false end
end

function caps.detect(force)
  if flags and not force then return flags end
  flags = {}
  for _, name in ipairs(order) do probe(name) end
  return flags
end

--- Re-probe everything cheap. Called wherever the world is trusted again
--- after an arbitrary gap.
function caps.refreshCheap()
  if not flags then return caps.detect() end
  for _, name in ipairs(order) do
    if not costly[name] then probe(name) end
  end
  return flags
end

function caps.get(name)
  return caps.detect()[name]
end

--- Overwrite a flag once the world teaches us something a probe could not.
function caps.set(name, value)
  caps.detect()[name] = value
  return value
end

function caps.has(name)
  local v = caps.get(name)
  return v ~= nil and v ~= false and v ~= 0
end

--- Re-probe. The machine is not static: equipping a crafting table adds
--- turtle.craft, equipping a modem adds a peripheral, and a boot-time
--- answer outlives none of that. Cheap -- every probe is a nil check or a
--- pcall -- so call it whenever the turtle's hardware may have changed.
function caps.refresh()
  return caps.detect(true)
end

--- Guard for scripts: `caps.require("digging")` errors with a clear message
--- instead of letting the job fail halfway through in a confusing way.
-- What is worth suggesting when a capability is missing: the operator
-- loading a tool into the inventory is not the same as equipping it, and
-- "this turtle cannot dig" while a pickaxe sits in slot 3 is a true
-- statement that helps nobody.
local CARRIED_FIX = {
  digging  = { spec = "*pickaxe",       hint = "inv.equip(\"*pickaxe\")" },
  crafting = { spec = "crafting_table", hint = "inv.equip(\"crafting_table\")" },
}

--- If the missing capability is one an item in the inventory would
--- supply, say which slot and what to call. Returns nil when there is
--- nothing useful to add.
function caps.carriedFix(name)
  local fix = CARRIED_FIX[name]
  if not fix or not _G.turtle then return nil end
  local ok, inv = pcall(require, "agent.inv")
  if not ok then return nil end
  local slot = inv.find(fix.spec)
  if not slot then return nil end
  local d = inv.slot(slot)
  return ("%s is in slot %d but not equipped -- %s")
    :format(d and (d.name:gsub("^.*:", "")) or fix.spec, slot, fix.hint)
end

function caps.require(name, why)
  if caps.has(name) then return true end
  -- Before refusing, check we are not holding a stale answer: a script
  -- that just equipped the tool it needs is right and we are wrong.
  caps.refresh()
  if caps.has(name) then return true end
  local carried = caps.carriedFix(name)
  error(("this turtle lacks '%s'%s%s"):format(
          name,
          why and (" -- " .. why) or "",
          carried and (" (" .. carried .. ")") or ""), 2)
end

--- One-line summary for the prompt header. Deliberately terse: this text
--- is sent on every request, so it is the most token-sensitive string in
--- the whole system.
function caps.summary()
  local f = caps.detect()
  local bits = {}
  local function add(cond, text) if cond then bits[#bits + 1] = text end end
  add(f.turtle, "turtle")
  add(not f.turtle, "computer (no turtle API)")
  -- "NO-dig" states the present, and reads as a verdict. When the thing
  -- that would supply the capability is sitting in the inventory, say so
  -- here rather than only in caps.require's error -- by the time that
  -- fires, a program has already been written around the turtle being
  -- incapable. Two words, and only when there is something to say.
  local function lacking(name, label)
    if caps.carriedFix(name) then return label .. "(aboard)" end
    return "NO-" .. label
  end
  add(f.digging == true, "dig")
  add(f.digging == nil, "dig?")
  add(f.digging == false, lacking("digging", "dig"))
  add(f.crafting, "craft")
  add(f.crafting == false and caps.carriedFix("crafting") ~= nil,
      "craft(aboard)")
  add(f.equip, "equip")
  add(f.gps, "gps")
  add(f.wirelessModem, "wireless")
  add(f.modem and not f.wirelessModem, "wired-modem")
  add(f.unlimitedFuel, "unlimited-fuel")
  local up = {}
  for side, t in pairs(f.upgrades or {}) do up[#up + 1] = side .. ":" .. t end
  table.sort(up)
  if #up > 0 then bits[#bits + 1] = table.concat(up, ",") end
  local per = {}
  for t in pairs(f.peripherals or {}) do
    if t ~= "modem" then per[#per + 1] = t end
  end
  table.sort(per)
  if #per > 0 then bits[#bits + 1] = "near:" .. table.concat(per, ",") end
  return table.concat(bits, " ")
end

return caps
