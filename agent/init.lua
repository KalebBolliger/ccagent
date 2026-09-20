--[[ agent/init.lua ------------------------------------------------------
  Assembles the agent API and declares it to the registry.

      local agent = require("agent.init")
      agent.boot()          -- probe capabilities, restore pose, set hooks
      agent.env()           -- the table generated scripts run against

  Everything a generated script can touch is here. If you add a module,
  register it at the bottom of this file (or from your own file, after
  requiring this one) and it appears in the manifest automatically.
--------------------------------------------------------------------------]]

local util     = require("agent.util")
local geom     = require("agent.geom")
local state    = require("agent.state")
local caps     = require("agent.caps")
local world    = require("agent.world")
local nav      = require("agent.nav")
local inv      = require("agent.inv")
local block    = require("agent.block")
local job      = require("agent.job")
local registry = require("agent.registry")
local contract = require("agent.contract")
local lint     = require("agent.lint")
local lib      = require("agent.lib")

local agent = {}

agent.util, agent.geom, agent.state    = util, geom, state
agent.caps, agent.world, agent.nav     = caps, world, nav
agent.inv,  agent.block, agent.job     = inv, block, job
agent.registry, agent.lib              = registry, lib
agent.contract, agent.lint             = contract, lint

agent.VERSION = "1.1.1"

--------------------------------------------------------------- helpers ----
-- Small cross-cutting utilities that do not belong to one module but are
-- asked for constantly. Cheap to provide, expensive to re-derive per script.

local helper = {}

--- Wait until a predicate is true, or give up. Avoids the busy-loop bug.
function helper.waitFor(pred, timeout, interval)
  local deadline = util.now() + (timeout or 30) * 1000
  while util.now() < deadline do
    job.checkAbort()
    local ok, v = pcall(pred)
    if ok and v then return true, v end
    util.sleep(interval or 0.5)
  end
  return false, "timed out"
end

--- Retry a flaky operation with a short backoff.
function helper.retry(fn, times, delay)
  local lastErr
  for i = 1, (times or 3) do
    local ok, res, err = pcall(fn)
    if ok and res then return res end
    lastErr = (not ok and res) or err or "failed"
    util.sleep((delay or 0.4) * i)
  end
  return nil, lastErr
end

--- Run fn, and no matter how it ends, come back to where we started.
function helper.roundTrip(fn, opts)
  local origin, facing = nav.pos(), nav.facing()
  local ok, res = pcall(fn)
  if origin then
    nav.moveTo(origin, opts or { dig = true })
    if facing then nav.face(facing) end
  end
  if not ok then error(res, 0) end
  return res
end

helper.glob = util.glob

--- Redstone in any direction word, without the side-name bookkeeping.
function helper.redstone(side, value)
  if not _G.redstone then return nil, "no redstone API" end
  side = tostring(side):lower()
  if value == nil then return redstone.getInput(side) end
  redstone.setOutput(side, value and true or false)
  return true
end

--------------------------------------------------------------- booting ----

function agent.boot(opts)
  opts = opts or {}
  caps.detect(true)
  state.load()

  -- nav cannot depend on inv (inv would then depend on nav), so wire the
  -- refuel behaviour in from here.
  nav.refuelHook = function(target) inv.refuel(target) end

  if caps.has("turtle") and opts.calibrate ~= false then
    local ok, err = nav.calibrate({ timeout = opts.gpsTimeout or 2 })
    if not ok then util.log.warn("calibration: %s", tostring(err)) end
    if not nav.home() then nav.setHome() end
  end
  state.flush()
  return agent
end

--- Everything a generated script sees. Built fresh so capability stubs
--- reflect the latest probe.
function agent.env()
  return registry.environment()
end

