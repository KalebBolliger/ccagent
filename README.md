# ccagent

A Claude-driven turtle for ComputerCraft: Tweaked.

You type a request in English. Claude writes a short Lua program against a
prebuilt capability library. The controller runs it, streams the output back,
and repairs it automatically if it throws.

```
> mine out a 5x3x5 room in front of me and dump the loot in the chest behind me
.. asking Claude...
--- program ---
 1 local p = nav.pos()
 2 local dug = block.clear(geom.add(p,{x=0,y=0,z=0}), geom.add(p,{x=4,y=2,z=4}), {
 3   dumpWhenFull = function() ... end })
...
.. running...
  cleared 61 blocks
= {dug = 61}
done in 94.2s
```

---

## The idea

The expensive part of an LLM-driven turtle is not the thinking, it is the
boilerplate. A model asked to "collect 64 logs" without a library will write
its own movement loop, its own collision handling, its own inventory scan, and
its own return-to-base routine — several hundred tokens of code that is
identical every single time, and wrong in a new way every time.

So the tokens go into a **manifest** instead. Every capability is declared once,
in a terse signature list that is sent as a *cached* system prompt. After the
first request of a session it costs roughly a tenth of full price, and it does
not grow with the number of requests. What varies per request is one short
state line and your sentence.

```
system prompt : ~2,700 tokens, cached     (rules + API manifest + examples)
per request   : ~60 tokens of live state + your sentence
per response  : usually 150-400 tokens of Lua
```

The library is also where correctness lives. Position tracking survives
reboots, the pathfinder remembers walls it has bumped into, protected blocks
are never dug through, and a program that hangs is always one keypress from
stopping — none of which the model has to get right, or can get wrong.

## Two ways to run it

**Standalone.** One turtle, its own key, its own conversation.

```
/ccagent
```

**Host and fleet.** A stationary computer holds the key and the conversations;
turtles run a thin worker that never touches the network. One place to update,
one key to rotate, and a separate conversation per turtle so "now do the same
thing one chunk east" lands on the right one.

```
(on the computer)  /ccagent host
(on each turtle)   /ccagent worker
```

```
cc> /who
*3    quarry-1     0,64,0 facing north | fuel 19834 | frame gps
 7    builder      118,71,-294 facing east | fuel 4102 | frame gps
cc> @7 build a 9x9 cobblestone floor under you
cc@7> all come home and unload
```

The prompt is `cc>` — not the shell's `>`, so it is clear which of the two
you are typing at. On a host aimed at one turtle it carries the target:
`cc@7>`.

Both front-ends sit on the same core. Nothing under `agent/` or `claude/`
knows which one is driving.

## Install

Put `boot.lua` on the machine and run it. It is the only file you have to move
by hand, and where it fetches the rest from is up to you — nothing is baked in:

```
wget run <wherever-you-keep-this>/boot.lua
```

It asks where to pull from (once), pulls every file `manifest.txt` lists into
`/ccagent`, and hands off to `install.lua`, which makes the directories, asks
once for an Anthropic API key (stored in `/.ccagent/key`, nowhere else),
installs a `/ccagent.lua` launcher, and runs a self-check that prints what
this particular machine can do.

Run it as `/ccagent` — absolute. CC's shell path is `.:/rom/programs`, so the
bare name `ccagent` only resolves when your current directory is `/`.

Mistyped the key? `/ccagent/install --key` asks again. It reports the length it
stored and warns if the value does not look like an Anthropic key, because the
alternative is finding out at the first request.

Nothing is written until every file has arrived, so a dropped connection leaves
an existing install alone rather than half-replaced. A `config.lua` you have
edited is kept, not overwritten.

The answer is remembered in `/.ccagent/source`, so from then on, from any
directory:

```
/ccagent update
```

### Where it pulls from

A source is either a directory this computer can see — a mounted floppy will
do — or a url template containing `{path}`, with `{repo}` and `{ref}` filled
in from `--repo` / `--ref` if you use them. Anything with no `{path}` in it,
which includes every local path, is treated as a directory and `/{path}` is
appended:

```
/disk/ccagent
https://files.mylan:8080/ccagent
https://raw.<forge-host>/OWNER/REPO/main/{path}
https://<api-host>/repos/OWNER/REPO/contents/{path}?ref={ref}
```

| | |
|---|---|
| `/ccagent/boot --from /disk/ccagent` | install from a floppy, or any local directory |
| `boot --url <template>` | set (and remember) the source |
| `boot v1.1.1` | change only the ref |
| `boot --repo you/ccagent --ref dev` | fill the template's placeholders |
| `boot --token <secret>` | send `Authorization: Bearer …` |
| `boot --header "Name: value"` | any other header; repeatable, remembered |
| `boot --force` | replace `config.lua` with the shipped one too |
| `boot --startup worker` | write a `startup.lua` as well |
| `boot --no-prompt` | fail instead of asking; for startup scripts |

