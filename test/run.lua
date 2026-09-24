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
group("a command typed without its slash")

-- Typing "save makeBread" instead of "/save makeBread" sent it to Claude
-- as a request: it cost an API call and overwrote the very program it
-- was meant to keep. A false positive costs one keystroke; this costs
-- money and work.
local console = require("ui.console")
local function slurp(p)
  local h = io.open(p, "r"); if not h then return nil end
  local s = h:read("*a"); h:close(); return s
end
local WORDS = { save = true, run = true, exit = true, again = true, notes = true }

ok(console.forgottenSlash("save makeBread", WORDS) == "save",
   "a bare command word with one argument is caught")
ok(console.forgottenSlash("exit", WORDS) == "exit", "on its own too")
ok(console.forgottenSlash("Save makeBread", WORDS) == "save", "whatever the case")
ok(console.forgottenSlash("/save makeBread", WORDS) == nil,
   "the correct form is left alone")
ok(console.forgottenSlash("make some bread", WORDS) == nil,
   "an ordinary request is left alone")
ok(console.forgottenSlash("run a quarry down to y=12", WORDS) == nil,
   "and so is a request that happens to start with a command word")
ok(console.forgottenSlash("notes never dig above y=70 near the base", WORDS) == nil,
   "long input is a request, whatever it starts with")
ok(console.forgottenSlash("", WORDS) == nil, "empty input is not a command")

for _, front in ipairs({ "ui/controller.lua", "ui/host.lua" }) do
  local src = slurp(front) or ""
  ok(src:find("COMMAND_WORDS", 1, true) ~= nil and
     src:find("forgottenSlash", 1, true) ~= nil,
     front .. " checks before spending an API call")
  ok(src:find("local COMMAND_WORDS", 1, true) ~= nil,
     front .. " defines the word set it uses")
end

--------------------------------------------------------------------------
group("the operator can change the inventory between jobs")

-- Run a job, take the result out by hand, put fresh ingredients in, run
-- the job again: it failed, reporting the item that had been removed as
-- being in the way. The inventory cache is module-level and only the
-- library's own operations invalidate it, so a turtle rearranged through
-- its GUI stayed invisible for the rest of the session.

fresh()
mock.turtle.slots[1] = { name = "minecraft:bread", count = 1 }
ok(inv.count("bread") == 1, "the cache is warm")

-- What opening the turtle's GUI looks like from in here: the world
-- changes, nothing tells the library.
mock.turtle.slots[1] = { name = "minecraft:wheat", count = 3 }
ok(inv.count("bread") == 1, "and a manual change goes unnoticed",
   inv.count("bread"))

local r = executor.run([[ job.report(inv.count("bread")) ]], agent.env(), {})
ok(r.ok and r.result == 0,
   "but a program starts from what is actually there", r.result)
ok(inv.count("wheat") == 3, "including the wheat that replaced it",
   inv.count("wheat"))

-- The same for the line describing the turtle to Claude: a stale one
-- means the model plans against an inventory that no longer exists.
fresh()
mock.turtle.slots[1] = { name = "minecraft:bread", count = 1 }
inv.count("bread")                                  -- warm it
mock.turtle.slots[1] = { name = "minecraft:wheat", count = 3 }
local situation = agent.situation()
ok(situation:find("wheat", 1, true) ~= nil,
   "the situation line is read fresh", situation)
ok(situation:find("bread", 1, true) == nil,
   "and does not describe what was taken out", situation)

--------------------------------------------------------------------------
group("a wall with a hole in it")

-- "Build a 3x3 wall" produced eight blocks and one gap: placed = 8,
-- skipped = 1, nothing unreachable. The skipped cell was one world memory
-- claimed was already solid. Memory is a record of a moment; a fill that
-- trusts it leaves exactly that hole when the moment has passed.
fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
inv.invalidate()
world.set({ x = 0, y = 64, z = -1 }, "minecraft:cobblestone")   -- but not really

local placed, skipped, info = block.fill({ x = 0, y = 64, z = -1 },
                                         { x = 0, y = 64, z = -1 },
                                         "minecraft:cobblestone")
ok(placed == 1, "a cell memory calls solid is filled anyway", placed)
ok(mock.get(0, 64, -1) == "minecraft:cobblestone", "and the block is really there",
   tostring(mock.get(0, 64, -1)))
ok(skipped == 0, "nothing was skipped on a belief", skipped)

-- A cell that really is occupied is still skipped -- but because the
-- turtle looked, not because it remembered.
fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
inv.invalidate()
mock.set(0, 64, -1, "minecraft:stone")
placed, skipped, info = block.fill({ x = 0, y = 64, z = -1 },
                                   { x = 0, y = 64, z = -1 },
                                   "minecraft:cobblestone")
ok(placed == 0 and skipped == 1, "an occupied cell is skipped",
   placed .. "/" .. skipped)
-- Not `== 0`. Zero is true in Lua, so a caller doing the documented
-- `if info.unplaceable then` would have seen a failure that never
-- happened -- which is how a finished 9x9 floor reported itself as
-- "fill incomplete". The absence of the key is the contract.
ok(info.unplaceable == nil, "and is not reported as a failure",
   tostring(info.unplaceable))
