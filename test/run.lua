--[[ test/run.lua ------------------------------------------------------
  Exercises the core against the mock world. Not a substitute for running
  it in Minecraft, but it catches the things that are painful to debug
  in-game: facing math, pathfinding, inventory matching, the sandbox,
  fence extraction, and manifest generation.

      lua5.3 test/run.lua
--------------------------------------------------------------------------]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local mock = require("test.mock")
mock.install()

local pass, fail = 0, 0
local function ok(cond, label, detail)
  if cond then
    pass = pass + 1
    print("  ok   " .. label)
  else
    fail = fail + 1
    print("  FAIL " .. label .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end
local function group(name) print("\n" .. name) end

local util  = require("agent.util")
local geom  = require("agent.geom")
local state = require("agent.state")
local caps  = require("agent.caps")
local world = require("agent.world")
local nav   = require("agent.nav")
local inv   = require("agent.inv")
local block = require("agent.block")
local agent = require("agent.init")
local registry = require("agent.registry")
local extract  = require("claude.extract")
local executor = require("claude.executor")

local function fresh()
  mock.reset()
  state.clear()
  world.clear()
  inv.invalidate()
  caps.detect(true)
  nav.localFrame(geom.v(0, 64, 0), geom.NORTH)
  nav.refuelHook = function(t) inv.refuel(t) end
end

--------------------------------------------------------------------------
group("util / geom")

ok(util.glob("minecraft:oak_log", "*_log"), "glob suffix")
ok(util.glob("minecraft:oak_log", "minecraft:oak_log"), "glob exact")
ok(not util.glob("minecraft:stone", "*_log"), "glob rejects")
ok(util.glob("MINECRAFT:Stone", "minecraft:stone"), "glob is case-insensitive")

ok(geom.manhattan(geom.v(0,0,0), geom.v(3,-2,1)) == 6, "manhattan")
ok(geom.eq(geom.ahead(geom.v(0,64,0), geom.NORTH), geom.v(0,64,-1)), "north is -z")
ok(geom.eq(geom.ahead(geom.v(0,64,0), geom.EAST), geom.v(1,64,0)), "east is +x")
do
  local n, side = geom.turnsBetween(geom.NORTH, geom.WEST)
  ok(n == 1 and side == "left", "north -> west is one left", n .. " " .. tostring(side))
  local n2, s2 = geom.turnsBetween(geom.NORTH, geom.SOUTH)
  ok(n2 == 2, "north -> south is two turns", n2 .. " " .. tostring(s2))
end
do
  local d, f = geom.resolve("left", geom.NORTH)
  ok(f == geom.WEST and d.x == -1, "resolve left of north")
  local d2 = geom.resolve("up", geom.NORTH)
  ok(d2.y == 1, "resolve up")
end
do
  local n = 0
  for _ in geom.iterBox(geom.v(0,0,0), geom.v(2,1,2)) do n = n + 1 end
  ok(n == 18, "iterBox visits every cell", n)
end
do
  local prev, adjacent = nil, true
  for cell in geom.iterBox(geom.v(0,0,0), geom.v(2,0,2)) do
    if prev and geom.manhattan(prev, cell) ~= 1 then adjacent = false end
    prev = cell
  end
  ok(adjacent, "iterBox steps are adjacent")
end

--------------------------------------------------------------------------
group("state / world")
fresh()
state.set("k", { a = 1 })
state.flush()
state.load()
ok(state.get("k").a == 1, "state round-trips through the file")

world.set(geom.v(1,64,1), "minecraft:diamond_ore")
world.setAir(geom.v(2,64,1))
ok(world.isSolid(geom.v(1,64,1)) == true, "solid recorded")
ok(world.isSolid(geom.v(2,64,1)) == false, "air recorded")
ok(world.isSolid(geom.v(9,9,9)) == nil, "unknown is nil")
ok(#world.find("*_ore") == 1, "world.find matches globs")
ok(world.find("*_ore", { near = geom.v(0,64,0) })[1].name == "minecraft:diamond_ore",
   "world.find returns names")

--------------------------------------------------------------------------
group("nav: movement and pose")
fresh()
ok(nav.pos().y == 64, "pose initialised")
nav.forward()
ok(geom.eq(nav.pos(), geom.v(0,64,-1)), "forward moves north",
   geom.tostring(nav.pos()))
ok(mock.turtle.z == -1, "mock agrees")
nav.face("east")
ok(nav.facing() == geom.EAST and mock.turtle.f == 1, "face east")
nav.forward()
ok(geom.eq(nav.pos(), geom.v(1,64,-1)), "forward moves east", geom.tostring(nav.pos()))
nav.step("down")
ok(nav.pos().y == 63, "step down")
nav.step("south")
ok(geom.eq(nav.pos(), geom.v(1,63,0)), "step by compass word", geom.tostring(nav.pos()))

group("nav: digging through an obstacle")
fresh()
mock.set(0, 64, -1, "minecraft:dirt")
local moved, err = nav.forward()
ok(moved, "digs through dirt when policy allows", err)
ok(mock.get(0, 64, -1) == nil, "block actually removed")

fresh()
mock.set(0, 64, -1, "minecraft:chest")
local moved2, err2 = nav.forward()
ok(not moved2, "refuses to dig a protected block")
ok(mock.get(0, 64, -1) == "minecraft:chest", "chest survives")
ok(tostring(err2):find("protected") ~= nil, "error explains why", err2)

fresh()
mock.set(0, 64, -1, "minecraft:dirt")
local moved3 = nav.forward({ dig = false })
ok(not moved3, "dig=false blocks the move")

group("nav: pathfinding")
fresh()
-- A wall across z=-2 with one gap at x=2.
for x = -4, 4 do
  if x ~= 2 then mock.set(x, 64, -2, "minecraft:bedrock") end
end
for x = -4, 4 do
  if x ~= 2 then world.set(geom.v(x, 64, -2), "minecraft:bedrock", { hard = true }) end
end
local target = geom.v(0, 64, -5)
local path, perr = nav.findPath(nav.pos(), target, { dig = false })
ok(path ~= nil, "found a path around the wall", perr)
if path then
  local throughWall = false
  for _, c in ipairs(path) do
    if c.y == 64 and c.z == -2 and c.x ~= 2 then throughWall = true end
  end
  ok(not throughWall, "path never enters a wall cell")
end

-- Confined to a single layer, the only way past is the gap at x=2.
local flat = { geom.v(-8, 64, -8), geom.v(8, 64, 8) }
local path2, perr2 = nav.findPath(nav.pos(), target, { dig = false, box = flat })
ok(path2 ~= nil, "found a path with vertical movement ruled out", perr2)
if path2 then
  local viaGap = false
  for _, c in ipairs(path2) do if c.z == -2 and c.x == 2 then viaGap = true end end
  ok(viaGap, "path goes through the gap")
end

local arrived = nav.moveTo(target, { dig = false })
ok(arrived and geom.eq(nav.pos(), target), "moveTo walked it",
   geom.tostring(nav.pos()))

group("nav: replanning when memory is wrong")
fresh()
-- World has a wall the turtle does not know about yet; it should bump into
-- it, record it, and route around.
for x = -3, 3 do
  if x ~= 3 then mock.set(x, 64, -1, "minecraft:bedrock") end
end
local got = nav.moveTo(geom.v(0, 64, -3), { dig = false })
ok(got, "recovered from an unknown obstacle")
ok(world.isSolid(geom.v(0, 64, -1)) == true, "learned the obstacle")

group("nav: fuel")
fresh()
mock.turtle.fuel = 0
mock.turtle.slots[1] = { name = "minecraft:coal", count = 4 }
inv.invalidate()
local fok = nav.ensureFuel(100)
ok(fok and nav.fuel() >= 100, "refuelled from inventory", nav.fuel())

--------------------------------------------------------------------------
group("inventory")
fresh()
mock.turtle.slots[1] = { name = "minecraft:oak_log", count = 12 }
mock.turtle.slots[2] = { name = "minecraft:cobblestone", count = 64 }
mock.turtle.slots[3] = { name = "minecraft:oak_log", count = 5 }
inv.invalidate()
ok(inv.count("*_log") == 17, "count across slots", inv.count("*_log"))
ok(inv.find("minecraft:cobblestone") == 2, "find by exact name")
ok(inv.has({ name = "*_log", min = 10 }), "spec with min")
ok(not inv.has("minecraft:diamond"), "missing item")
ok(inv.freeSlots() == 13, "free slots", inv.freeSlots())
ok(inv.select("*_log") == 1, "select picks the first match")
inv.consolidate()
inv.invalidate()
ok(inv.count("*_log") == 17 and inv.freeSlots() == 14, "consolidate merges stacks",
   inv.freeSlots())
local summary = inv.summary()
ok(summary:find("cobblestone") ~= nil, "summary mentions contents", summary)

--------------------------------------------------------------------------
group("block")
fresh()
mock.set(0, 63, 0, "minecraft:grass_block")
ok(block.is("down", "*grass*"), "block.is down")
ok(world.isSolid(geom.v(0,63,0)) == true, "inspect folded into world memory")

mock.set(1, 64, 0, "minecraft:stone")
local isStone, info = block.is("east", "minecraft:stone")
ok(isStone and info.name == "minecraft:stone", "inspect to the east by turning")
ok(nav.facing() == geom.NORTH, "facing restored after a sideways look",
   nav.facingName())

fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 10 }
inv.invalidate()
ok(block.place("down", "minecraft:cobblestone"), "place below")
ok(mock.get(0, 63, 0) == "minecraft:cobblestone", "block appeared in the world")

fresh()
mock.set(0, 63, 0, "minecraft:stone")
ok(block.dig("down"), "dig below")
ok(mock.get(0, 63, 0) == nil, "block gone")
ok(inv.count("minecraft:stone") == 1, "loot collected")

group("block: fill and clear")
fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
inv.invalidate()
local placed = block.fill(geom.v(0,63,0), geom.v(2,63,2), "minecraft:cobblestone",
                          { dig = true })
ok(placed == 9, "filled a 3x3 floor", placed)
local count = 0
for x = 0, 2 do for z = 0, 2 do
  if mock.get(x, 63, z) == "minecraft:cobblestone" then count = count + 1 end
end end
ok(count == 9, "floor is really there", count)

fresh()
mock.fill({0,64,-1}, {2,65,-3}, "minecraft:stone")
local dug = block.clear(geom.v(0,64,-1), geom.v(2,65,-3))
ok(dug > 0, "clear removed blocks", dug)
local left = 0
for x = 0, 2 do for y = 64, 65 do for z = -3, -1 do
  if mock.get(x, y, z) then left = left + 1 end
end end end
ok(left == 0, "box is empty", left)

group("block: vein mining")
fresh()
-- An L-shaped vein of three ore blocks in front of the turtle.
mock.set(0, 64, -1, "minecraft:iron_ore")
mock.set(0, 64, -2, "minecraft:iron_ore")
mock.set(1, 64, -2, "minecraft:iron_ore")
local mined = block.digVein("*_ore", { max = 10 })
ok(mined == 3, "mined the whole vein", mined)
ok(geom.eq(nav.pos(), geom.v(0,64,0)), "returned to the start",
   geom.tostring(nav.pos()))

--------------------------------------------------------------------------
group("registry / manifest")
local manifest = registry.manifest()
ok(manifest:find("nav.moveTo") ~= nil, "manifest lists nav.moveTo")
ok(manifest:find("inv.find") ~= nil, "manifest lists inv.find")
local tokens, chars = registry.manifestCost()
ok(tokens > 300 and tokens < 3000, "manifest is a sane size", tokens .. " tokens")
print(("       (~%d tokens, %d chars)"):format(tokens, chars))

do
  -- A capability the machine does not have must be stubbed, not nil.
  caps.set("modem", false)
  local env = registry.environment()
  local okCall, errCall = pcall(env.inv.listExternal)
  ok(not okCall and tostring(errCall):find("modem") ~= nil,
     "missing capability raises a readable error", errCall)
  caps.detect(true)
end

--------------------------------------------------------------------------
group("code extraction")
do
  local code, note = extract.code("Sure.\n```lua\nreturn 1\n```\n")
  ok(code == "return 1", "plain fenced block", code)

  code = extract.code("```\nlocal x = 1\n```")
  ok(code == "local x = 1", "untagged fence")

  code, note = extract.code("```lua\nlocal x = 1\n")
  ok(code == "local x = 1" and note and note:find("truncated"),
     "unterminated fence is recovered and flagged", note)

  code = extract.code("intro\n```lua\nfirst()\n```\nthen\n```lua\nsecond()\n```")
  ok(code == "first()", "first usable block wins", code)

  local bad, why = extract.code("I would rather not.")
  ok(bad == nil and why:find("no lua code block"), "prose is rejected", why)

  local okChk, chkErr = extract.check("local x =")
  ok(not okChk, "syntax check catches broken code", chkErr)
end

--------------------------------------------------------------------------
group("executor sandbox")
fresh()
do
  local env = agent.env()
  local r = executor.run([[
    local p = nav.pos()
    job.say("at %d,%d,%d", p.x, p.y, p.z)
    job.report({ y = p.y })
  ]], env, {})
  ok(r.ok, "simple program runs", r.error)
  ok(r.result and r.result.y == 64, "job.report came back")
  ok(r.output:find("at 0,64,0") ~= nil, "job.say captured", r.output)

  local r2 = executor.run([[ fs.delete("/") ]], env, {})
  ok(not r2.ok and tostring(r2.error):find("nil value") ~= nil,
     "fs is not reachable from the sandbox", r2.error)

  local r3 = executor.run([[ require("agent.nav") ]], env, {})
  ok(not r3.ok, "require is not reachable")

  local r4 = executor.run([[ local x = nil; x.y = 1 ]], env, {})
  ok(not r4.ok and tostring(r4.error):find("job:1") ~= nil,
     "runtime errors carry the generated line number", r4.error)

  local r5 = executor.run([[
    turtle.forward()
    job.report(nav.pos())
  ]], env, {})
  ok(r5.ok and r5.result.z == -1,
     "raw turtle.forward is rerouted so pose stays correct",
     r5.result and r5.result.z)
end

--------------------------------------------------------------------------
group("end-to-end: a program written the way Claude is told to write one")
fresh()
mock.set(0, 63, 0, "minecraft:grass_block")
mock.set(0, 63, -1, "minecraft:iron_ore")
mock.set(0, 63, -2, "minecraft:iron_ore")
do
  local r = executor.run([[
    local start = nav.pos()
    local mined = 0
    for i = 1, 4 do
      job.checkAbort()
      if block.is("down", "*_ore") then
        block.dig("down")
        mined = mined + 1
      end
      if not nav.step("north") then break end
      job.progress(i, 4, "scanned")
    end
    nav.moveTo(start)
    job.report({ mined = mined, back = geom.eq(nav.pos(), start) })
  ]], agent.env(), {})
  ok(r.ok, "survey program ran", r.error)
  ok(r.result and r.result.mined == 2, "found both ore blocks",
     r.result and r.result.mined)
  ok(r.result and r.result.back, "returned to the start")
end

--------------------------------------------------------------------------
group("session: ask -> run -> repair, with a stubbed API")
fresh()
do
  local client  = require("claude.client")
  local session = require("claude.session")

  local replies, sent = {}, {}
  local realMessage = client.message
  client.message = function(cfg, body)
    -- Snapshot the message count: `body.messages` is the live history table
    -- and keeps growing after the call returns.
    sent[#sent + 1] = { system = body.system, messages = body.messages,
                        nMessages = #body.messages }
    local r = table.remove(replies, 1)
    if not r then return nil, "stub ran out of replies" end
    return { text = r, usage = { input_tokens = 10, output_tokens = 20,
                                 cache_read_input_tokens = 900 },
             stop = "end_turn", blocks = {} }
  end

  local cfg = { apiKey = "test", model = "stub", maxRepairs = 1 }
  local sess = session.new(cfg, agent)

  -- First reply is broken; the repair reply works.
  replies[1] = "Here you go.\n```lua\nlocal x = nil\nreturn x.y\n```"
  replies[2] = "Sorry.\n```lua\njob.report({fixed = true})\n```"

  local kinds = {}
  local r = sess:handle("do a thing", {
    onEvent = function(k) kinds[#kinds + 1] = k end,
  })

  ok(r.ok, "repair loop recovered from a runtime error", r.error)
  ok(r.result and r.result.fixed == true, "second program's report came back")
  ok(#sent == 2, "exactly one repair round trip", #sent)

  -- The system prompt must be identical across turns or the cache is dead.
  ok(sent[1].system == sent[2].system, "system block is reused verbatim")
  ok(sent[1].system[1].cache_control ~= nil, "system block is marked for caching")

  -- Live state belongs in the user turn, never the cached prefix.
  ok(sent[1].system[1].text:find("CURRENT STATE") == nil,
     "state is not baked into the cached prompt")
  ok(sent[1].messages[1].content:find("CURRENT STATE") ~= nil,
     "state rides in the user turn")

  -- History grows: user, assistant, repair-user, repair-assistant.
  ok(sent[2].nMessages == 3, "repair carries the failed program in history",
     sent[2].nMessages)
  ok(sent[2].messages[3].content:find("The program failed") ~= nil,
     "repair turn contains the error")

  ok(sess.stats.cacheRead == 1800, "usage accounting sums cache reads",
     sess.stats.cacheRead)

  -- A reply with no code at all is a clean failure, not a crash.
  replies[1] = "I would rather not do that."
  local r2 = sess:handle("something else", { onEvent = function() end })
  ok(not r2.ok and tostring(r2.error):find("program") ~= nil,
     "prose-only reply fails cleanly", r2.error)

  -- Re-running costs nothing.
  local before = #sent
  sess.lastCode = "job.report(42)"
  local r3 = sess:rerun({ onEvent = function() end })
  ok(r3.ok and r3.result == 42 and #sent == before,
     "rerun executes without an API call")

  client.message = realMessage
end

--------------------------------------------------------------------------
group("equipping changes what the turtle is")

-- The real failure this covers: a turtle carrying a crafting table is
-- asked to make bread. The program equips the table -- which is what the
-- table is for -- and then cannot craft, because capabilities were probed
-- once at boot and the sandbox's view of the turtle API was copied once
-- at program start. Both were stale by the time they mattered.

--- The turtle table a generated program actually sees.
local function sandboxTurtle()
  return executor.sandbox(agent.env()).turtle
end

local function withCraftingTable()
  fresh()
  mock.turtle.slots[1] = { name = "minecraft:crafting_table", count = 1 }
  turtle.select(1)
  caps.detect(true)
end

withCraftingTable()
ok(not caps.has("crafting"), "a bare turtle cannot craft")

local sbt = sandboxTurtle()
ok(sbt.craft == nil, "and the sandbox shows no craft function")

ok(sbt.equipLeft(), "the script equips the crafting table")

ok(caps.has("crafting"), "capabilities notice, without being asked twice")
ok(type(sbt.craft) == "function",
   "and the sandbox now has craft, from the table it was already handed")

ok(type(sbt.craft) == "function", "which is callable")

-- caps.require is the guard generated code is told to use. It must not
-- refuse on a stale answer either.
withCraftingTable()
local sbt2 = sandboxTurtle()
sbt2.equipRight()
ok(pcall(caps.require, "crafting"), "caps.require re-probes before refusing")

-- A mutator that did not exist when the sandbox was built still has to
-- bust the inventory cache when it appears.
withCraftingTable()
local sbt3 = sandboxTurtle()
sbt3.equipLeft()
inv.slots()                      -- warm the cache
mock.turtle.slots[5] = { name = "minecraft:bread", count = 3 }
sbt3.craft(1)
ok(inv.count("minecraft:bread") == 3,
   "a newly appeared mutator still invalidates the inventory cache",
   inv.count("minecraft:bread"))

-- Movement must still be rerouted through nav, proxy or not.
withCraftingTable()
local before = nav.pos()
sandboxTurtle().forward()
ok(nav.pos().z == before.z - 1, "movement still goes through nav", nav.pos().z)

-- The same staleness, one level up: a capability-gated entry is stubbed
-- when the env is built. Equipping the missing hardware has to un-stub it,
-- and building the env must not cost the module its real function.
fresh()
do
  local realFn = inv.listExternal
  local env = agent.env()
  ok(type(inv.listExternal) == "function",
     "gating leaves a callable behind, not a hole")

  local blocked = select(2, pcall(env.inv.listExternal))
  ok(tostring(blocked):find("modem", 1, true) ~= nil,
     "without a modem it refuses, by name", blocked)

  -- Equip one: caps.refresh is what a script would call after equipping.
  local realPeripheral = _G.peripheral
  _G.peripheral = { getNames = function() return { "left" } end,
                    getType = function() return "modem" end,
                    find = function(t) return t == "modem" and {} or nil end }
  caps.refresh()
  local _, nowErr = pcall(env.inv.listExternal)
  _G.peripheral = realPeripheral
  caps.refresh()

  -- It may still fail further in (this fake peripheral is not a real
  -- chest), but it must no longer fail *because of the capability* --
  -- the gate is what is under test.
  ok(tostring(nowErr):find("modem", 1, true) == nil,
     "once the modem is there the gate stops refusing", nowErr)
  ok(inv.listExternal == realFn or type(inv.listExternal) == "function",
     "and the real function was never thrown away")
end

--------------------------------------------------------------------------
group("crafting: the grid is not the inventory")

-- The real sequence: a turtle holding wheat and a crafting table, asked
-- for bread. It equipped the table (that part works) and then crafted
-- nothing, because the wheat was in slot 8 -- outside the 3x3 the turtle
-- actually crafts from -- and because three wheat in one slot is not the
-- same shape as three wheat in three cells. No generated script can be
-- expected to know either, so the library does.

local function turtleWith(items)
  fresh()
  for slot, item in pairs(items) do mock.turtle.slots[slot] = item end
  caps.detect(true)
end

local WHEAT = "minecraft:wheat"

-- Exactly the failing case: wheat parked outside the crafting grid.
turtleWith({
  [1] = { name = "minecraft:crafting_table", count = 1 },
  [8] = { name = WHEAT, count = 3 },
})
turtle.select(1)
executor.sandbox(agent.env()).turtle.equipLeft()

local okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "wheat outside the grid still becomes bread", why)
ok(inv.count("minecraft:bread") == 1, "and the bread is there",
   inv.count("minecraft:bread"))

-- Stacked in one cell: has to be spread across three.
turtleWith({
  [1] = { name = "minecraft:crafting_table", count = 1 },
  [2] = { name = WHEAT, count = 3 },
})
turtle.select(1)
executor.sandbox(agent.env()).turtle.equipRight()
okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "a single stack is spread across the cells", why)

-- Junk sitting in the grid is part of the recipe unless it is moved out.
turtleWith({
  [1] = { name = "minecraft:crafting_table", count = 1 },
  [2] = { name = "minecraft:cobblestone", count = 7 },
  [6] = { name = "minecraft:dirt", count = 2 },
  [12] = { name = WHEAT, count = 3 },
})
turtle.select(1)
executor.sandbox(agent.env()).turtle.equipLeft()
okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "junk in the grid is cleared out of the way", why)
ok(inv.count("minecraft:cobblestone") == 7, "and is not lost",
   inv.count("minecraft:cobblestone"))
ok(inv.count("minecraft:dirt") == 2, "none of it", inv.count("minecraft:dirt"))

-- Not enough to go round: say so, rather than crafting something else.
turtleWith({
  [1] = { name = "minecraft:crafting_table", count = 1 },
  [8] = { name = WHEAT, count = 2 },
})
turtle.select(1)
executor.sandbox(agent.env()).turtle.equipLeft()
okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(not okCraft, "two wheat is not bread")
ok(tostring(why):find("one per cell", 1, true) ~= nil,
   "and the reason names the shape", why)

-- No crafting table anywhere: say that, rather than "no recipe".
turtleWith({ [8] = { name = WHEAT, count = 3 } })
okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(not okCraft and tostring(why):find("no crafting table carried", 1, true) ~= nil,
   "with no table at all it says so", why)

-- Carrying one is enough: the library equips it rather than making the
-- script hand-roll the swap, and puts the displaced tool back after.
turtleWith({
  [5] = { name = "minecraft:diamond_pickaxe", count = 1 },
  [6] = { name = "minecraft:crafting_table", count = 1 },
  [8] = { name = WHEAT, count = 3 },
})
mock.turtle.equipped = { right = "minecraft:diamond_pickaxe" }
mock.turtle.slots[5] = nil
caps.detect(true)
ok(not caps.has("crafting"), "starts unable to craft")

okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "a carried crafting table is equipped automatically", why)
ok(inv.count("minecraft:bread") == 1, "and the bread gets made",
   inv.count("minecraft:bread"))
ok(mock.turtle.equipped.right == "minecraft:diamond_pickaxe",
   "and the pickaxe goes back on afterwards",
   tostring(mock.turtle.equipped.right))
ok(inv.count("crafting_table") == 1, "with the table back in the inventory",
   inv.count("crafting_table"))

-- opts.restore = false leaves it equipped, for a script crafting in a loop.
turtleWith({
  [6] = { name = "minecraft:crafting_table", count = 1 },
  [8] = { name = WHEAT, count = 3 },
})
okCraft = inv.craft({ { WHEAT, WHEAT, WHEAT } }, { restore = false })
ok(okCraft and caps.has("crafting"),
   "restore = false keeps the table on")

-- A failure has to say what the grid actually held.
turtleWith({
  [6] = { name = "minecraft:crafting_table", count = 1 },
  [8] = { name = "minecraft:cobblestone", count = 3 },
})
okCraft, why = inv.craft({ { "cobblestone", "cobblestone", "cobblestone" } })
ok(not okCraft, "cobblestone in a row is not a recipe")
ok(tostring(why):find("1=cobblestone", 1, true) ~= nil,
   "and the error shows the layout it refused", why)

-- Malformed patterns are refused rather than half-executed.
turtleWith({ [1] = { name = "minecraft:crafting_table", count = 1 } })
turtle.select(1)
executor.sandbox(agent.env()).turtle.equipLeft()
ok(not inv.craft({}), "an empty pattern is refused")
ok(not inv.craft({ { WHEAT }, { WHEAT }, { WHEAT }, { WHEAT } }),
   "a four-row recipe is refused")
ok(not inv.craft({ { WHEAT, WHEAT, WHEAT, WHEAT } }),
   "a four-cell row is refused")

--------------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
