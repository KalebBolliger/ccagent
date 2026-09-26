# Extending ccagent

The platform has one extension point and it is deliberately small:
`registry.add`. Everything downstream — the sandbox environment Claude's code
runs in, the manifest Claude is shown, capability gating, the error message
when a machine lacks the upgrade — is generated from the same declarations, so
they cannot fall out of sync.

## The shape of a module

Create `agent/farm.lua`:

```lua
local util  = require("agent.util")
local nav   = require("agent.nav")
local block = require("agent.block")
local inv   = require("agent.inv")
local job   = require("agent.job")

local farm = {}

farm.crops = {
  ["minecraft:wheat"]    = { ripe = 7, seed = "minecraft:wheat_seeds" },
  ["minecraft:carrots"]  = { ripe = 7, seed = "minecraft:carrot" },
  ["minecraft:potatoes"] = { ripe = 7, seed = "minecraft:potato" },
  ["minecraft:beetroots"]= { ripe = 3, seed = "minecraft:beetroot_seeds" },
}

--- Is the block below a crop that is ready?
function farm.ripe(dir)
  local info = block.inspect(dir or "down")
  if not info then return false end
  local c = farm.crops[info.name]
  if not c then return false end
  local age = info.state and tonumber(info.state.age)
  return age ~= nil and age >= c.ripe, info
end

--- Harvest and replant a rectangle of farmland.
function farm.harvest(cornerA, cornerB)
  local geom = require("agent.geom")
  local picked = 0
  for cell in geom.iterBox(cornerA, cornerB) do
    job.checkAbort()
    local above = { x = cell.x, y = cell.y + 1, z = cell.z }
    if nav.moveTo(above) then
      local ready, info = farm.ripe("down")
      if ready then
        block.dig("down")
        picked = picked + 1
        local seed = farm.crops[info.name].seed
        if inv.has(seed) then block.place("down", seed) end
      end
    end
    job.progress(picked, nil, "harvested")
  end
  return picked
end

return farm
```

## Declaring it

Anywhere after `agent.init` has loaded — the bottom of `agent/init.lua`, or
your own file that the controller requires:

```lua
local registry = require("agent.registry")
local farm = require("agent.farm")

registry.add("farm", farm, "crop tending", {
  { fn = "ripe",    sig = "(dir?) -> bool, info",
    doc = "is the crop that way fully grown" },
  { fn = "harvest", sig = "(a, b) -> picked",
    doc = "harvest and replant every ripe crop in a box" },
})
```

That is the whole integration. `/manifest` now shows:

```
farm  -- crop tending
  farm.ripe(dir?) -> bool, info             -- is the crop that way fully grown
  farm.harvest(a, b) -> picked              -- harvest and replant every ripe crop in a box
```

and `farm` is in scope inside generated programs.

## Declaration fields

| field | |
|---|---|
| `fn` | function name, as reached through the namespace |
| `sig` | terse signature. `?` marks optional, `->` separates returns |
| `doc` | one line, imperative, no fluff. It is sent on every cached prompt |
| `requires` | a capability flag (or list) — hidden from machines that lack it |
| `tags` | strings, for building a reduced manifest with `registry.manifest{tags=…}` |
| `hidden` | callable but not advertised |

## Capability gating

If a function needs hardware, say so:

```lua
{ fn = "craft", sig = "(recipe, n?) -> ok, err", requires = "crafting" }
```

On a turtle without a crafting upgrade the entry is omitted from the manifest —
so no tokens are spent advertising it — and calling it anyway raises
`farm.craft needs 'crafting', which this machine does not have`, which is the
error you want in the repair loop rather than `attempt to call a nil value`.

Register a new flag with a non-destructive probe:

```lua
local caps = require("agent.caps")
caps.register("geoScanner", function()
  return peripheral.find("geoScanner") ~= nil
end)
```

`caps.summary()` picks it up and it appears in the state line Claude sees.

## What belongs in a module

Ask whether the model would otherwise write it from scratch on every request.
Good candidates share three traits:

- **Composable.** Takes a spec or a box, returns a count or a list. Not a
  hardcoded routine for one situation.
- **Expensive in tokens.** Vein mining is thirty lines of fiddly recursion;
  `block.digVein("*_ore")` is one.
- **Easy to get subtly wrong.** Anything involving turning and remembering
  that you turned, gravel, or bookkeeping across a failure.

Things that do *not* belong: one-off tasks (save those with `/save`), anything
that hardcodes your base's coordinates (use `/notes` for that), and thin
wrappers that only rename a `turtle` call.

## House rules