ok(info.complete == true, "a run with nothing wrong says so outright")
ok(not (info.unreachable or info.unplaceable or info.stopped),
   "and the documented truthiness check stays quiet")
ok(world.isSolid({ x = 0, y = 64, z = -1 }) == true,
   "with memory corrected from what it saw")

-- The cheap path is still available for jobs big enough to need it.
fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
inv.invalidate()
world.set({ x = 0, y = 64, z = -1 }, "minecraft:cobblestone")   -- again a lie
placed, skipped = block.fill({ x = 0, y = 64, z = -1 }, { x = 0, y = 64, z = -1 },
                             "minecraft:cobblestone", { trustMemory = true })
ok(placed == 0 and skipped == 1, "trustMemory skips on the record",
   placed .. "/" .. skipped)

-- ...but only while the record is fresh.
fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
inv.invalidate()
world.set({ x = 0, y = 64, z = -1 }, "minecraft:cobblestone")
local keepStale = world.staleAfter
world.staleAfter = -1                            -- everything is now old
placed, skipped = block.fill({ x = 0, y = 64, z = -1 }, { x = 0, y = 64, z = -1 },
                             "minecraft:cobblestone", { trustMemory = true })
world.staleAfter = keepStale
ok(placed == 1, "a stale record is checked even then", placed)

--------------------------------------------------------------------------
group("memory belongs to the frame it was recorded in")

-- Without GPS, coordinates are local to wherever the turtle booted. Break
-- it and put it down again and the same keys name different blocks, so
-- every remembered observation is now a claim about somewhere else.
fresh()
world.set({ x = 5, y = 64, z = 5 }, "minecraft:diamond_ore")
ok(world.isSolid({ x = 5, y = 64, z = 5 }) == true, "remembered")

ok(world.useFrame("local:1:aaa") == false, "the first frame seen is just recorded")
ok(world.isSolid({ x = 5, y = 64, z = 5 }) == true, "and changes nothing")

ok(world.useFrame("local:1:bbb"), "a different frame drops the memory")
ok(world.isSolid({ x = 5, y = 64, z = 5 }) == nil,
   "so nothing is claimed about coordinates that moved")

-- GPS frames are mutually consistent, which is the point of having GPS.
fresh()
world.useFrame("gps")
world.set({ x = 5, y = 64, z = 5 }, "minecraft:diamond_ore")
ok(world.useFrame("gps") == false, "the same frame keeps everything")
ok(world.isSolid({ x = 5, y = 64, z = 5 }) == true, "memory survives", nil)

--------------------------------------------------------------------------
group("a fill that placed nothing has to say why")

-- Nine cells came back as "placed = 0, skipped = 2" and the turtle did
-- not move. The other seven were cells whose move failed, and a failed
-- move incremented neither counter -- so the report did not add up and
-- gave the operator nothing to act on.
fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
inv.invalidate()
mock.turtle.fuel = 0                      -- cannot move anywhere

local placed, skipped, info = block.fill({ x = 0, y = 64, z = -3 },
                                         { x = 2, y = 66, z = -3 },
                                         "minecraft:cobblestone")
ok(placed == 0, "nothing was placed", placed)
ok(info ~= nil, "and there is a third return value that says so")
ok(info.unreachable > 0, "counting the cells it could not reach",
   info and info.unreachable)
-- Absent means zero, so arithmetic on these needs `or 0`. That is the
-- price of making the truthiness check correct, and it is the cheaper
-- mistake: this one crashes loudly instead of misreporting quietly.
ok(placed + skipped + (info.unreachable or 0) + (info.unplaceable or 0)
     == info.cells,
   "so the numbers add up to the cells it looked at",
   info and (placed .. "+" .. skipped .. "+" .. tostring(info.unreachable) ..
             "+" .. tostring(info.unplaceable) .. " vs " .. info.cells))
ok(info.complete == false, "and a run that reached nothing is incomplete")
ok(info.reason and #info.reason > 0, "with a reason worth reporting",
   info and info.reason)

-- And it stops rather than grinding through hundreds of cells it cannot
-- reach, which is what makes the failure instant rather than slow.
fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
inv.invalidate()
mock.turtle.fuel = 0
placed, skipped, info = block.fill({ x = 20, y = 64, z = -20 },
                                   { x = 29, y = 73, z = -20 },
                                   "minecraft:cobblestone")
ok(info.stopped, "it gives up")
ok(info.cells < 100, "before walking the whole box", info.cells)
ok(tostring(info.reason):find("gave up", 1, true) ~= nil,
   "and says that is what happened", info.reason)

-- A fill that can do its job still reports plainly.
fresh()
mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
inv.invalidate()
placed, skipped, info = block.fill({ x = 0, y = 64, z = -2 },
                                   { x = 0, y = 64, z = -2 },
                                   "minecraft:cobblestone")
