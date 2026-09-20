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
local flags  = nil

function caps.register(name, probe)
  if not probes[name] then order[#order + 1] = name end
  probes[name] = probe
end

--------------------------------------------------------------- built-ins --

caps.register("turtle", function() return _G.turtle ~= nil end)

caps.register("http", function() return _G.http ~= nil end)

caps.register("unlimitedFuel", function()
  if not _G.turtle then return false end
  return turtle.getFuelLevel() == "unlimited"
end)

caps.register("crafting", function()
  return _G.turtle ~= nil and turtle.craft ~= nil
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

--- Can this turtle break blocks? Only safe to answer when there is nothing
--- in front of us -- otherwise we would be destroying it to find out.
caps.register("digging", function()
  if not _G.turtle then return false end
  if turtle.detect() then return nil end          -- unknown; learn lazily
  local _, err = turtle.dig()
  if err and err:lower():find("no tool") then return false end
  return true
end)

caps.register("gps", function()
  if not _G.gps then return false end
  local x = gps.locate(2)
  return x ~= nil
end)

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
function caps.detect(force)
  if flags and not force then return flags end
  flags = {}
  for _, name in ipairs(order) do
    local ok, val = pcall(probes[name])
    flags[name] = ok and val or false
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

--- Guard for scripts: `caps.require("digging")` errors with a clear message
--- instead of letting the job fail halfway through in a confusing way.
function caps.require(name, why)
  if caps.has(name) then return true end
  error(("this turtle lacks '%s'%s"):format(name, why and (" -- " .. why) or ""), 2)
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
  add(f.digging == true, "dig")
  add(f.digging == nil, "dig?")
  add(f.digging == false, "NO-dig")
  add(f.crafting, "craft")
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