`/notes` — or `operatorNotes` in `config.lua` — appends free text to the system
prompt. It is the right place for facts about *your* world:

```
The base is at 120,64,-300; storage chests line its north wall.
Never dig above y=70 within 40 blocks of the base.
Fuel is in the barrel at 118,64,-298.
```

This re-caches the prompt once, then rides along free.

## Failures a caller has to be able to act on

`inv.craft` is the worked example: it can fail because the turtle is
carrying something that is not an ingredient, and only the caller can
decide whether to deposit it, drop it, or give up. So it returns
`ok, err, info` with `info.reason` and, for that case, `info.blocking`
listing `{slot, name, count}` for everything in the way.

The rule it follows is worth copying. When a capability can fail in a way
the caller might reasonably *fix*, hand back enough structure to fix it —
not a sentence. Prose is for the operator; a table is for the program.
And never resolve it by destroying something the operator owns: refusing
with the facts is always available, and a generated script aborting with
a clear report is a fine outcome.

## Shipping it

Add the file to `manifest.txt`. That is the list `install.lua` pulls onto a
computer or turtle, and it is the only one — a module that is not in it works
perfectly in the test suite and is simply absent on any machine installed over
the wire, which surfaces in-game as a `require` failure a long way from the
cause. `test/run_install.lua` fails if the manifest and the repo disagree, so
running the suite is enough to catch the omission.

## Adding a capability invalidates saved programs

Not mechanically — they keep running. That is the problem. A program saved
before `block.till` existed tills with `turtle.placeDown()`, which is still
legal Lua against a still-present API, and still does nothing. No lint can
see it: the raw call is only wrong *relative to a capability that did not
exist when the program was written*.

So when you add a capability that supersedes a raw `turtle.*` call people
would otherwise reach for, two things are part of the change, not
follow-ups:

1. Say so in `claude/prompt.lua`, naming the raw call and what it does
   instead. "Use `block.till`" is advice; "`turtle.place` puts down an
   inventory item and never uses the equipped tool, so it cannot till" is
   the thing that stops it being rediscovered the hard way.
2. Mention in `CHANGELOG.md` that existing saved programs want `/revise`.

`/revise <name> [note]` sends a saved program back with the current API
listing and replaces it with what comes back, after showing it. It is the
only repair path for this class of rot, because there is nothing to detect.

## Testing

`test/mock.lua` is a small voxel world with a turtle in it, plus enough of
`fs`, `textutils` and `os` to let state and the executor run. Add cases to
`test/run.lua` (core) or `test/run_lib.lua` (saved routines) and:

```
lua5.3 test/all.lua
```

It runs outside Minecraft in well under a second, and it catches exactly the
bugs that are worst to chase in-game: facing math, path replanning, inventory
matching, sandbox leaks.

---

# Two ways to add a capability

Everything above describes a **module**: Lua you write by hand, in `agent/`,
registered with `registry.add`. That is the right shape for anything that
needs the raw `turtle` API, new peripherals, or logic too fiddly to generate.

There is a second way, which costs no Lua at all: a **saved routine**. Ask for
something with a `+` prefix, and Claude writes it with a contract header; then
`/register` it and it becomes callable as `lib.run("name", {...})` from every
future program. See the README's "Saved routines" section for the operator
side. This section covers what the two share and where the line is.

## Which to use

| | module | routine |
|---|---|---|
| written in | hand-written Lua | generated, on request |
| lives in | `agent/*.lua` | `/ccagent/jobs/*.lua` |
| declared by | `registry.add` | `@ccagent` header |
| appears as | `farm.harvest(a, b)` | `lib.run('harvest', {...})` |
| can use | raw `turtle`, peripherals, `fs` | the sandbox only |
| good for | primitives, hardware, anything composable | procedures built from primitives |

The rule of thumb: if it needs something the sandbox does not expose, it is a
module. If it is a *composition* of things the sandbox already has, it is a
routine, and writing it by hand is work you do not need to do.

## The contract header

```lua
--[==[ @ccagent
name:    quarry
doc:     excavate a box downward from the caller's position
frame:   relative
args:    width:number=5, depth:number=16
needs:   caps=digging, item=*_pickaxe, fuel=width*width*depth
returns: number of blocks dug
]==]
```

| field | |
|---|---|
| `name` | must match the name it is saved under |
| `doc` | one line under 140 chars — it rides in every cached prompt |
| `frame` | `relative` \| `absolute` \| `anywhere`. Required |
| `args` | `name:type=default`, comma separated. Types: `number string boolean pos table any`. No default means required |
| `needs` | `caps=<flag>`, `item=<spec>`, `item=<spec>x<n>`, `fuel=<number or expression over args>`, `gps=true` |
| `returns` | one line describing what `job.report()` carries |