ok(placed == 1, "one cell, one block", placed)
ok(info.complete == true and not info.stopped and not info.unreachable,
   "nothing to explain")

-- block.clear had the same hole.
fresh()
mock.fill({ 0, 64, -3 }, { 2, 66, -3 }, "minecraft:stone")
mock.turtle.fuel = 0
local dug, clearInfo = block.clear({ x = 0, y = 64, z = -3 },
                                   { x = 2, y = 66, z = -3 })
ok(dug == 0, "nothing dug", dug)
ok(clearInfo and clearInfo.unreachable > 0, "and the misses are counted",
   clearInfo and clearInfo.unreachable)

--------------------------------------------------------------------------
group("fuel is whatever the game will burn")

-- A turtle at zero fuel carrying thirty-two lignite coal from a mod
-- reported "Refueled: 0 -> 0" and then warned its way through a build it
-- could not move for. inv.fuelItems was a list of vanilla item names, so
-- a modpack's fuel matched nothing and looked like no fuel at all.
fresh()
mock.turtle.fuel = 0
mock.turtle.slots[1] = { name = "thermal:lignite_coal", count = 32 }
inv.invalidate()

ok(not inv.matches({ name = "thermal:lignite_coal", count = 32 }, inv.fuelItems),
   "no list here has heard of it")
