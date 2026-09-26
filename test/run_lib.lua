--[[ test/run_lib.lua ---------------------------------------------------
  The saved-routine subsystem: contracts, lint, registration gating, and
  the nesting hazards.

      lua5.3 test/run_lib.lua
--------------------------------------------------------------------------]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local mock = require("test.mock")
mock.install()

local pass, fail = 0, 0
local function ok(cond, label, detail)
  if cond then pass = pass + 1; print("  ok   " .. label)
  else fail = fail + 1; print("  FAIL " .. label ..
       (detail and ("  -- " .. tostring(detail)) or "")) end
end
local function group(name) print("\n" .. name) end

local util     = require("agent.util")
local geom     = require("agent.geom")
local state    = require("agent.state")
local caps     = require("agent.caps")
local world    = require("agent.world")
local nav      = require("agent.nav")
local inv      = require("agent.inv")
local block    = require("agent.block")
local job      = require("agent.job")
local contract = require("agent.contract")
local lint     = require("agent.lint")
local lib      = require("agent.lib")
local agent    = require("agent.init")
local executor = require("claude.executor")

local function fresh()
  mock.reset()
  state.clear(); world.clear(); inv.invalidate()
  lib.invalidate()
  caps.detect(true)
  nav.localFrame(geom.v(0, 64, 0), geom.NORTH)
  nav.refuelHook = function(t) inv.refuel(t) end
  if fs.exists("/ccagent/jobs/index.json") then fs.delete("/ccagent/jobs/index.json") end
end

--------------------------------------------------------------------------
group("contract parsing")
fresh()

local GOOD = [[
--[==[ @ccagent
name:    stack
doc:     stack cobble in a column above the caller
frame:   relative
args:    height:number=3, spec:string=minecraft:cobblestone
needs:   caps=digging, item=minecraft:cobblestone, fuel=height*2
returns: number of blocks placed
]==]
local placed = 0
for i = 1, args.height do
  job.checkAbort()
  if nav.step("up") and block.place("down", args.spec) then placed = placed + 1 end
end
job.report(placed)
]]

do
  local c, err = contract.parse(GOOD)
  ok(c ~= nil, "parses a well-formed header", err)
  if c then
    ok(c.name == "stack" and c.frame == "relative", "name and frame")
    ok(#c.args == 2, "two args parsed", #c.args)
    ok(c.args[1].name == "height" and c.args[1].type == "number"
       and c.args[1].default == 3, "typed arg with a numeric default")
    ok(c.args[1].required == false, "a default makes an arg optional")
    ok(c.needs.caps[1] == "digging", "caps requirement")
    ok(c.needs.items[1] == "minecraft:cobblestone", "item requirement")
    ok(c.needs.fuel == "height*2", "fuel expression kept verbatim")
    ok(contract.signature(c):find("height%?") ~= nil, "signature marks optionals",
       contract.signature(c))
  end
end

do
  local _, err = contract.parse("local x = 1")
  ok(err == "no @ccagent header", "source without a header", err)

  local _, e2 = contract.parse("--[[ @ccagent\ndoc: x\nframe: relative\n]]")
  ok(e2 and e2:find("name"), "missing name is rejected", e2)

  local _, e3 = contract.parse("--[[ @ccagent\nname: a\ndoc: d\nframe: sideways\n]]")
  ok(e3 and e3:find("frame"), "unknown frame is rejected", e3)

  local long = "--[[ @ccagent\nname: a\ndoc: " .. string.rep("x", 200)
               .. "\nframe: anywhere\n]]"
  local _, e4 = contract.parse(long)
  ok(e4 and e4:find("doc is"), "an over-long doc is rejected (it rides in every prompt)", e4)
end

group("argument binding")
do
  local c = contract.parse(GOOD)
  local a, err = contract.bindArgs(c, {})
  ok(a and a.height == 3, "defaults fill in", err)
  local b = contract.bindArgs(c, { height = "7" })
  ok(b and b.height == 7 and type(b.height) == "number", "numeric coercion")
  local cc = contract.parse([==[--[[ @ccagent
name: n
doc: d
frame: anywhere
args: target:pos
]]]==])
  local _, e = contract.bindArgs(cc, {})
  ok(e and e:find("missing required"), "required arg enforced", e)
  local _, e2 = contract.bindArgs(cc, { target = 5 })
  ok(e2 and e2:find("position"), "pos type enforced", e2)
end

--------------------------------------------------------------------------
group("lint: stripping comes first")
do
  -- A direction word inside a string must not read as a movement call, and
  -- a coordinate inside a comment must not read as a hardcoded location.
  local src = [[
job.say("go forward and then left")
-- move to {x=100,y=64,z=-300} eventually
nav.step("north")
]]
  local findings = lint.check(src, lib.allowedNames())
  ok(lint.has(findings, "relative-facing") == nil,
     "prose in job.say is not a direction word")
  ok(lint.has(findings, "absolute-coords") == nil,
     "coordinates in a comment are not hardcoded coordinates")
end

group("lint: the checks that matter")
do
  local anchored = [[
local p = nav.pos()
block.clear(p, geom.add(p, {x=4, y=-16, z=4}))
]]
  local f = lint.check(anchored, lib.allowedNames())
  ok(lint.has(f, "ambient-anchor") ~= nil, "ambient anchoring is detected")
  ok(lint.has(f, "absolute-coords") == nil,
     "a relative offset is not a world coordinate")

  local absolute = [[
nav.moveTo({x=120, y=64, z=-300})
block.dig("down")
]]
  local f2 = lint.check(absolute, lib.allowedNames())
  ok(lint.has(f2, "absolute-coords") ~= nil, "world coordinates detected")

  local facing = [[ nav.step("forward") ]]
  local f3 = lint.check(facing, lib.allowedNames())
  ok(lint.has(f3, "relative-facing") ~= nil, "facing-relative word detected")

  local calls = [[ lib.run("restock", {n=4}) ]]
  local f4 = lint.check(calls, lib.allowedNames())
  local c4 = lint.has(f4, "calls-library")
  ok(c4 and c4.detail == "restock", "library call recorded by name",
     c4 and c4.detail)

  local undef = [[ local x = helper.waitFor(function() return true end)
                   frobnicate(x) ]]
  local f5 = lint.check(undef, lib.allowedNames())
  local u = lint.has(f5, "undefined-global")
  ok(u and u.detail:find("frobnicate"), "undefined global detected", u and u.detail)
  ok(not lint.report(f5):find("helper"), "a real sandbox name is not flagged")

  -- Legitimate nav.pos() uses must not trip the anchor check.
  local legit = [[
nav.moveTo(args.origin)
local here = nav.pos()
job.report({ back = geom.eq(here, args.origin) })
]]
  local f6 = lint.check(legit, lib.allowedNames())
  ok(lint.has(f6, "ambient-anchor") == nil,
     "a drift check reads position without anchoring to it")
end

group("lint: declaration vs source")
do
  local anchored = lint.check([[
local p = nav.pos()
block.clear(p, geom.add(p, {x=4, y=-4, z=4}))
]], lib.allowedNames())

  local e1 = lint.consistency({ frame = "anywhere" }, anchored)
  ok(#e1 > 0 and e1[1]:find("anywhere"), "anywhere + anchor is rejected", e1[1])

  local e2 = lint.consistency({ frame = "absolute" }, anchored)
  ok(#e2 > 0, "absolute + anchor is rejected", e2[1])

  -- Anchoring to nav.pos() in a relative routine is CORRECT behaviour, not
  -- an error: called from a new position it does the relative thing there.
  -- What it costs is targetability, which is a warning, not a refusal.
  local e3, w3 = lint.consistency({ frame = "relative" }, anchored)
  ok(#e3 == 0, "relative + anchor is allowed -- it is the correct reading",
     e3[1])
  ok(#w3 > 0 and w3[1]:find("cannot aim"),
     "but warns that callers cannot target it", w3[1])

  local clean = lint.check([[
nav.moveTo(args.origin)
job.report(1)
]], lib.allowedNames())
  local e4, w4 = lint.consistency({ frame = "relative" }, clean)
  ok(#e4 == 0, "a correctly anchored routine passes", e4[1])
end

--------------------------------------------------------------------------
group("registration gating")
fresh()
do
  lib.save("stack", GOOD)
  local res = require("ui.jobs").register("stack")
  ok(res.ok, "a consistent routine registers",
     res.errors and res.errors[1])
  ok(lib.has("stack"), "and is callable")
  ok(lib.state("stack").listed == true, "and listed by default")

  -- The landmine: a header that lies about its frame.
  local LIAR = [[
--[==[ @ccagent
name:  liar
doc:   claims to be position-independent
frame: anywhere
]==]
local p = nav.pos()
block.clear(p, geom.add(p, {x=2, y=-2, z=2}))
]]
  lib.save("liar", LIAR)
  local res2 = require("ui.jobs").register("liar")
  ok(not res2.ok, "a header contradicting the source is refused")
  ok(not lib.has("liar"), "and it is not callable")
  ok(lib.source("liar") ~= nil, "but the program is still saved")

  -- No header at all: the signal to offer a retrofit, not a bare failure.
  lib.save("oneoff", "job.report(1)")
  local res3 = require("ui.jobs").register("oneoff")
  ok(not res3.ok and res3.needsRetrofit,
     "a headerless program reports needsRetrofit")

  -- Name mismatch.
  lib.save("othername", GOOD)
  local res4 = require("ui.jobs").register("othername")
  ok(not res4.ok and res4.errors[1]:find("saved as"),
     "header name must match the save name", res4.errors[1])
end

group("three states")
fresh()
do
  lib.save("stack", GOOD)
  lib.register("stack")
  ok(lib.manifest():find("lib.run%('stack'"), "listed routines reach the prompt")

  lib.expose("stack", false)
  lib.invalidate()
  ok(lib.manifest() == nil, "unlisted routines leave the prompt")
  ok(lib.has("stack"), "but stay callable")

  lib.expose("stack", true)
  lib.invalidate()
  lib.unregister("stack")
  lib.invalidate()
  ok(not lib.has("stack"), "unregister revokes callability")
  ok(lib.source("stack") ~= nil, "and still leaves the source on disk")
end

group("listing version drives re-caching")
fresh()
do
  local v0 = lib.listingVersion()
  lib.save("stack", GOOD); lib.register("stack"); lib.invalidate()
  local v1 = lib.listingVersion()
  ok(v0 ~= v1, "registering moves the fingerprint")
  lib.invalidate()
  ok(lib.listingVersion() == v1, "and it is stable across reloads")
  lib.expose("stack", false); lib.invalidate()
  ok(lib.listingVersion() ~= v1, "exposing moves it too")
end

--------------------------------------------------------------------------
group("calling a routine")
fresh()
do
  mock.turtle.slots[1] = { name = "minecraft:cobblestone", count = 64 }
  inv.invalidate()
  lib.save("stack", GOOD)
  local res = require("ui.jobs").register("stack")
  ok(res.ok, "registered", res.errors and res.errors[1])

  local r = executor.run([[
    local n = lib.run("stack", { height = 3 })
    job.report({ placed = n })
  ]], agent.env(), {})
  ok(r.ok, "caller ran", r.error)
  ok(r.result and r.result.placed == 3, "routine's report reached the caller",
     r.result and r.result.placed)
  ok(nav.pos().y == 67, "the turtle really moved", geom.tostring(nav.pos()))
end

group("needs are checked before the first instruction")
fresh()
do
  lib.save("stack", GOOD); lib.register("stack")
  -- No cobblestone in the inventory this time.
  local before = geom.copy(nav.pos())
  local r = executor.run([[ lib.run("stack", { height = 3 }) ]], agent.env(), {})
  ok(not r.ok, "the call failed")
  ok(tostring(r.error):find("needs minecraft:cobblestone"),
     "and said exactly what was missing", r.error)
  ok(geom.eq(nav.pos(), before),
     "the turtle did not move before failing -- this is the whole point")
end

group("unregistered and unknown routines")
fresh()
do
  lib.save("stack", GOOD)   -- saved, not registered
  local r = executor.run([[ lib.run("stack") ]], agent.env(), {})
  ok(not r.ok and tostring(r.error):find("not registered"),
     "a saved-but-unregistered routine refuses to run", r.error)

  local r2 = executor.run([[ lib.run("nope") ]], agent.env(), {})
  ok(not r2.ok and tostring(r2.error):find("no saved routine"),
     "an unknown name fails readably", r2.error)
end

--------------------------------------------------------------------------
group("nesting: the distributed cycle")
fresh()
do
  -- No single program contains the loop: a -> b -> c -> a.
  local function routine(name, callee)
    return ("--[==[ @ccagent\nname: %s\ndoc: link in a chain\nframe: anywhere\n]==]\n%s\njob.report('%s')\n")
      :format(name, callee and ("lib.run('" .. callee .. "')") or "", name)
  end
  lib.save("a", routine("a", "b")); lib.register("a")
  lib.save("b", routine("b", "c")); lib.register("b")
  lib.save("c", routine("c", "a")); lib.register("c")

  local r = executor.run([[ lib.run("a") ]], agent.env(), {})
  ok(not r.ok, "the cycle is refused")
  ok(tostring(r.error):find("cycle"), "and named as a cycle", r.error)
  ok(tostring(r.error):find("a %-> b %-> c %-> a"),
     "and prints the whole chain, which no single file shows", r.error)
end

group("nesting: depth cap")
fresh()
do
  -- A chain with no cycle, longer than the cap.
  for i = 1, 8 do
    local callee = (i < 8) and ("d" .. (i + 1)) or nil
    lib.save("d" .. i, ("--[==[ @ccagent\nname: d%d\ndoc: chain link\nframe: anywhere\n]==]\n%s\n")
      :format(i, callee and ("lib.run('" .. callee .. "')") or "job.report('end')"))
    lib.register("d" .. i)
  end
  local r = executor.run([[ lib.run("d1") ]], agent.env(), {})
  ok(not r.ok and tostring(r.error):find("too deep"),
     "nesting is capped", r.error)
end

group("nesting: state isolation")
fresh()
do
  lib.save("inner", [[
--[==[ @ccagent
name:  inner
doc:   reports its own value and writes a checkpoint
frame: anywhere
]==]
job.checkpoint("mark", "inner-value")
job.report("INNER")
]])
  lib.register("inner")

  local r = executor.run([[
    job.checkpoint("mark", "outer-value")
    job.report("OUTER")
    local got = lib.run("inner")
    job.report({ outerStillMine = job.recall("mark"), innerReturned = got })
  ]], agent.env(), {})

  ok(r.ok, "ran", r.error)
  ok(r.result and r.result.innerReturned == "INNER",
     "the nested report is returned to the caller, not lost",
     r.result and r.result.innerReturned)
  ok(r.result and r.result.outerStillMine == "outer-value",
     "the nested checkpoint did not collide with the caller's",
     r.result and r.result.outerStillMine)
end

group("nesting: module flags restored")
fresh()
do
  lib.save("flipper", [[
--[==[ @ccagent
name:  flipper
doc:   deliberately leaves a module flag flipped
frame: anywhere
]==]
block.restoreFacing = false
nav.policy.dig = false
error("boom")
]])
  lib.register("flipper")

  local savedFacing = block.restoreFacing
  local savedDig = nav.policy.dig
  local r = executor.run([[ pcall(function() lib.run("flipper") end) ]],
                         agent.env(), {})
  ok(r.ok, "the caller survived the routine's error", r.error)
  ok(block.restoreFacing == savedFacing,
     "block.restoreFacing was restored even though the routine threw")
  ok(nav.policy.dig == savedDig,
     "nav.policy was restored even though the routine threw")
end

group("nesting: a routine's globals do not leak")
fresh()
do
  lib.save("leaky", [[
--[==[ @ccagent
name:  leaky
doc:   assigns a global
frame: anywhere
]==]
sneaky = "from inside"
job.report(1)
]])
  lib.register("leaky")
  local r = executor.run([[
    lib.run("leaky")
    job.report({ leaked = sneaky })
  ]], agent.env(), {})
  ok(r.ok, "ran", r.error)
  ok(r.result and r.result.leaked == nil,
     "a global set inside a routine stays inside it",
     r.result and r.result.leaked)
end

group("nesting: abort survives a routine's own pcall")
fresh()
do
  lib.save("swallower", [[
--[==[ @ccagent
name:  swallower
doc:   wraps its work in pcall, as a careless program might
frame: anywhere
]==]
pcall(function()
  for i = 1, 100 do job.checkAbort() end
end)
job.report("finished anyway")
]])
  lib.register("swallower")

  local r = executor.run([[
    job.checkAbort()
    lib.run("swallower")
    job.report("outer finished")
  ]], agent.env(), {
    onOutput = function() end,
  })
  -- Not aborted yet: baseline should succeed.
  ok(r.ok, "baseline runs when no abort is pending", r.error)

  -- Now abort mid-flight: the routine's pcall eats the sentinel, but the
  -- lib.run boundary re-checks on the way out.
  job.abortFlag = false
  local env = agent.env()
  local caught = executor.run([[
    job.abortFlag = true
    lib.run("swallower")
    job.report("outer finished")
  ]], env, {})
  ok(caught.aborted, "the stop request was not swallowed", caught.error)
  ok(caught.result ~= "outer finished",
     "and the caller did not carry on past it")
end

--------------------------------------------------------------------------
group("deleting a saved program")
fresh()
do
  local function listed(name)
    for _, n in ipairs(lib.names()) do if n == name then return true end end
    return false
  end

  lib.save("doomed", "job.report(1)")
  ok(lib.source("doomed") ~= nil, "saved")
  ok(listed("doomed"), "and listed")
  ok(lib.delete("doomed"), "deleted")
  ok(lib.source("doomed") == nil, "the source is gone")
  ok(not listed("doomed"), "and so is the listing")
  ok(not lib.delete("doomed"), "deleting it again says so, rather than lying")
  ok(not lib.delete("never-existed"), "as does deleting a typo")

  -- Registration lives in the same index entry, so deleting has to take
  -- it with them: a routine Claude can still call but whose source is
  -- gone is worse than either.
  lib.save("promoted", [[
--[==[ @ccagent
name:  promoted
doc:   does a thing
frame: anywhere
]==]
job.report("ok")
]])
  ok(lib.register("promoted"), "registered")
  ok(lib.has("promoted"), "and callable by Claude")
  lib.delete("promoted")
  ok(not lib.has("promoted"), "deleting it unregisters it too")
  local manifest = lib.manifest()
  ok(manifest == nil or manifest:find("promoted", 1, true) == nil,
     "and it leaves the manifest Claude is shown", manifest)
end

group("prompt integration")
fresh()
do
  local prompt = require("claude.prompt")
  local session = require("claude.session")

  lib.save("stack", GOOD); lib.register("stack"); lib.invalidate()

  local _, text = prompt.system({})
  ok(text:find("SAVED ROUTINES") ~= nil, "the library index is in the prompt")
  ok(text:find("lib%.run%('stack'") ~= nil, "with the routine's signature")
  ok(text:find("REUSABLE ROUTINES") ~= nil, "contract instructions are present")
  ok(text:find("frame: relative") ~= nil or text:find("relative   operates") ~= nil,
     "frame semantics are explained")

  -- The index must be in the cached prefix, not the live state block.
  local situation = prompt.situation(agent)
  ok(situation:find("lib%.run") == nil,
     "the index is NOT in the per-request state line")

  -- Registering something rebuilds the prefix exactly once.
  local sess = session.new({ apiKey = "x", model = "m" }, agent)
  local s1 = sess:buildSystem()
  local s2 = sess:buildSystem()
  ok(s1 == s2, "the prefix is stable when nothing changed")
  lib.save("other", (GOOD:gsub("name:    stack", "name:    other")))
  lib.register("other"); lib.invalidate()
  local s3 = sess:buildSystem()
  ok(s3 ~= s1, "registering rebuilds it")
  local s4 = sess:buildSystem()
  ok(s4 == s3, "and it is stable again afterwards")
end

group("the reusable flag reaches the model")
fresh()
do
  local client  = require("claude.client")
  local session = require("claude.session")
  local sent = {}
  local real = client.message
  client.message = function(cfg, body)
    sent[#sent + 1] = body.messages[#body.messages].content
    return { text = "```lua\njob.report(1)\n```", usage = {}, blocks = {} }
  end
  local sess = session.new({ apiKey = "x", model = "m" }, agent)
  sess:handle("dig a hole", { onEvent = function() end })
  ok(not sent[1]:find("REUSABLE"), "a plain request carries no reusable flag")
  sess:handle("dig a hole", { onEvent = function() end, reusable = true })
  ok(sent[2]:find("THIS ONE SHOULD BE REUSABLE") ~= nil,
     "a + request does")
  client.message = real
end

--------------------------------------------------------------------------
group("retrofit: promoting a one-off, with a stubbed API")
fresh()
do
  local client  = require("claude.client")
  local session = require("claude.session")
  local jobs    = require("ui.jobs")

  -- A program written as a one-off: anchors to nav.pos(), no header.
  local ONEOFF = [[
local p = nav.pos()
block.clear(p, geom.add(p, {x=4, y=-8, z=4}))
job.report("done")
]]
  lib.save("pit", ONEOFF, "dig a pit in front of me")

  local res = jobs.register("pit")
  ok(not res.ok and res.needsRetrofit, "a one-off cannot register as-is")
  ok(lint.has(res.findings, "ambient-anchor") ~= nil,
     "and the findings name the reason")

  local seen
  local real = client.message
  client.message = function(cfg, body)
    seen = body.messages[#body.messages].content
    return { text = [[Here:
```lua
--[==[ @ccagent
name:  pit
doc:   excavate a pit below and around the caller
frame: relative
args:  size:number=4, depth:number=8
needs: caps=digging
]==]
block.clear(args.origin, geom.add(args.origin,
  {x=args.size, y=-args.depth, z=args.size}))
job.report("done")
```]], usage = {}, blocks = {} }
  end

  local sess = session.new({ apiKey = "x", model = "m" }, agent)
  local newSrc, err = sess:retrofit("pit", ONEOFF,
                                    lint.report(res.findings), "dig a pit")
  client.message = real

  ok(newSrc ~= nil, "retrofit returned a program", err)
  ok(seen and seen:find("ambient%-anchor"),
     "the lint findings were sent, so the model works from facts not guesses")
  ok(seen and seen:find("Promote this saved program"), "and the framing is right")

  if newSrc then
    lib.save("pit", newSrc)
    lib.invalidate()
    local res2 = jobs.register("pit")
    ok(res2.ok, "the promoted version registers",
       res2.errors and res2.errors[1])
    ok(lib.has("pit"), "and is callable")
    local c = lib.contract("pit")
    ok(c and c.frame == "relative", "as a relative routine")
    ok(c and #c.args == 2, "with parameters where the hardcoding was",
       c and #c.args)
  end
end

group("coordinate frames: the failure that is actually silent")
fresh()
do
  -- A routine built on fixed coordinates, registered under one local frame.
  lib.save("gochest", [[
--[==[ @ccagent
name:  gochest
doc:   go to the storage chest
frame: absolute
]==]
nav.moveTo({x=20, y=64, z=-30})
job.report("there")
]])
  local res = require("ui.jobs").register("gochest")
  ok(res.ok, "an absolute routine registers", res.errors and res.errors[1])
  local authored = lib.state("gochest").frameId
  ok(authored ~= nil and authored:find("local:"),
     "and records the coordinate frame it was written in", authored)

  -- Same frame: it runs.
  local r = executor.run([[ lib.run("gochest") ]], agent.env(), {})
  ok(r.ok, "runs under the frame it was registered in", r.error)

  -- The turtle is re-placed and boots a new local frame. The literals in
  -- the routine now point somewhere else entirely, and nothing about the
  -- code changed -- this is the case that would otherwise fail in silence.
  nav.localFrame(geom.v(0, 64, 0), geom.NORTH)
  state.set("frameId", "local:test:second-frame")
  lib.invalidate()
  local r2 = executor.run([[ lib.run("gochest") ]], agent.env(), {})
  ok(not r2.ok, "refuses under a different local frame")
  ok(tostring(r2.error):find("coordinate frame"),
     "and says why in terms the repair loop can act on", r2.error)

  -- A relative routine is immune, because it never referred to the frame.
  lib.save("rel", [[
--[==[ @ccagent
name:  rel
doc:   step once from the caller's position
frame: relative
]==]
job.report(args.origin ~= nil)
]])
  require("ui.jobs").register("rel")
  state.set("frameId", "local:test:third-frame")
  lib.invalidate()
  local r3 = executor.run([[ job.report(lib.run("rel")) ]], agent.env(), {})
  ok(r3.ok and r3.result == true,
     "a relative routine is unaffected by a frame change", r3.error)
end

group("re-saving revokes a stale registration")
fresh()
do
  lib.save("stack", GOOD)
  lib.register("stack")
  ok(lib.has("stack"), "registered")
  -- The source changes; the old validation no longer describes it.
  lib.save("stack", GOOD .. "\n-- edited\n")
  lib.invalidate()
  ok(not lib.has("stack"),
     "editing the source revokes registration until it is re-checked")
  lib.register("stack"); lib.invalidate()
  ok(lib.state("stack").listed == true,
     "and re-registering restores the listing preference")
end

--------------------------------------------------------------------------
group("revise: a saved program against an API that moved")
do
  local client  = require("claude.client")
  local session = require("claude.session")
  local prompt  = require("claude.prompt")

  local old = "-- v1\nturtle.placeDown()\n"
  local sent
  local real = client.message
  client.message = function(cfg, body)
    sent = body.messages[#body.messages].content
    return { text = "```lua\nblock.till('down')\n```",
             usage = {}, stop = "end_turn", blocks = {} }
  end

  local sess = session.new({ apiKey = "t", model = "stub" }, nil)
  local newSrc, err = sess:revise("setWheatFarm", old, "tilling does nothing")
  ok(newSrc and newSrc:find("block.till", 1, true) ~= nil,
     "a revision comes back as code", err)

  -- The request has to carry the source, or the model is guessing.
  ok(sent:find("turtle.placeDown", 1, true) ~= nil,
     "the old source is sent for revision")
  ok(sent:find("tilling does nothing", 1, true) ~= nil,
     "along with what the operator said is wrong")
  ok(sent:find("setWheatFarm", 1, true) ~= nil, "and which job it is")

  -- The API listing is what makes this work, and it lives in the cached
  -- system prompt rather than being re-sent per revision.
  ok(sent:find("CURRENT STATE", 1, true) == nil,
     "live turtle state is not sent -- a revision is about source, not pose")

  local bare = prompt.revise("j", "x = 1", nil, nil)
  ok(bare:find("x = 1", 1, true) ~= nil, "a revision with no note still works")
  ok(bare:find("unchanged", 1, true) ~= nil,
     "and tells the model it may decline to change anything")

  client.message = real
end

--------------------------------------------------------------------------
group("the fuel trap is documented where the call is chosen")
do
  local registry = require("agent.registry")
  local manifest = registry.manifest()

  -- The rule lived only in the prompt's list of principles, where it lost
  -- to a state line reading "fuel 0". It belongs next to the signature
  -- the model reads when it reaches for the call -- and that doc string
  -- is in the cached prefix, so it costs nothing per request.
  local fuelLine
  for line in manifest:gmatch("[^\n]+") do
    if line:find("fuel", 1, true) and line:find("->", 1, true)
       and not line:find("ensureFuel", 1, true)
       and not line:find("fuelSlots", 1, true) then
      fuelLine = fuelLine or line
    end
  end
  -- Match identifiers, not sentences. Rewording the guidance should not
  -- fail the suite; deleting it should. An earlier version of this group
  -- asserted an exact English sentence was present and an older one
  -- absent -- which pinned punctuation forever and still would not have
  -- caught contradictory guidance added in different words.
  ok(fuelLine ~= nil, "nav.fuel is listed", manifest:sub(1, 80))
  ok(fuelLine and fuelLine:find("refuel", 1, true) ~= nil,
     "and its doc sends the reader to refuelling rather than leaving the "
     .. "number bare", fuelLine)

  -- Against prompt.RULES, not the assembled system block: the manifest
  -- is part of that block and lists nav.fuel and nav.ensureFuel as
  -- signatures, so searching the whole thing matched the API listing and
  -- passed happily with the guidance deleted.
  local prompt = require("claude.prompt")
  ok(prompt.RULES:find("nav.fuel", 1, true) ~= nil,
     "the rules name the accessor that misleads")
  ok(prompt.RULES:find("moveTo", 1, true) ~= nil,
     "and what already handles it -- losing either means the rule went "
     .. "missing, whatever the wording")
end

--------------------------------------------------------------------------
group("config: a file kept across updates pins values the code moved past")
do
  local config = require("claude.config")

  -- The exact shape that cost a run: an install from before thinking was
  -- on by default keeps maxTokens = 4096, every update preserves it, and
  -- the failure arrives much later looking nothing like a config problem.
  local w = config.warnings({ maxTokens = 4096 })
  ok(#w > 0, "a low token budget is called out")
  ok(table.concat(w, " "):find("4096", 1, true) ~= nil,
     "naming the value actually in force", w[1])
  ok(table.concat(w, " "):find("/ccagent/config.lua", 1, true) ~= nil,
     "and the file to edit -- the number alone is not actionable")

  ok(#config.warnings({ maxTokens = 32000 }) == 0,
     "the current default says nothing")
  ok(#config.warnings({ maxTokens = 4096, thinking = "off" }) == 0,
     "and neither does a small budget with thinking off, which is a "
     .. "coherent choice rather than a stale file")
  ok(#config.warnings({}) == 0, "an unset budget is not guessed at")

  -- Every warning has to fit a turtle screen or it scrolls its own
  -- explanation away.
  for _, line in ipairs(config.warnings({ maxTokens = 4096 })) do
    ok(#line <= 37, "warning fits the screen with its prefix", line)
  end
end

--------------------------------------------------------------------------
group("share: getting a failure off a screen with no scrollback")
do
  local share = require("ui.share")

  local text = share.bundle({
    version = "1.2.0", situation = "at 0,64,0",
    request = "build a wall", code = "job.report(1)",
    result = { ok = false, error = "boom", output = "line one" },
  })
  -- The point is that everything needed to tell two explanations apart
  -- survives in one place, since none of it survives on the screen.
  for _, want in ipairs({ "1.2.0", "at 0,64,0", "build a wall",
                          "job.report(1)", "boom", "line one" }) do
    ok(text:find(want, 1, true) ~= nil, "bundle carries " .. want)
  end

  -- Missing pieces are omitted, not rendered as "nil".
  local sparse = share.bundle({ version = "1.2.0" })
  ok(sparse:find("nil", 1, true) == nil, "an empty bundle prints no nils",
     sparse)
  ok(#sparse > 0, "and is still something")

  -- Whatever else changes, the key must never leave the turtle.
  ok(share.carriesSecret("x sk-ant-secret y", "sk-ant-secret"),
     "a key in the text is detected")
  ok(not share.carriesSecret(text, "sk-ant-secret"),
     "and a clean bundle passes")
  ok(not share.carriesSecret(text, ""), "an unset key is not a match for "
     .. "everything -- that would block every report")

  -- Posting. The sink is described in config, never named in code, so
  -- swapping one for another is an edit to config.lua.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = "https://example.invalid/abc\n" })
  local where, err = share.send({ url = "https://sink.invalid" }, text)
  ok(where == "https://example.invalid/abc", "the sink's url is returned", err)
  ok(mock.http.requests[1].body:find("boom", 1, true) ~= nil,
     "and the bundle is what was sent")

  mock.resetHttp()
  ok(select(2, share.send({}, text)):find("no sink", 1, true) ~= nil,
     "an unconfigured sink is refused before any request")
  ok(#mock.http.requests == 0, "with nothing sent")

  mock.resetHttp()
  mock.http.reply({ status = 200, body = "   " })
  local w2, e2 = share.send({ url = "https://sink.invalid" }, text)
  ok(w2 == nil and tostring(e2):find("nothing", 1, true) ~= nil,
     "a sink that answers with nothing is an error, not a blank url", e2)

  -- The three shapes a sink answers in, none of them named here.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = "ignored",
                    headers = { Location = "https://example.invalid/h" } })
  ok(share.send({ url = "https://s.invalid", link = "header:location" }, text)
       == "https://example.invalid/h", "a link in a header is found")

  mock.resetHttp()
  mock.http.reply({ status = 200, body = '{"html_url":"https://example.invalid/j"}' })
  ok(share.send({ url = "https://s.invalid", link = "json:html_url" }, text)
       == "https://example.invalid/j", "a link in a JSON key is found")

  mock.resetHttp()
  mock.http.reply({ status = 200, body = "x" })
  local _, e3 = share.send({ url = "https://s.invalid", link = "json:nope" }, text)
  ok(tostring(e3):find("JSON", 1, true) ~= nil,
     "and a sink that does not answer that way says so", e3)

  -- A sink wanting a form field rather than a raw body.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = "https://example.invalid/f" })
  share.send({ url = "https://s.invalid", field = "file" }, text)
  local req = mock.http.requests[1]
  ok(req.headers["content-type"]:find("multipart/form-data", 1, true) ~= nil,
     "the content type says multipart", req.headers["content-type"])
  ok(req.body:find('name="file"', 1, true) ~= nil, "under the configured name")
  ok(req.body:find("boom", 1, true) ~= nil, "and the report is still in there")

  -- Whatever the sink wants for expiry or visibility rides in params,
  -- because no client can require retention it was not offered.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = "https://example.invalid/p" })
  share.send({ url = "https://s.invalid", params = { expires = "1d" } }, text)
  ok(mock.http.requests[1].url:find("expires=1d", 1, true) ~= nil,
     "params are appended", mock.http.requests[1].url)

  -- Redaction decides what leaves the turtle, which is the only control
  -- that works when retention is somebody else's setting.
  mock.resetHttp()
  mock.http.reply({ status = 200, body = "https://example.invalid/r" })
  share.send({ url = "https://s.invalid", redact = { "boom" } }, text)
  ok(mock.http.requests[1].body:find("boom", 1, true) == nil,
     "a redacted pattern does not leave")
  ok(mock.http.requests[1].body:find("redacted", 1, true) ~= nil,
     "and its absence is visible rather than silent")

  ok(share.redact("keep me", nil) == "keep me", "no rules changes nothing")
  local okPat = pcall(share.redact, "x", { "%(" })
  ok(okPat, "a malformed pattern warns rather than throwing")

  -- A default ships so the command works without configuring anything.
  local config = require("claude.config")
  local d = config.defaults.share
  ok(d and d.url and d.url ~= "", "a sink is configured out of the box", d and d.url)
  ok(d.link == "body", "with the link rule its answer actually uses")
  ok(d.params == nil,
     "and no expiry parameter, because that sink has none to accept")

  -- The merge is recursive, so `share = {}` in an operator's config keeps
  -- the default rather than clearing it. Turning /share off means saying
  -- so, and an empty url is what does it.
  local util = require("agent.util")
  local kept = util.merge(config.defaults, { share = {} })
  ok(kept.share.url == d.url,
     "an empty override does not disable the sink -- it merges", kept.share.url)
  local off = util.merge(config.defaults, { share = { url = "" } })
  ok(off.share.url == "", "an empty url is how it is turned off")
  ok(select(2, share.send(off.share, "x")):find("no sink", 1, true) ~= nil,
     "and send refuses when it is")

  -- Overriding one field keeps the rest, which is the point of merging.
  local mine = util.merge(config.defaults, { share = { url = "https://m.invalid" } })
  ok(mine.share.link == "body", "one field can be changed without the others")
end

--------------------------------------------------------------------------
group("revise: showing what changed, not the whole program")
do
  local util = require("agent.util")
  local before = "local a = 1\nturtle.placeDown()\nlocal c = 3\n"
  local after  = "local a = 1\nblock.till('down')\nlocal c = 3\n"
  local added, removed = util.lineDelta(before, after)
  ok(#added == 1 and added[1]:find("block.till", 1, true),
     "the new line is named", added[1])
  ok(#removed == 1 and removed[1]:find("placeDown", 1, true),
     "and so is the one it replaced", removed[1])

  -- Identical sources have nothing to show, which is how /revise knows to
  -- say "already current" instead of asking to replace like for like.
  local a2, r2 = util.lineDelta(before, before)
  ok(#a2 == 0 and #r2 == 0, "an unchanged program reports no delta")

  -- Blank lines are not a change worth a person's attention.
  local a3 = util.lineDelta("x = 1\n", "x = 1\n\n\n")
  ok(#a3 == 0, "added blank lines are not reported")

  -- A line that only moved did not change.
  local a4, r4 = util.lineDelta("a\nb\n", "b\na\n")
  ok(#a4 == 0 and #r4 == 0, "reordering is not an edit")
end

--------------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