`--startup worker` makes the turtle rejoin its host after a chunk reload;
`host` and `solo` do the same for the other two modes. `--ref` defaults to
`main`. A bare argument is read as a url if it looks like one, a repo if it
looks like `owner/name`, and otherwise a ref — so a branch name containing a
slash needs the explicit `--ref`.

`wget run` is not guaranteed to forward arguments, so for anything but a bare
run, save the file first and then run it:

```
wget <wherever-you-keep-this>/boot.lua
boot --url https://files.mylan:8080/ccagent
```

`/.ccagent/source` is plain `key=value` text and yours to edit:

```
url=https://files.mylan:8080/ccagent/{path}
repo=you/ccagent
ref=main
header.X-Deploy-Key=whatever
```

Seed it from a floppy and a whole fleet installs without being asked anything.

### No web server? Use a floppy

You do not need anywhere to host this. A Minecraft save is a directory on your
disk, and everything a computer can see is a directory in it, so you can put
the tree there and let the game hand it around.

For one machine, drop the repo into that computer's own folder — find its id
with the `id` command in-game — and run the installer:

```
<save>/computercraft/computer/<id>/ccagent/     <- the tree goes here
```
```
/ccagent/install
```

For more than one, use a floppy, which is the same idea but reusable. Put the
tree in a disk's folder, then put that disk in a drive next to each turtle:

```
<save>/computercraft/disk/<n>/ccagent/          <- the tree goes here
```
```
/disk/ccagent/boot --from /disk/ccagent
```

That runs `boot.lua` straight off the floppy: it reads `manifest.txt` from the
disk, writes `/ccagent`, keeps any `config.lua` already on the turtle, and
hands off to `install.lua` as usual. The disk is remembered as the source, so
updating a turtle later is `/ccagent update` with the floppy in the drive —
refresh the files on the disk once and every machine can re-pull from it.

No http is involved at any point, so this works in a world with the HTTP API
switched off entirely.

### Pulling from a private repository

If you would rather pull over the wire, `--token <secret>` sends
`Authorization: Bearer <secret>` with every request and stores the token in
`/.ccagent/token` — not in `/.ccagent/source`, so the source file stays safe to
copy between turtles. When a token is present `boot.lua` also asks for raw
content rather than metadata, since a forge that answers a file request with
base64 JSON would otherwise install a tree that fails later as a syntax error.
(If it ever does, `boot.lua` says so instead of writing it.) Override with
`--header "Accept: …"`.

For GitHub, the contents API serves private files to a fine-grained token with
read access to that one repository:

```
boot --url "https://api.github.com/repos/{repo}/contents/{path}?ref={ref}" \
     --repo you/ccagent --token github_pat_...
```

The token sits in plain text on the in-game computer, readable by anyone who
can reach that computer's files or the world save — so scope it to one
repository, read-only, with an expiry. The floppy above is the option where no
secret exists in Minecraft at all.

### Which host the game will talk to

CC:Tweaked's HTTP rules live in `computercraft-server.toml` — in `config/` on
a dedicated server, and under the world's `serverconfig/` in singleplayer. The
default rules allow the public internet but **deny private IP ranges**, so a
public API needs no change while a machine on your own LAN needs an explicit
allow rule ahead of the `$private` deny:

```toml
[[http.rules]]
    host = "192.168.0.0/16"
    action = "allow"
```

None of this is affected by the mod loader: NeoForge, Forge and Fabric builds
of CC:Tweaked run the same Lua, so every path and command here is the same on
all of them. Only the config and save locations are the loader's business, and
the two above are where current builds put them.

### Without HTTP at all

Use the floppy route above, or copy the tree to `/ccagent/` by hand and run:

```
/ccagent/install
```

`/ccagent/install <base-url>` also still works for a plain directory url: it
fetches `boot.lua` and lets it do the pulling, so the file list only ever lives
in `manifest.txt`.

Requirements: CC:Tweaked with the HTTP API enabled (default) and
`api.anthropic.com` reachable — that one is not optional, since it is how
Claude is asked anything; installing from a floppy avoids needing http for the
*install*, not for running. A GPS constellation is optional but strongly
recommended — without it coordinates are local to wherever the turtle booted.
Everything else is detected at runtime.

## Using it

Anything that is not a slash command is a request.

| command | |
|---|---|
| `/state` | what the turtle sees and carries |
| `/caps` | capability probe results |
| `/manifest` | the API Claude is shown, and its token cost |
| `/code` | full source of the last program |
| `/again` | re-run it — **no API call** |
| `+<request>` | ask for a **reusable routine** rather than a one-off |
| `/save <name>` / `/run <name>` | keep a program that worked and re-run it forever, free |
| `/register <name>` | make a saved program callable by Claude |
| `/expose <name> on\|off` | show or hide it in the prompt |
| `/unregister <name>` / `/check <name>` | revoke it; lint it without registering |
| `/dry <request>` | generate a program without running it |
| `/notes <text>` | house rules appended to the system prompt |
| `/calibrate`, `/sethome`, `/home`, `/refuel` | housekeeping |
| `/reset` | forget the conversation (world memory survives) |
| `/stats` | token usage, including cache hits |