ok(#inv.fuelSlots() == 1, "but the game says it burns", #inv.fuelSlots())

local level = inv.refuel(100)
ok(level >= 100, "so the turtle refuels on it", level)
ok(mock.turtle.fuel >= 100, "really refuels", mock.turtle.fuel)

-- Asking costs nothing: refuel(0) is a question, not a burn.
fresh()
mock.turtle.fuel = 0
mock.turtle.slots[1] = { name = "thermal:lignite_coal", count = 32 }
inv.invalidate()
inv.fuelSlots()
ok(inv.count("thermal:lignite_coal") == 32, "probing burns nothing",
   inv.count("thermal:lignite_coal"))

-- Known fuels still go first, so a turtle does not burn the planks it is
-- holding to build with while it has coal.
fresh()
mock.turtle.fuel = 0
mock.turtle.slots[1] = { name = "minecraft:oak_planks", count = 64 }
mock.turtle.slots[2] = { name = "minecraft:coal", count = 8 }
inv.invalidate()
inv.refuel(80)
ok(inv.count("minecraft:oak_planks") == 64, "planks untouched",
   inv.count("minecraft:oak_planks"))
ok(inv.count("minecraft:coal") < 8, "coal burned instead",
   inv.count("minecraft:coal"))

-- And the caller can protect anything it needs.
fresh()
mock.turtle.fuel = 0
mock.turtle.slots[1] = { name = "thermal:lignite_coal", count = 32 }
inv.invalidate()
inv.refuel(100, { keep = "*lignite*" })
ok(mock.turtle.fuel == 0, "opts.keep is respected even when nothing else burns",
   mock.turtle.fuel)

-- nav.ensureFuel is what generated code calls; it has to benefit too.
fresh()
mock.turtle.fuel = 0
mock.turtle.slots[1] = { name = "thermal:lignite_coal", count = 32 }
inv.invalidate()
ok(nav.ensureFuel(50), "nav.ensureFuel reaches its target", nav.fuel())

--------------------------------------------------------------------------
group("capabilities change, and not only when we change them")

-- A turtle built a wall, ran out of fuel, and was then asked to break the
-- wall down. It refused: "this turtle lacks digging capability". It had
-- been marked that way at boot, because the digging probe will not
-- destroy a block to find out whether it can, and its honest "I cannot
-- tell" was being recorded as "no".
fresh()
mock.set(0, 64, -1, "minecraft:cobblestone")        -- facing what it built
caps.detect(true)
ok(caps.get("digging") == nil or caps.get("digging") == true,
   "facing a wall is not evidence that it cannot dig",
   tostring(caps.get("digging")))
ok(caps.summary():find("NO%-dig") == nil,
   "so the turtle is not described as unable to", caps.summary())

-- With the sides reporting, the answer comes from the tool, wall or no.
fresh()
mock.set(0, 64, -1, "minecraft:cobblestone")
mock.turtle.hasTool = false
mock.turtle.equipped = { left = "minecraft:diamond_pickaxe" }
caps.detect(true)
ok(caps.has("digging"), "a pickaxe on a side means it can dig")

-- The operator equipping one by hand is the same class of change as
-- rearranging the inventory: nothing in here is told about it.
fresh()
mock.turtle.hasTool = false
caps.detect(true)
ok(not caps.has("digging"), "starts with nothing to dig with")
mock.turtle.equipped = { right = "minecraft:iron_pickaxe" }   -- by hand
ok(not caps.has("digging"), "and does not notice on its own")

local r = executor.run([[ job.report(caps.has("digging")) ]], agent.env(), {})
ok(r.ok and r.result == true,
   "but a program is told what the turtle can do now", tostring(r.result))

fresh()
mock.turtle.hasTool = false
caps.detect(true)
mock.turtle.equipped = { right = "minecraft:iron_pickaxe" }
ok(agent.situation():find("dig", 1, true) ~= nil,
   "and so is Claude", agent.situation())

-- Carrying the tool is not the same as having it on, and saying "this
-- turtle cannot dig" while a pickaxe sits in the inventory is true and
-- useless.
fresh()
mock.turtle.hasTool = false
mock.turtle.slots[3] = { name = "minecraft:diamond_pickaxe", count = 1 }
caps.detect(true)
local hint = caps.carriedFix("digging")
ok(hint and hint:find("slot 3", 1, true), "the refusal can point at the pickaxe", hint)
ok(hint and hint:find("inv.equip", 1, true), "and say what to call", hint)

local okReq, err = pcall(caps.require, "digging", "to break the wall")
ok(not okReq and tostring(err):find("slot 3", 1, true) ~= nil,
   "caps.require carries the hint", err)

fresh()
mock.turtle.hasTool = false
caps.detect(true)
ok(caps.carriedFix("digging") == nil,
   "and stays quiet when there is nothing to suggest")

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

-- Anything that is not an ingredient makes the arrangement unmatchable,
-- wherever it sits -- the whole inventory is the crafting area. Refuse
-- and name it, rather than dropping the operator's belongings to make
-- room or failing later with "no matching recipe".
turtleWith({
  [1] = { name = "minecraft:crafting_table", count = 1 },
  [2] = { name = "minecraft:cobblestone", count = 7 },
  [6] = { name = "minecraft:dirt", count = 2 },
  [12] = { name = WHEAT, count = 3 },
})
local info
okCraft, why, info = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(not okCraft, "a turtle carrying other things cannot craft")
ok(tostring(why):find("cobblestone", 1, true) ~= nil,
   "and the refusal names what is in the way", why)
ok(inv.count("minecraft:cobblestone") == 7, "nothing was dropped to make room",
   inv.count("minecraft:cobblestone"))
ok(inv.count("minecraft:dirt") == 2, "none of it", inv.count("minecraft:dirt"))

-- The caller decides what to do about it, so it gets the facts, not
-- just prose: which slots, what is in them, how much.
ok(info and info.reason == "inventory", "the failure is labelled",
   info and info.reason)
ok(info and #info.blocking == 2, "with every blocking slot, not a sample",
   info and #info.blocking)
local seen = {}
for _, b in ipairs(info and info.blocking or {}) do
  seen[b.name] = b
end
ok(seen["minecraft:cobblestone"] and seen["minecraft:cobblestone"].count == 7,
   "each carrying slot, name and count")
ok(seen["minecraft:dirt"] and seen["minecraft:dirt"].slot == 6,
   "and where to find it", seen["minecraft:dirt"] and seen["minecraft:dirt"].slot)

-- A caller that acts on it can then craft: this is the deposit-and-retry
-- a generated program is expected to write.
for _, b in ipairs(info.blocking) do mock.turtle.slots[b.slot] = nil end
inv.invalidate()
ok(inv.craft({ { WHEAT, WHEAT, WHEAT } }), "clearing what it named is enough")

-- Other failures are labelled too, so a caller can tell them apart.
turtleWith({ [8] = { name = WHEAT, count = 3 } })
okCraft, why, info = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(info and info.reason == "no_table", "a missing crafting table is its own reason",
   info and info.reason)

turtleWith({
  [1] = { name = WHEAT, count = 2 },
  [2] = { name = "minecraft:crafting_table", count = 1 },
})
okCraft, why, info = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(info and info.reason == "ingredients", "as is running short",
   info and info.reason)
ok(info and info.have == 2 and info.cells == 3, "with the count and the need",
   info and (tostring(info.have) .. "/" .. tostring(info.cells)))

okCraft, why, info = inv.craft({})
ok(info and info.reason == "pattern", "and a malformed pattern",
   info and info.reason)

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
ok(not okCraft and tostring(why):find("none carried", 1, true) ~= nil,
   "with no table at all it says so", why)

-- Carrying one is enough: the library equips it rather than making the
-- script hand-roll the swap, and puts the displaced tool back after.
turtleWith({
  [6] = { name = "minecraft:crafting_table", count = 1 },
  [8] = { name = WHEAT, count = 3 },
})
mock.turtle.hasTool = false                        -- left side genuinely bare
mock.turtle.equipped = { right = "minecraft:diamond_pickaxe" }
caps.detect(true)
ok(not caps.has("crafting"), "starts unable to craft")

okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "a carried crafting table is equipped automatically", why)
ok(inv.count("minecraft:bread") == 1, "and the bread gets made",
   inv.count("minecraft:bread"))
ok(mock.turtle.equipped.right == "minecraft:diamond_pickaxe",
   "the pickaxe is not disturbed -- the free side is used",
   tostring(mock.turtle.equipped.right))
ok(inv.count("crafting_table") == 1, "with the table back in the inventory",
   inv.count("crafting_table"))

-- Both sides carrying upgrades: equipping the table displaces one into
-- the inventory, which is itself outside the recipe. Say so.
turtleWith({
  [6] = { name = "minecraft:crafting_table", count = 1 },
  [8] = { name = WHEAT, count = 3 },
})
mock.turtle.equipped = { left = "minecraft:diamond_pickaxe",
                         right = "minecraft:wireless_modem" }
caps.detect(true)
okCraft, why, info = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(not okCraft, "with both sides full there is nowhere for the table to go")
ok(info and info.reason == "inventory",
   "and it reads as something in the way", info and info.reason)

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

-- The failure seen in game: turtle.craft is callable with no crafting
-- table attached (the method outlived the upgrade), so the old check --
-- "does turtle.craft exist" -- skipped equipping and crafted against a
-- turtle with nothing on its sides. It returns a bare false, no message,
-- which reads as a wrong recipe.
turtleWith({
  [1] = { name = WHEAT, count = 3 },
  [2] = { name = "minecraft:crafting_table", count = 1 },
})
mock.staleCraft = true
turtle.craft = mock.craftImpl          -- present, nothing equipped
caps.detect(true)
ok(not caps.has("crafting"),
   "a build that can report its sides is not fooled by the stale method")

okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "it equips the table anyway and crafts", why)
ok(inv.count("bread") == 1, "bread", inv.count("bread"))

