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

236 assertions against a mocked CC:Tweaked world (`test/mock.lua`), in well
under a second, with no Minecraft required. Every bug this project has
actually shipped was the kind this catches — facing math, path replanning,
sandbox leaks, nesting hazards. If you touched `agent/` or `claude/`, run it
before saying you're finished, not just when something seems wrong.

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
  `CHANGELOG.md`. The `frame` lint was wrong in 1.1.0 in a way that took a
  direct challenge from the person who commissioned it to catch — worth
  reading once so the same reasoning error doesn't recur.

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
- A new file under `agent/`, `claude/` or `ui/` has to be added to
  `manifest.txt` as well, or turtles installed over the wire will not get
  it. `test/run_boot.lua` catches this; `lua5.3 test/all.lua` is the only
  thing standing between that mistake and a confusing in-game failure.
- Keep `registry.add` (and the contract-header equivalent for saved
  routines) as the *only* way a capability becomes visible to the model.
  Anything added ad hoc outside that path won't appear in the manifest and
  won't be capability-gated correctly.