Arguments arrive as the global `args`. `needs` is evaluated before the first
instruction runs; `fuel` may be an expression over the bound arguments, so
`fuel=width*width*depth` scales with the call.

## `frame`, and what it actually buys

`frame` documents what a routine is anchored to. Be precise about what that
prevents, because it is easy to overstate.

A routine that captures `nav.pos()` and works outward from it is **correct**.
Called from a new position it does the relative thing at the new position,
which is the whole point of being relative. Registration does not object.

What `args.origin` buys is *reach*, not safety. `lib.run` defaults it to the
turtle's current position, so behaviour is identical — but a caller can also
pass one, and target the routine somewhere else without walking the turtle
there first:

```lua
lib.run("quarry", { origin = site, depth = 24 })
```

That is why anchoring to `nav.pos()` produces a warning rather than a refusal.
`nav.pos()` also remains the right call for drift checks and round-trip
assertions:

```lua
if geom.manhattan(nav.pos(), args.origin) > 50 then job.warn("drifted") end
job.report({ back = geom.eq(nav.pos(), args.origin) })
```

Registration refuses a header that **contradicts** the source — `anywhere` on
something that anchors to a position, `absolute` on something that anchors to
wherever the turtle happens to be. A false statement about the code is worth
refusing; a stylistic preference is not.

### The frame mismatch that is genuinely silent

Without GPS, `nav.localFrame()` anchors coordinates wherever the turtle
booted. A `frame: absolute` routine holding `{x=120,y=64,z=-300}` was written
against one such frame; re-place the turtle, let it boot a new one, and those
same numbers now point somewhere else in the world. Nothing throws — the
turtle drives confidently to the wrong place.

So registration stamps `nav.frameId()` onto the entry, and `lib.run` compares
it before calling an `absolute` routine. Every GPS frame is the same frame, so
GPS machines never trip it. Relative routines never refer to the frame at all
and are immune.

## What registration actually checks

`/register` runs `agent/lint.lua` over the source and compares the findings to
the declaration. It detects:

| finding | |
|---|---|
| `ambient-anchor` | a local bound from `nav.pos()`/`nav.facing()` that later feeds a position-consuming call |
| `absolute-coords` | a literal `{x=,y=,z=}` outside a `geom.add`/`sub`/`v` offset |
| `relative-facing` | `"forward"`/`"back"`/`"left"`/`"right"` passed to a direction-taking call |
| `calls-library` | `lib.run` by callee name, for cycle awareness |
| `undefined-global` | a name that does not exist in the sandbox |

Strings and comments are blanked before any of this runs, so
`job.say("go forward")` is not a direction word and a coordinate in a comment
is not a hardcoded location.

A finding is not automatically a problem. `undefined-global` is always an
error, because the code will crash. The rest become errors only when they
contradict the declared `frame`, and are otherwise warnings — `ambient-anchor`
in a `relative` routine is correct behaviour that merely costs targetability,
so it is reported and allowed.

**The known limits, stated plainly.** Lua offers no AST, so the anchor check
is a heuristic and will miss a position captured deep inside a loop and
assigned indirectly. And a coordinate literal is syntactically identical
whether it is a world position or a relative offset — context is the only
signal, so a literal assigned to a local and then passed to `geom.add` reads
as a coordinate. Neither gap is closable without writing a parser, which costs
more than the problem is worth at this scale. It is also why registration is
an explicit operator action rather than something that happens on its own.

Semantic preconditions are wholly invisible to static analysis. That is what
`needs:` is for, and the reason it is worth writing even when it feels
obvious.

## Calling routines from routines

Allowed, with guards in `agent/lib.lua`:

- a call stack of **names** refuses a cycle at the first repeated name and
  prints the whole chain — the dangerous case is the cycle spread across
  separately saved programs, which no single file reveals
- nesting is capped at `lib.maxDepth` (4)
- `job.name` and `job.result` are pushed and popped, so a nested report cannot
  clobber its caller's return value and nested checkpoints cannot collide
- `block.restoreFacing` and `nav.policy` are snapshotted and restored even
  when the routine throws
- routines compile against a child environment, so their globals stay theirs
- `job.ABORT` is a sentinel table, so a routine's own `pcall` cannot swallow a
  stop request

## Testing routines

`test/run_lib.lua` covers the subsystem and is the place to add cases. The
mock world makes the nesting hazards cheap to reproduce — a distributed cycle
is three four-line routines — and those are exactly the bugs you do not want
to be discovering from inside a Minecraft world at 3am.