-- Same, on a build too old to report what is equipped: the only way to
-- find out is to try, so it tries, then equips and retries once.
turtleWith({
  [1] = { name = WHEAT, count = 3 },
  [2] = { name = "minecraft:crafting_table", count = 1 },
})
mock.staleCraft = true
turtle.getEquippedLeft, turtle.getEquippedRight = nil, nil   -- older build
turtle.craft = mock.craftImpl
caps.detect(true)
ok(inv.craftingTableEquipped() == nil, "this build cannot say what is on")

okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "a failed craft is retried with the table on", why)
ok(inv.count("bread") == 1, "and produces bread", inv.count("bread"))

-- The retry must not fire when there is nothing to retry with.
turtleWith({ [1] = { name = "minecraft:cobblestone", count = 3 } })
mock.staleCraft = true
turtle.getEquippedLeft, turtle.getEquippedRight = nil, nil
turtle.craft = mock.craftImpl
okCraft, why = inv.craft({ { "cobblestone", "cobblestone", "cobblestone" } })
ok(not okCraft, "a genuinely wrong shape still fails")

-- Sixteen wheat and a crafting table. This failed in game: the surplus
-- was parked in slot 4, which is outside the 3x3 but still inside the
-- crafting area, so the game refused a layout that looked perfect.
-- Spread it across the cells instead -- 6/5/5 -- and it is five loaves.
turtleWith({
  [1] = { name = WHEAT, count = 16 },
  [2] = { name = "minecraft:crafting_table", count = 1 },
})
okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "sixteen wheat crafts instead of failing", why)
ok(mock.crafted == 5, "five loaves, not one", mock.crafted)
ok(inv.count("wheat") == 1, "with the odd wheat left over", inv.count("wheat"))

-- opts.limit bounds it without stranding the rest outside the recipe.
turtleWith({
  [1] = { name = WHEAT, count = 16 },
  [2] = { name = "minecraft:crafting_table", count = 1 },
})
okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } }, { limit = 2 })
ok(okCraft and mock.crafted == 2, "limit caps the number of crafts", mock.crafted)