Press **Q** while a job runs to ask it to stop at the next checkpoint; press it
again to force.

Follow-ups are diffs, not new descriptions — the previous program is still in
the conversation, so "same thing but two blocks deeper" is cheap.

`/save` is the cheapest optimisation available. A program that worked is worth
more than the sentence that produced it; running it again costs nothing.

## Saved routines

`/save` alone is for you: it stores source that you can `/run`, and Claude
never learns it exists. `/register` goes further and makes a program callable
from generated code as `lib.run("quarry", {depth = 24})`, so future requests
compose proven routines instead of regenerating the same logic.

Three states, independent on purpose:

| | | cost |
|---|---|---|
| **saved** | source on disk, `/run`-able by you | nothing |
| **registered** | validated contract, `lib.run` will call it | nothing |
| **listed** | name + doc in the cached prompt | ~15 tokens |

Registered-but-unlisted is the useful middle shelf: Claude won't reach for it
unprompted, but it still works when you name it in a request or mention it in
`/notes`. `/expose <name> off` puts a routine there.

**Registration is gated, and the gate is the point.** A routine needs a
contract header, which Claude writes during generation when you prefix the
request with `+`:

```
> +dig a shaft down from wherever I'm standing, size and depth as options
```

```lua
--[==[ @ccagent
name:    shaft
doc:     excavate a shaft downward from the caller's position
frame:   relative
args:    size:number=2, depth:number=16
needs:   caps=digging, item=*_pickaxe, fuel=size*size*depth
returns: number of blocks dug
]==]
```

`/register shaft` then parses the header, lints the source, and **rejects the
header if it contradicts the code** — a program that declares
`frame: anywhere` while anchoring to `nav.pos()` does not register. `needs:`
is checked before the routine's first instruction, so a missing pickaxe throws
a readable error instead of a turtle that wanders off and does nothing useful.

`needs:` is the field that earns its keep. Static analysis cannot see that a
routine assumes a pickaxe rather than a hoe, or a chest behind the turtle. A
turtle missing one of those will move, accomplish nothing, and report
success-shaped output — that is the failure that is genuinely silent, and
declaring the precondition converts it into a clear error.

`frame:` is documentation of intent, and a narrower check. It declares what a
routine is anchored to — `relative` (to the caller, via the injected
`args.origin` / `args.facing`), `absolute` (to coordinates in the source), or
`anywhere` (inventory work, pure reporting).

Worth being precise about what this does and does not prevent. A routine that
captures `nav.pos()` and works outward from it is **correct**: called from a
new position it does the relative thing at the new position, which is the
point. Registration does not object to that. Anchoring to `args.origin`
instead is a *reach* improvement — identical default behaviour, plus a caller
can aim the routine somewhere else without walking the turtle there — so it
is a warning, not a refusal.

What registration does refuse is a header that **contradicts** the code:
`anywhere` on something that anchors to a position, `absolute` on something
that anchors to wherever the turtle happens to be. A false statement about
the code is worth refusing; a stylistic preference is not.

The one case where a frame mismatch fails in silence is real and is checked
at call time. Without GPS, coordinates are anchored wherever the turtle
booted. A `frame: absolute` routine records which frame its literals were
written against, and if the turtle is later re-placed under a new local
frame, `lib.run` refuses rather than driving confidently to the wrong place.
Relative routines are immune, because they never referred to the frame.

Didn't think ahead? `/register` on a headerless program offers to promote it —
one API call that re-parameterises it, using the lint findings so the model
works from facts about its own source rather than re-reading and guessing.

Editing a saved program revokes its registration, because the old validation
no longer describes the new source. Your listing preference survives, so
re-registering puts it back where it was.

### What the lint can and cannot see

It catches mechanical dependencies: ambient position capture, hardcoded
coordinates, facing-relative direction words, library calls, and references
to names that don't exist in the sandbox. It cannot see semantic
preconditions — "assumes a chest behind me", "assumes a pickaxe not a hoe".
That is exactly what `needs:` is for, and why registration is an explicit
operator action rather than something automatic.

### Nesting

Routines may call routines. The hazards are handled, and they are mostly not
about stack depth:

- **Distributed cycles.** `quarry → restock → gofuel → restock`, where no
  single file contains the loop. A call stack of *names* catches it on entry
  and prints the whole chain.