--- One compact line describing the machine right now. Goes at the top of
--- every request, and is the only per-request world state Claude needs in
--- the common case.
function agent.situation()
  -- This is the one per-request description of the world Claude gets, so
  -- it has to be read fresh: the operator may have loaded or emptied the
  -- turtle by hand since the last one.
  inv.invalidate()
  caps.refreshCheap()
  local bits = {
    "caps: " .. caps.summary(),
  }
  if caps.has("turtle") then
    bits[#bits + 1] = "at: " .. nav.status()
    local h = nav.home()
    if h then bits[#bits + 1] = "home: " .. geom.tostring(h) end
    bits[#bits + 1] = "inv: " .. inv.summary(6)
    bits[#bits + 1] = "seen: " .. world.summary(nav.pos(), 6)
  end
  return table.concat(bits, "\n")
end

------------------------------------------------------------ declarations --

registry.add("nav", nav, "position, movement, pathfinding", {
  { fn = "pos",        sig = "() -> {x,y,z}|nil",            doc = "current position" },
  { fn = "facing",     sig = "() -> 0..3",                   doc = "0=north 1=east 2=south 3=west" },
  { fn = "facingName", sig = "() -> 'north'|...",            doc = "heading as a word" },
  { fn = "moveTo",     sig = "(pos, opts?) -> ok, err",      doc = "pathfind there; opts: dig, box, adjacent, blocked, onStep" },
  { fn = "moveBy",     sig = "(dx, dy, dz, opts?) -> ok, err", doc = "pathfind to a relative offset" },
  { fn = "step",       sig = "(dir, opts?) -> ok, err",      doc = "one block; dir is forward/back/left/right/up/down/north/east/south/west" },
  { fn = "face",       sig = "(dir) -> ok",                  doc = "turn to a heading or direction word" },
  { fn = "faceToward", sig = "(pos) -> ok",                  doc = "turn to look at a position" },
  { fn = "turnLeft",   sig = "() -> ok" },
  { fn = "turnRight",  sig = "() -> ok" },
  { fn = "turnAround", sig = "() -> ok" },
  { fn = "findPath",   sig = "(from, to, opts?) -> path|nil, err", doc = "plan without walking" },
  { fn = "follow",     sig = "(path, opts?) -> ok, err, i",  doc = "walk a planned path" },
  { fn = "distanceTo", sig = "(pos) -> n",                   doc = "manhattan distance" },
  { fn = "setHome",    sig = "(pos?) -> ok",                 doc = "remember a return point" },
  { fn = "home",       sig = "() -> pos|nil" },
  { fn = "goHome",     sig = "(opts?) -> ok, err" },
  { fn = "fuel",       sig = "() -> n",                      doc = "math.huge if unlimited" },
  { fn = "ensureFuel", sig = "(n) -> ok, err",               doc = "refuel from inventory if below n" },
  { fn = "calibrate",  sig = "(opts?) -> ok, err",           doc = "re-fix position/heading from GPS" },
  { fn = "status",     sig = "() -> string" },
})

registry.add("block", block, "look at, break, place and hit blocks in any direction", {
  { fn = "inspect",  sig = "(dir) -> info|nil, err",        doc = "info.name, info.state; turns as needed" },
  { fn = "detect",   sig = "(dir) -> boolean" },
  { fn = "is",       sig = "(dir, pattern) -> bool, info",  doc = "glob match, e.g. block.is('down','*_ore')" },
  { fn = "scan",     sig = "(opts?) -> {dir=name|false}",   doc = "look all six ways, fold into world memory" },
  { fn = "dig",      sig = "(dir, opts?) -> ok, err",       doc = "opts: only=pattern, repeatWhileFalling, force" },
  { fn = "digVein",  sig = "(pattern, opts?) -> n, err",    doc = "flood-fill mine a connected vein, then return" },
  { fn = "place",    sig = "(dir, spec?, opts?) -> ok, err", doc = "spec is an item spec; opts: replace, text" },
  { fn = "fill",     sig = "(a, b, spec, opts?) -> placed, skipped", doc = "fill a box with blocks" },
  { fn = "clear",    sig = "(a, b, opts?) -> dug",          doc = "excavate a box" },
  { fn = "attack",   sig = "(dir, opts?) -> hits",          doc = "opts: times, delay" },
  { fn = "drop",     sig = "(dir, spec, opts?) -> n",       doc = "drop matching items that way" },
  { fn = "suck",     sig = "(dir, count?) -> ok" },
})

registry.add("inv", inv, "inventory as a query, not sixteen slots", {
  { fn = "find",     sig = "(spec) -> slot|nil, detail",    doc = "spec: 'minecraft:coal' | '*_log' | {tag=...} | {min=n} | fn" },
  { fn = "findAll",  sig = "(spec) -> {{slot,detail},...}" },
  { fn = "count",    sig = "(spec) -> n" },
  { fn = "has",      sig = "(spec, n?) -> bool" },
  { fn = "select",   sig = "(spec) -> slot|false, err" },
  { fn = "contents", sig = "() -> {name=count}" },
  { fn = "summary",  sig = "(limit?) -> string" },
  { fn = "freeSlots",sig = "() -> n" },
  { fn = "isFull",   sig = "() -> bool" },
  { fn = "consolidate", sig = "() -> moved",                doc = "merge partial stacks" },
  { fn = "drop",     sig = "(dir, spec, opts?) -> n",       doc = "dir is forward/up/down; opts: keep=n, limit=n" },
  { fn = "suck",     sig = "(dir, count?, opts?) -> gained" },
  { fn = "deposit",  sig = "(dir, opts?) -> n",             doc = "unload everything; opts.keep = spec to retain" },
  { fn = "refuel",   sig = "(target?, opts?) -> level",     doc = "burn carried fuel up to target; any fuel the game accepts, mods included; opts.keep protects items" },
  { fn = "fuelSlots", sig = "(opts?) -> {slot,...}",        doc = "slots the game itself will burn; asks, so it works for modded fuel" },
  { fn = "craft",    sig = "(pattern, opts?) -> ok, err, info",
    doc = "rows of item specs; turtle must carry ONLY the ingredients; info.reason='inventory' + info.blocking when it does not" },
  { fn = "equip",    sig = "(spec, side?) -> ok, slot", doc = "side is left|right (default right); swaps, so slot holds what came off" },
  { fn = "unequip",  sig = "(side?) -> ok, slot" },
  { fn = "listExternal", sig = "(nameOrType?) -> {name=count}, err",
    doc = "read an adjacent/networked chest without moving items", requires = "modem" },
})

registry.add("world", world, "persistent memory of blocks already seen", {
  { fn = "get",      sig = "(pos) -> {n,t}|nil",            doc = "n=false means known air" },
  { fn = "isSolid",  sig = "(pos) -> true|false|nil",       doc = "nil = never observed" },
  { fn = "find",     sig = "(pattern, opts?) -> {{pos,name,age},...}", doc = "opts: near=pos, limit, box" },
  { fn = "count",    sig = "(pattern?) -> n" },
  { fn = "set",      sig = "(pos, name|false)",             doc = "record an observation by hand" },
  { fn = "summary",  sig = "(near?, limit?) -> string" },
  { fn = "save",     sig = "() -> ok" },
})

registry.add("geom", geom, "coordinate helpers (pure math, no server calls)", {
  { fn = "v",         sig = "(x,y,z) -> pos" },
  { fn = "add",       sig = "(a,b) -> pos" },
  { fn = "sub",       sig = "(a,b) -> pos" },
  { fn = "eq",        sig = "(a,b) -> bool" },
  { fn = "manhattan", sig = "(a,b) -> n" },
  { fn = "ahead",     sig = "(pos, facing, n?) -> pos" },
  { fn = "iterBox",   sig = "(a, b, opts?) -> iterator",    doc = "walk a box in turtle-friendly order" },
  { fn = "boxVolume", sig = "(a,b) -> n" },
  { fn = "inBox",     sig = "(p,a,b) -> bool" },
  { fn = "neighbours",sig = "(pos) -> {pos x6}" },
})

registry.add("job", job, "talk to the operator; survive reboots", {
  { fn = "say",        sig = "(fmt, ...)",                  doc = "narrate progress; use instead of print" },
  { fn = "warn",       sig = "(fmt, ...)" },
  { fn = "progress",   sig = "(done, total, label?)" },
  { fn = "report",     sig = "(value)",                     doc = "hand a final structured result back" },
  { fn = "checkAbort", sig = "()",                          doc = "call inside long loops so stop works" },
  { fn = "sleep",      sig = "(n)",                         doc = "abort-aware sleep" },
  { fn = "checkpoint", sig = "(key, value)",                doc = "persist across reboot" },
  { fn = "recall",     sig = "(key, default?) -> value" },
})

registry.add("lib", lib, "saved routines, callable by name", {
  { fn = "run",  sig = "(name, args?) -> result",
    doc = "call a registered routine; raises on a bad name, bad args or unmet needs" },
  { fn = "has",  sig = "(name) -> bool",       doc = "is that routine available here" },
  { fn = "list", sig = "() -> {{name,doc},...}" },
})

registry.add("caps", caps, "what this machine can actually do", {
  { fn = "has",     sig = "(name) -> bool",                 doc = "turtle, digging, crafting, equip, gps, modem, wirelessModem, unlimitedFuel" },
  { fn = "get",     sig = "(name) -> value" },
  { fn = "require", sig = "(name, why?)",                   doc = "hard guard; errors with a readable message" },
  { fn = "refresh", sig = "() -> flags",                    doc = "re-probe after equipping: equipping a crafting table adds crafting" },
  { fn = "carriedFix", sig = "(name) -> hint|nil",          doc = "'a pickaxe is in slot 3 but not equipped' when that is why a capability is missing" },
})

registry.add("helper", helper, "cross-cutting odds and ends", {
  { fn = "waitFor",   sig = "(pred, timeout?, interval?) -> ok, v" },
  { fn = "retry",     sig = "(fn, times?, delay?) -> v, err" },
  { fn = "roundTrip", sig = "(fn, opts?) -> v",             doc = "run fn and always return to the starting position" },
  { fn = "glob",      sig = "(s, pattern) -> bool" },
  { fn = "redstone",  sig = "(side, value?) -> v",          doc = "read or set a redstone side" },
})

agent.helper = helper

return agent