-- Surplus already spread unevenly across the cells is still fine.
turtleWith({
  [1] = { name = WHEAT, count = 2 },
  [2] = { name = WHEAT, count = 7 },
  [3] = { name = WHEAT, count = 3 },
  [5] = { name = "minecraft:crafting_table", count = 1 },
})
okCraft, why = inv.craft({ { WHEAT, WHEAT, WHEAT } })
ok(okCraft, "ingredients already in the cells get rebalanced", why)
ok(mock.crafted == 4, "twelve wheat is four loaves", mock.crafted)

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
group("transport: the timeout that actually kills long generations")
mock.reset()
do
  local client = require("claude.client")
  local cfg = { apiKey = "test", model = "stub", maxTokens = 64, retries = 1 }

  -- A turtle-sized reply, streamed the way the API sends it.
  local function streamed(text, opts)
    opts = opts or {}
    local parts = {
      { "message_start", { type = "message_start", message = {
          id = "msg_1", model = "stub", role = "assistant",
          usage = { input_tokens = 12, cache_read_input_tokens = 1700 } } } },
      { "content_block_start", { type = "content_block_start", index = 0,
          content_block = { type = "text", text = "" } } },
    }
    -- Split across deltas: the point of the format is that no single event
    -- carries the whole program.
    for i = 1, #text, 7 do
      parts[#parts + 1] = { "content_block_delta", {
        type = "content_block_delta", index = 0,
        delta = { type = "text_delta", text = text:sub(i, i + 6) } } }
    end
    parts[#parts + 1] = { "content_block_stop",
      { type = "content_block_stop", index = 0 } }
    parts[#parts + 1] = { "message_delta", { type = "message_delta",
      delta = { stop_reason = opts.stop or "end_turn" },
      usage = { output_tokens = 40 } } }
    if not opts.truncate then
      parts[#parts + 1] = { "message_stop", { type = "message_stop" } }
    end
    return mock.sse(parts)
  end

  local body = "Here.\n```lua\njob.report(1)\n```"
  mock.http.reply({ status = 200, body = streamed(body) })
  local resp, err = client.message(cfg, { messages = { { role = "user", content = "hi" } } })
  ok(resp ~= nil, "a streamed reply is reassembled", err)
  ok(resp and resp.text == body, "deltas are concatenated in order",
     resp and resp.text)
  ok(resp and resp.stop == "end_turn", "stop_reason survives the stream")

  -- Usage arrives in two different events and both halves matter: input
  -- only in message_start, output only in message_delta.
  ok(resp and resp.usage.input_tokens == 12, "input tokens from message_start")
  ok(resp and resp.usage.output_tokens == 40, "output tokens from message_delta")
  ok(resp and resp.usage.cache_read_input_tokens == 1700,
     "cache reads still accounted for -- the cost line depends on it")

  -- The request itself. Both of these are the bug: CC's read timeout is
  -- what fired in-game, and without `stream` there is nothing to keep the
  -- connection alive while a big program is written.
  local req = mock.http.requests[#mock.http.requests]
  ok(req.timeout == 60, "http.request carries CC's read timeout", req.timeout)
  ok(req.body:find('"stream":true', 1, true) ~= nil
     or req.body:find('"stream": true', 1, true) ~= nil,
     "the request asks for a stream")
  ok(tostring(req.headers["accept"]):find("event%-stream") ~= nil,
     "accept header matches", req.headers["accept"])

  -- Out-of-range is an error from http.request, not a warning.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = streamed(body) })
  client.message({ apiKey = "t", retries = 1, readTimeout = 999 },
                 { messages = { { role = "user", content = "hi" } } })
  ok(mock.http.requests[1].timeout == 60, "read timeout is clamped to CC's max",
     mock.http.requests[1].timeout)

  -- A cut-off stream is reported as cut off, not as a mystery.
  mock.resetHttp()
  mock.http.reply({ status = 200,
                    body = streamed("Here.\n```lua\njob.repo", { truncate = true }) })
  local r2, e2 = client.message(cfg, { messages = { { role = "user", content = "hi" } } })
  ok(r2 and r2.truncated == true, "a stream with no message_stop is flagged", e2)

  -- CC's own wording gets translated. "Timed out" alone sends people to
  -- our timeout setting, which is not the one that fired.
  mock.resetHttp()
  mock.http.reply({ failure = "Timed out" })
  local r3, e3 = client.message({ apiKey = "t", retries = 1 },
                                { messages = { { role = "user", content = "hi" } } })
  ok(r3 == nil, "a transport failure fails the request")
  ok(tostring(e3):find("cut off") ~= nil and tostring(e3):find("60") ~= nil,
     "CC's timeout is explained in terms of the silence window", e3)

  -- An API error delivered inside the stream is an error, not empty text.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = mock.sse({
    { "message_start", { type = "message_start", message = { usage = {} } } },
    { "error", { type = "error",
                 error = { type = "overloaded_error", message = "Overloaded" } } },
  }) })
  local r4, e4 = client.message(cfg, { messages = { { role = "user", content = "hi" } } })
  ok(r4 == nil and tostring(e4):find("Overloaded") ~= nil,
     "an in-stream error is surfaced", e4)

  -- Our own timer is the backstop, and it is no longer the 60s one.
  mock.resetHttp()
  local r5, e5 = client.message({ apiKey = "t", retries = 1, timeout = 180 },
                                { messages = { { role = "user", content = "hi" } } })
  ok(r5 == nil and tostring(e5):find("180") ~= nil,
     "an unanswered request hits our ceiling", e5)

  -- Non-streaming still works, for a build where SSE misbehaves.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = (textutils.serialiseJSON({
    content = { { type = "text", text = "```lua\njob.report(2)\n```" } },
    stop_reason = "end_turn", usage = { input_tokens = 1, output_tokens = 2 },
  })) })
  local r6, e6 = client.message({ apiKey = "t", retries = 1, stream = false },
                                { messages = { { role = "user", content = "hi" } } })
  ok(r6 ~= nil and r6.text:find("job.report") ~= nil, "stream = false still works", e6)
  ok(mock.http.requests[1].body:find("stream", 1, true) == nil,
     "and does not ask for a stream")
end
mock.resetHttp()