- **Shared module state.** `job.result` is one slot and `job.checkpoint` keys
  are namespaced by job name, so a nested `job.report` would clobber its
  caller's return value and nested checkpoints would corrupt the
  reboot-resume mechanism. `block.restoreFacing` and `nav.policy` are module
  flags a routine may flip and fail to restore. All four are saved and
  restored across every boundary.
- **Swallowed aborts.** The stop signal is a sentinel table, not a string, so
  a routine's own `pcall` cannot quietly eat it; every boundary re-checks.
- **Leaked globals.** Routines compile against a child environment, so a
  global they assign stays inside them.

## What the generated code can use

`nav` movement and pathfinding · `block` inspect/dig/place/attack in any of ten
direction words · `inv` inventory as a query · `world` persistent block memory ·
`geom` coordinate math · `job` operator I/O and reboot-safe checkpoints · `lib`
your own registered routines · `caps` capability guards · `helper` odds and
ends.

`/manifest` prints the current list with signatures. A few of the calls that do
the most work:

```lua
nav.moveTo({x=104,y=64,z=-31})        -- A*, obstacle memory, gravel, mobs, fuel
block.digVein("*_ore", {max=64})      -- flood-fill a vein and come back
block.clear(a, b, {dumpWhenFull=fn})  -- excavate a box
block.fill(a, b, "*_planks")          -- build one
inv.count({tag="minecraft:logs"})     -- tag- and glob-aware matching
world.find("*chest*", {near=nav.pos()})  -- answered from memory, zero server calls
helper.roundTrip(fn)                  -- always end up where you started
```

Scripts run in a sandbox: no `fs`, no `http`, no `shell`, no `require`. The raw
`turtle` table is available as an escape hatch, but its movement functions are
rerouted through `nav` so position tracking cannot desync.

## Cost control

- **Keep `cache = true`.** It is most of the savings. `/stats` shows cache
  reads; if that number stays near zero, something is invalidating the prefix.
- `/notes`, switching models, and `/register` / `/expose` each re-cache once.
  Switching turtles in a mixed fleet does too, because the manifest is
  filtered by capability. None of these is worth avoiding; just don't toggle
  listings mid-session out of idle curiosity.
- The saved-routine index lives in the **cached** prefix, not the per-request
  state line — it's stable between registrations, so putting it in the live
  block would mean paying full price for it on every request forever. At
  ~15 tokens per listed routine, fifty of them add ~750 to a ~3,500-token
  prefix. You will find scrolling `/jobs` annoying long before the tokens
  matter, which makes `/expose` a curation tool more than a cost one.
- `thinking` is off by default. Most turtle jobs do not need it and it triples
  latency. Turn it on in `config.lua` for genuinely hard planning.
- `maxRepairs` (default 2) bounds the automatic fix loop.

## Extending

Adding a capability is one `registry.add` call. See `docs/EXTENDING.md` for a
worked example; the short version:

```lua
local registry = require("agent.registry")
local farm = {}

function farm.harvest(radius) ... end

registry.add("farm", farm, "crop tending", {
  { fn = "harvest", sig = "(radius?) -> n", doc = "break and replant ripe crops" },
})
```

Claude sees it on the next request. The sandbox and the manifest are generated
from the same declarations, so they cannot drift apart.

Capability-gated entries (`requires = "crafting"`) are hidden from turtles that
lack the upgrade, and calling one anyway raises *"farm.harvest needs 'crafting',
which this machine does not have"* instead of a nil-index error.

## Layout

```
agent/     util geom state caps world nav inv block job
           registry contract lint lib init
claude/    client prompt extract executor session config
ui/        console jobs net controller worker host
test/      mock run run_lib run_boot all   -- lua5.3 test/all.lua, no Minecraft
jobs/      where saved/registered routines land at runtime (gitignored)
boot.lua manifest.txt    one-command install, and the list of what it pulls
config.lua install.lua
CLAUDE.md              entry point for an agentic coding session
docs/ARCHITECTURE.md   core internals, invariants, and known unknowns
docs/EXTENDING.md      how to add a capability or a saved routine
CHANGELOG.md           what changed, release by release
```

`lua5.3 test/all.lua` runs the three suites against a mock world — 321
assertions covering facing math, pathfinding, replanning, inventory matching,
the sandbox, fence extraction, manifest generation, contract parsing and
gating, lint accuracy, distributed cycle detection, nested state isolation,
abort survival, and the bootstrapper. Run it before shipping a change; it catches the class of bug that is
miserable to debug in-game.

## Where this is going

The executor is deliberately the simple version: run, capture, repair, report.
Its contract — `run(code, env, opts) -> result` — is what a fuller session
manager slots in around: pause and resume, a persistent job queue, scheduled
and repeating tasks, and resuming a half-finished quarry after a chunk unload.
`job.checkpoint` / `job.recall` already persist, so programs written against
them today will resume correctly when that lands.
