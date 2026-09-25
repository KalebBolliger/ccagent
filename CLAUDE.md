# CLAUDE.md

Guidance for an agentic session working in this repo. Kept short on
purpose — this is the entry point, not the reference. It orients and links;
it doesn't restate what's already written elsewhere.

## What this is

ccagent lets a CC:Tweaked (Minecraft) turtle take natural-language requests,
have Claude turn them into short Lua programs against a prebuilt capability
library, and run them with automatic error repair. Two front ends (a
standalone turtle, or a host computer driving a fleet over rednet) share one
core. Full picture: `README.md`.

## Before you consider any change done

```
lua5.3 test/all.lua
```

561 assertions against a mocked CC:Tweaked world (`test/mock.lua`), in well
under a second, with no Minecraft required. If you touched `agent/` or
`claude/`, run it before saying you're finished, not just when something
seems wrong.

**Know what it does and does not prove.** It is good at regressions in
things we already understand: facing math, path replanning, sandbox leaks,
nesting hazards, contract parsing. It is worthless against a wrong belief
about what CC:Tweaked or Minecraft actually does, because `test/mock.lua`
encodes the same belief. Every one of these shipped green:

- `block.fill` reported *every* successful fill as incomplete. Zero is
  truthy in Lua; the test asserted `info.unplaceable == 0` and passed.
- `block.till` could not work in any situation. The tests stood the turtle
  on the block being tilled — the one geometry Minecraft forbids.
- the `frame` lint in 1.1.0, whose tests were written from the same wrong
  premise as the rule (`CHANGELOG.md`).

So when the game disagrees with the tests, **fix the mock first** and watch
the existing tests fail. A green suite after a correction to
`test/mock.lua` means something; a green suite after a change to `agent/`
alone only means you did not break what was already understood.

(That count is checked. `test/all.lua` fails if this file or `README.md`
quotes a number that is no longer true — a figure cited as evidence and
left to rot makes every claim near it look equally unmaintained.)

## Deployment target is NOT the interpreter you're testing with

Tests and this doc run under `lua5.3` for convenience. The actual runtime
is CC:Tweaked's bundled Lua (Cobalt — roughly 5.1, with some later
backports), which is stricter on the things people don't expect: no
`table.unpack` (there's a shim, `util.unpack = table.unpack or unpack` —
use it, don't add a second one), no `//`, no bitwise operators, no `goto`
in older builds, no `utf8` library. Passing `test/all.lua` does not by
itself prove new code will run in-game if it leans on a 5.2/5.3-only
feature. When in doubt, write it the way the rest of the codebase already
does — nothing here currently relies on anything past 5.1.

## Map

| path | what |
|---|---|
| `agent/` | the capability library: nav, block, inv, world, job, caps, registry, contract, lint, lib |
| `claude/` | the LLM layer: API client, prompt assembly, code extraction, sandboxed executor, session/repair loop |
| `ui/` | the two front ends (`controller` standalone, `host`+`worker` fleet) and their shared bits |
| `test/` | `mock.lua` (fake CC:Tweaked world) + `run.lua`/`run_lib.lua`/`run_boot.lua`/`all.lua` |
| `boot.lua`, `manifest.txt` | the bootstrapper and the one list of what ships to a CC machine |
| `jobs/` | where saved/registered operator routines land at runtime (`.gitignore`d; see its `.gitkeep`) |

## Read before you touch it

- **Adding a capability** (new Lua the model can call, or wiring up a saved
  routine) → `docs/EXTENDING.md`.
- **Changing the core** (`nav`, `lib`, `prompt`, `session`, anything with
  module-level state) → `docs/ARCHITECTURE.md`. It documents the one
  invariant that's easy to break without any test failing (the cache
  boundary between the system prompt and per-request state), the nesting
  hazards in `lib.run` and why each exists, and a list of numbers in this
  codebase that are guesses rather than derivations.
- **What actually changed and why, including corrected mistakes** →
  `CHANGELOG.md`. The `frame` lint was wrong in 1.1.0 in a way no test
  caught, because the tests were written from the same wrong assumption —
  worth reading once so the same reasoning error doesn't recur.

## Never commit

This repository is public. Nothing that belongs to a person, a machine or a
conversation goes into it — not into a file, and not into a commit message,
which is just as public and much harder to correct later.

- **Secrets.** API keys, tokens, cookies. The Anthropic key lives in
  `/.ccagent/key` and any source token in `/.ccagent/token`, both outside
  this tree by design, and `/.ccagent/` is `.gitignore`d so a
  reconfiguration cannot drag them back in. A key in a diff is a key to
  rotate, not a key to delete.
- **Identifying details.** Names, emails, handles, server addresses, IPs,
  world seeds, coordinates of anyone's actual base. Examples in docs are
  invented ones (`files.mylan`, `OWNER/REPO`, `192.168.0.0/16`) and should
  stay that way.
- **Conversation specifics.** Session links, chat transcripts, ticket or
  thread references, "as discussed", "the person who asked for this". Write
  what changed and why it is right, in terms someone reading the repo cold
  can check. If a decision came from an exchange, record the reasoning, not
  the exchange.
- **Machine-local paths.** Anything under a working directory, temp or
  scratch directory from the environment a change happened to be made in.

Commit trailers are subject to all of the above: `Co-Authored-By:` is fine,
a session or conversation URL is not.

Before pushing anything new here, and always before making history public:

```
git log --format='%an <%ae>%n%B' | grep -niE 'session_|claude\.ai/code|@[a-z0-9.-]+\.[a-z]{2,}'
```

Nothing should come back but `noreply@anthropic.com`.

## Habits specific to this repo