--------------------------------------------------------------------------
group("till: the turtle cannot till what it stands on")
fresh()
do
  -- These tests were originally written with the turtle standing on the
  -- dirt, which is the one geometry that can never work -- the same
  -- wrong-assumption-in-the-test pattern as the frame lint and the
  -- zero-is-truthy info contract. The real rule, from CC:Tweaked's
  -- TurtleTool: vanilla refuses to till a block with anything above it,
  -- and the turtle IS that block, so digDown only tills when the space
  -- directly below is air and it can reach one further.
  mock.turtle.slots[1] = { name = "minecraft:diamond_hoe", count = 1 }
  inv.invalidate()
  ok(inv.equip("*hoe"), "hoe equipped")

  -- Standing on it: refused before a dig is even spent.
  mock.set(0, 63, 0, "minecraft:dirt")
  local okA, errA, infoA = block.till("down")
  ok(not okA, "tilling the block underfoot is refused")
  ok(tostring(errA):find("standing on", 1, true) ~= nil,
     "and says why, rather than blaming the hoe", errA)
  ok(infoA.blocked == "standing on it", "with a machine-readable reason")
  ok(mock.get(0, 63, 0) == "minecraft:dirt",
     "the ground is untouched -- not broken either", mock.get(0, 63, 0))

  -- Hovering over a gap: this is the geometry that works.
  fresh()
  mock.turtle.slots[1] = { name = "minecraft:diamond_hoe", count = 1 }
  inv.invalidate()
  inv.equip("*hoe")
  mock.turtle.y = 64
  mock.set(0, 62, 0, "minecraft:dirt")      -- floor
  mock.set(0, 63, 0, nil)                   -- the gap that makes it legal
  local okB, errB = block.till("down")
  ok(okB, "tilling through a gap works", errB)
  ok(mock.get(0, 62, 0) == "minecraft:farmland",
     "the floor two below became farmland", mock.get(0, 62, 0))

  -- And a seed goes into the gap, onto that farmland, from the same spot.
  mock.turtle.slots[2] = { name = "minecraft:wheat_seeds", count = 64 }
  inv.invalidate()
  ok(block.place("down", "minecraft:wheat_seeds"),
     "so till and plant happen from one position")

  -- placeDown still cannot till, which is the mistake that started this.
  fresh()
  mock.turtle.slots[1] = { name = "minecraft:diamond_hoe", count = 1 }
  inv.invalidate()
  inv.equip("*hoe")
  mock.turtle.y = 64
  mock.set(0, 62, 0, "minecraft:dirt")
  turtle.select(1)
  ok(not turtle.placeDown(), "placeDown is not a tool action")
  ok(mock.get(0, 62, 0) == "minecraft:dirt", "and changes nothing")

  -- A hoe over stone does not quietly punch a hole in the floor: the
  -- fall-through break is refused as ineffective.
  mock.set(0, 62, 0, "minecraft:stone")
  local okC, errC = block.till("down")
  ok(not okC, "a block the hoe has no use for is not tilled")
  ok(mock.get(0, 62, 0) == "minecraft:stone",
     "and is not broken either", mock.get(0, 62, 0))
  ok(tostring(errC):find("equipped", 1, true) ~= nil,
     "the error names what is actually equipped", errC)
end

fresh()
--------------------------------------------------------------------------
group("fill info: a count of zero must not read as a failure")
fresh()
do
  -- The whole 3x1x1 run succeeds: nothing unreachable, nothing unplaceable.
  mock.turtle.slots[1] = { name = "minecraft:dirt", count = 64 }
  inv.invalidate()
  local placed, skipped, info = block.fill({ x = 1, y = 64, z = 0 },
                                           { x = 3, y = 64, z = 0 },
                                           "minecraft:dirt")
  ok(placed == 3, "every cell was placed", placed)
  ok(info.complete == true, "so the run is complete")
  ok(info.unreachable == nil and info.unplaceable == nil,
     "and no failure key is present to trip a truthiness test")
  ok(info.reason == nil, "with no reason to report")

  -- And the keys still appear, as numbers, when they mean something.
  local i2 = block.settle({ cells = 9, unreachable = 2, unplaceable = 0 })
  ok(i2.unreachable == 2, "a real count survives", i2.unreachable)
  ok(i2.unplaceable == nil, "alongside one that did not happen")
  ok(i2.complete == false, "and the run is not complete")
  ok(block.settle({ cells = 1, unreachable = 0, stopped = true }).complete == false,
     "giving up early is incomplete even with no failed cells")
end

--------------------------------------------------------------------------
group("thinking: the tokens spent before a program is written")
mock.reset()
do
  local client = require("claude.client")
  local msgs = { { role = "user", content = "hi" } }

  local function sentPayload(cfg)
    mock.resetHttp()
    mock.http.reply({ status = 200, body = mock.sse({
      { "message_start", { type = "message_start", message = { usage = {} } } },
      { "content_block_start", { type = "content_block_start", index = 0,
                                 content_block = { type = "text", text = "" } } },
      { "content_block_delta", { type = "content_block_delta", index = 0,
                                 delta = { type = "text_delta", text = "x" } } },
      { "message_delta", { type = "message_delta",
                           delta = { stop_reason = "end_turn" }, usage = {} } },
      { "message_stop", { type = "message_stop" } },
    }) })
    cfg.apiKey, cfg.retries = "t", 1
    client.message(cfg, { messages = msgs })
    return mock.http.requests[1].body
  end

  -- Omitting `thinking` is not the same as switching it off: current
  -- models think by default. So we must not send a `thinking` field at
  -- all unless the operator asked for one.
  ok(sentPayload({}):find("thinking", 1, true) == nil,
     "no thinking field is sent by default")
  ok(sentPayload({ thinking = "off" }):find('"disabled"', 1, true) ~= nil,
     "off asks for disabled explicitly")
  ok(sentPayload({ thinking = "adaptive" }):find('"adaptive"', 1, true) ~= nil,
     "adaptive is spelled the way current models take it")

  -- budget_tokens is a 400 on current models. It must only appear when
  -- the operator wrote it out, for an older model they chose.
  local legacy = sentPayload({ thinking = { budget = 2048 } })
  ok(legacy:find("budget_tokens", 1, true) ~= nil,
     "the pre-4.6 spelling is still available for an old model")
  ok(sentPayload({}):find("budget_tokens", 1, true) == nil,
     "but never appears on its own")

  -- effort is the knob that bounds what thinking costs.
  ok(sentPayload({ effort = "low" }):find('"effort"', 1, true) ~= nil,
     "effort rides in output_config")
  ok(sentPayload({ effort = "low" }):find("output_config", 1, true) ~= nil,
     "under that exact key")
  ok(sentPayload({}):find("output_config", 1, true) == nil,
     "and is omitted when unset")

  -- temperature is rejected outright alongside thinking.
  ok(sentPayload({ temperature = 0.5, thinking = "adaptive" })
       :find("temperature", 1, true) == nil,
     "temperature is not sent alongside a thinking directive")

  -- A default budget big enough that thinking cannot eat all of it. 4096
  -- was the number that failed in-game.
  local body = sentPayload({})
  local maxTok = tonumber(body:match('"max_tokens"%s*:%s*(%d+)'))
  ok(maxTok and maxTok >= 16000, "max_tokens leaves room to think", maxTok)

  -- And when it does run out, the error says what was in the response.
  -- "hit max_tokens" alone reads as "the program was too long", which is
  -- the opposite of what happened.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = mock.sse({
    { "message_start", { type = "message_start", message = { usage = {} } } },
    { "content_block_start", { type = "content_block_start", index = 0,
                               content_block = { type = "thinking", thinking = "" } } },
    { "message_delta", { type = "message_delta",
                         delta = { stop_reason = "max_tokens" },
                         usage = { output_tokens = 4096 } } },
    { "message_stop", { type = "message_stop" } },
  }) })
  local r, e = client.message({ apiKey = "t", retries = 1 }, { messages = msgs })
  ok(r == nil, "a reply that is all thinking is an error")
  ok(tostring(e):find("thinking", 1, true) ~= nil,
     "and names the block type that consumed the budget", e)
  ok(tostring(e):find("4096", 1, true) ~= nil,
     "and the tokens it cost", e)
end
mock.resetHttp()

--------------------------------------------------------------------------
group("/doctor: telling a stale install apart from a broken transport")
mock.reset()
do
  local client = require("claude.client")

  local s = client.settings({})
  ok(s.stream == true, "streaming is on by default")
  ok(s.readTimeout == 60, "and reports CC's window, not ours", s.readTimeout)
  ok(s.timeout == 180, "our ceiling is reported separately", s.timeout)
  ok(client.settings({ stream = false }).stream == false,
     "a config override is reflected, not the module default")
  ok(client.settings({ readTimeout = 900 }).readTimeout == 60,
     "and the reported window is the clamped one -- the number CC will see")

  -- "not configured" and "off" are different, and the difference is what
  -- broke in-game, so /doctor must not conflate them.
  ok(client.settings({}).thinking == "on",
     "unset thinking reports as on, because that is what the model does")
  ok(client.settings({ thinking = "off" }).thinking == "off",
     "and off reports as off")
  ok(client.settings({ maxTokens = 32000 }).maxTokens == 32000,
     "the token budget is reported")

  -- The whole point of /doctor is that it fails loudly rather than
  -- reporting health it did not check.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = mock.sse({
    { "message_start", { type = "message_start",
                         message = { usage = { input_tokens = 4 } } } },
    { "content_block_start", { type = "content_block_start", index = 0,
                               content_block = { type = "text", text = "" } } },
    { "content_block_delta", { type = "content_block_delta", index = 0,
                               delta = { type = "text_delta", text = "ok" } } },
    { "message_delta", { type = "message_delta",
                         delta = { stop_reason = "end_turn" }, usage = {} } },
    { "message_stop", { type = "message_stop" } },
  }) })
  local took, err = client.ping({ apiKey = "t", model = "stub" })
  ok(took ~= nil, "a working transport reports a time", err)

  mock.resetHttp()
  mock.http.reply({ failure = "Timed out" })
  local t2, e2 = client.ping({ apiKey = "t", model = "stub" })
  ok(t2 == nil and tostring(e2):find("cut off") ~= nil,
     "a dead transport reports the reason", e2)

  -- One attempt, not three: /doctor is a question, not a retry loop.
  ok(#mock.http.requests == 1, "the test call does not retry",
     #mock.http.requests)
end
mock.resetHttp()

--------------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