- Don't add a new piece of module-level mutable state (a flag like
  `block.restoreFacing`) without adding matching save/restore in
  `lib.run`'s nesting boundary — see `docs/ARCHITECTURE.md`'s nesting
  table. Nothing enforces this automatically; it's a checklist.
- If a design decision produces an enforcement rule (a lint check, a
  registration refusal), write out the concrete scenario it's meant to
  catch and confirm that scenario is actually wrong before shipping the
  rule. The `frame` mistake in 1.1.0 was a plausible-sounding rule that
  nobody — including the test suite written to cover it — checked against
  a real example.
- Anything a person reads in-game has to fit **39 columns by 13 rows** —
  a turtle's screen — and CC terminals have no scrollback, so a prompt
  taller than the screen scrolls its own explanation away before it can be
  read. Put the detail in `README.md` and keep the in-game text to what
  someone needs at that moment. `test/run_boot.lua` measures the
  bootstrapper's prompts; nothing measures the rest, so check by eye.
- **Zero is true in Lua.** Never make a caller derive a boolean from a
  count. `block.fill` returned `info.unreachable = 0` on a perfect run
  and `claude/prompt.lua` told the model to write
  `if info.unreachable then` — so a finished 9x9 floor reported itself as
  "fill incomplete", every single time, and the test written from the
  same assumption asserted `== 0` and passed. A failure count that did
  not happen is now absent, and `info.complete` states the answer
  outright. If you add another count to a result table, either omit it
  when it is zero or give the table a boolean that says what the caller
  actually wants to know.
- A cache is only as good as its invalidation, and the operator is not a
  caller. `agent/inv.lua` caches the inventory and only this library's own
  operations invalidate it — so anything the operator does through the
  turtle's GUI is invisible until something re-reads. Every boundary where
  we start trusting the world again after an arbitrary gap has to
  invalidate: `executor.run` before a program starts, `agent.situation`
  before describing the turtle to Claude. Adding a third such boundary
  means adding a third invalidation. The same goes for `agent/caps.lua`,
  which re-probes everything cheap at those boundaries — a new probe is
  refreshed by default, and one too slow to re-run (the GPS fix blocks
  for two seconds) must say so with `{ expensive = true }`.
- A probe that cannot tell must return `nil`, and `nil` must survive into
  the flags table. `caps.detect` used to write `ok and val or false`,
  which turned the digging probe's "I will not destroy the block in front
  of me to find out" into "this turtle cannot dig" — permanently, for a
  turtle that happened to boot facing a wall. `caps.summary` still has a
  `dig?` branch for unknown; if it can never fire again, something has
  re-collapsed the two answers.
- World memory is a record of moments, not a description of the world.
  `agent/world.lua` entries carry a timestamp and belong to a coordinate
  frame; acting on one without checking either is how a wall gets a hole
  in it (`block.fill` skipped a cell memory called solid) and how a
  re-placed turtle reasons about somebody else's blocks. Read `isStale`
  before trusting an observation, and remember that without GPS the
  coordinates themselves are only meaningful within one frame —
  `world.useFrame` drops the memory when that changes, and is called at
  the same boundaries as the other invalidations.
- **`test/mock.lua` says which of its behaviours are verified and which
  are fixtures, and the suite counts them.** `mock.provenance` maps every
  faked turtle function to the CC:Tweaked class it was read from, or to
  `fixture` (the real answer is decided at runtime by a datapack or the
  world, so no fixed rule can be right) or `unverified` (nobody has
  looked). `mock.apiSurface` lists what our code can reach, so a function
  the library calls and the mock lacks fails a test instead of waiting to
  become a nil-index in a path nothing covers. Adding a faked function
  without a provenance entry fails too. Currently 28 verified, 2
  fixtures, 15 unverified — and the last number is the honest measure of
  how much of this suite is resting on nothing.
- **CC:Tweaked is open source, so read it instead of guessing.** Two
  failures in a row came from plausible reasoning about behaviour that is
  written down: long generations died because `http.request` takes a
  `timeout` field that is a *read* timeout (30s default, 60s max) and we
  never passed it, and tilling did nothing because `TurtleTool.dig` offers
  the block to the tool before breaking it — with a comment saying you
  cannot till with a block above. Both were settled in one fetch of
  `cc-tweaked/CC-Tweaked` on GitHub. A guess about the game costs an
  in-game round trip to disprove; reading the source costs a minute.
- **Files kept across updates go stale silently.** `/ccagent/config.lua` is
  written once and preserved by `boot` (that is deliberate — it holds the
  operator's choices), and saved programs under `jobs/` are snapshots of
  the API as it was the day they were written. Changing a default or adding
  a capability therefore reaches nobody who already has it installed. When
  you change either, say so in `CHANGELOG.md`: `boot` reports a shipped
  config that differs from the kept one, `config.warnings` flags settings
  that will bite, and `/revise` rewrites a saved program against the
  current API. None of it fires on its own.
- Where the game can be asked, ask it. A hardcoded list of what counts as
  fuel, what a recipe looks like, or which upgrades exist is a list that is
  wrong on somebody's modpack — and wrong silently, as "this turtle has no
  fuel" while it carries thirty-two lignite. `turtle.refuel(0)` and
  `turtle.getEquippedLeft/Right` cost one call and cannot be out of date.
  Keep the lists for *preference* (burn coal before planks) and let the
  game decide *membership*.
- A new file under `agent/`, `claude/` or `ui/` has to be added to
  `manifest.txt` as well, or turtles installed over the wire will not get
  it. `test/run_boot.lua` catches this; `lua5.3 test/all.lua` is the only
  thing standing between that mistake and a confusing in-game failure.
- Keep `registry.add` (and the contract-header equivalent for saved
  routines) as the *only* way a capability becomes visible to the model.
  Anything added ad hoc outside that path won't appear in the manifest and
  won't be capability-gated correctly.
