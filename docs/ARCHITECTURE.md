# Architecture

This is the doc to read before changing anything under `agent/` or
`claude/` — as opposed to `docs/EXTENDING.md`, which is for *adding* a
capability without touching the core, and `README.md`, which is written for
the operator, not the maintainer.

It covers three things a diff can easily get wrong without any test
failing: the invariant the whole cost model depends on, the hazards that
only show up under nesting, and the places where a design choice was a
judgment call rather than a derivation — so you know which numbers are load
bearing and which are guesses that happened to work.

## The one invariant: what's cached, what isn't

`agent/registry.lua` is the single source of truth for the sandbox
environment a generated program runs in AND the API manifest Claude is
shown (`registry.environment()` / `registry.manifest()`, both built from
the same `registry.declare` calls). That part is easy to keep intact,
because the two would visibly disagree if it broke.

The part that's easy to break silently is the cache boundary, because
nothing will *fail* if you get it wrong — the system will just get slowly
more expensive, and you won't notice until someone checks `/stats`.

- `claude/prompt.lua` `prompt.system()` builds one block, carries
  `cache_control: ephemeral`, and must be **byte-identical across turns**
  unless the operator did something that should legitimately invalidate it
  (`/notes`, `/register`, `/expose`, a model switch, a different worker's
  capability set). It currently holds: the rules, the API manifest, the
  saved-routine index (`lib.manifest()`), the contract-writing
  instructions, and the worked examples.
- `prompt.situation()` builds the other block — pose, fuel, inventory
  summary, world summary — and goes in the **user turn**, uncached, every
  request.

Anything that changes per-request does not belong in the first block.
Anything stable across the whole session does not belong in the second.
`agent/lib.lua`'s `listingVersion()` exists specifically so `session.lua`
can tell "did the cacheable stuff actually change" apart from "a request
happened" — copy that pattern rather than re-triggering `buildSystem(true)`
speculatively, or every routine registration starts paying full price on
every subsequent turn.

`test/run_lib.lua` > `"prompt integration"` asserts the prefix is stable
across calls that shouldn't move it and does move when something registers.
If you touch `prompt.lua` or `session.lua`, that group is the one to watch.

## Conventions that are load-bearing, not stylistic

- Facing: `0=north(-Z) 1=east(+X) 2=south(+Z) 3=west(-X)` (`agent/geom.lua`).
  Getting the sign wrong on any of the four is the kind of bug that only
  shows up as the turtle walking into a wall it just inspected.
- Direction words (`forward/back/left/right/up/down/north/east/south/west`)
  are accepted everywhere in `nav`/`block`, resolved once in
  `geom.resolve`. Add a new one there, not per-call-site.
- Item specs (`"minecraft:coal"`, `"*_log"`, `{tag=...}`, `{name=...,
  min=n}`, a predicate function) are matched in one place,
  `inv.matches` — same reasoning.
- `nav.policy.protect` (bedrock, shulker boxes, chests, barrels, spawners,
  command blocks, portals, anything `computercraft:*`) is never dug through
  regardless of `dig = true`. This is a judgment call about what an
  operator would consider a mistake, not a technical constraint — see
  "Unverified premises" below.
- A* (`nav.findPath`) treats an unobserved cell as cost 1 (optimistic — go
  there, find out) and a known-solid, non-protected cell as cost 4
  (diggable, but prefer routing around it). `world.staleAfter` (10 minutes)
  is when an observation stops being trusted as gospel; it's advisory, not
  enforced by the pathfinder itself. Both numbers are guesses; see below.

## Nesting hazards (`agent/lib.lua`)

Routines calling routines is where almost every subtle bug in this
subsystem lives, and stack depth is the least of it.

| hazard | mechanism | guarded by | test |
|---|---|---|---|
| distributed cycle (`a→b→c→a` across separately saved files — no single file shows the loop) | call stack of *names*, checked on every `lib.run` entry | `callStack` in `lib.run`, capped by `lib.maxDepth = 4` | `"nesting: the distributed cycle"`, `"nesting: depth cap"` |
| a nested `job.report` clobbering the caller's return value | `job.push`/`job.pop` save and restore `job.result` around the call | `agent/job.lua` frame stack | `"nesting: state isolation"` |
| nested `job.checkpoint` colliding with the caller's (this would corrupt the reboot-resume mechanism the checkpoints exist for) | `job.push`/`job.pop` also swap `job.name`, which namespaces checkpoint keys | same | same |
| a routine flipping `block.restoreFacing` or `nav.policy` and throwing before restoring it, leaving the CALLER's environment wrong | `lib.run` snapshots both before the call and restores them in all paths, including the error path | `agent/lib.lua` around the `pcall` | `"nesting: module flags restored"` |
| a routine's own `pcall` silently swallowing an operator stop request | `job.ABORT` is a sentinel **table**, not a string, so a generic `pcall(fn)` doesn't look like it caught a normal error; every `lib.run` boundary re-checks `job.checkAbort()` on the way out regardless | `job.ABORT`, `job.rethrowAbort`, `job.isAbort` | `"nesting: abort survives a routine's own pcall"` |
| a routine assigning a global and leaking it into the caller | routines compile with `load(src, name, "t", env)` where `env` is a *child* of the sandbox (`setmetatable({args=...}, {__index = sandbox})`), so writes land in the child, not the parent | `lib.run`'s `load` call | `"nesting: a routine's globals do not leak"` |

If you add a new piece of module-level mutable state anywhere in `agent/`
(another flag like `block.restoreFacing`), it needs the same
snapshot-before / restore-after treatment in `lib.run`, or it will silently
leak between nested calls. There's no mechanism that catches this
automatically — it's a manual checklist, which is exactly the kind of thing
that erodes over time. Consider that a warning sign if a change is adding
mutable module state at all.

## `frame`: what it checks and — importantly — what it doesn't

This was wrong in 1.1.0 and fixed in 1.1.1 (see `CHANGELOG.md`), and it's
worth understanding *why* it was wrong so it doesn't drift back.

**A routine that captures `nav.pos()` and works outward from it is
correct.** Called from a new position, it does the relative thing at the
new position — that's what "relative" means. It is not a hazard, and
`lint.consistency` does not treat it as one for `frame: relative`.

What `args.origin` (which `lib.run` injects, defaulting to `nav.pos()`)
buys over calling `nav.pos()` directly is **targetability**: a caller can
pass a different origin and aim the routine somewhere else without walking
the turtle there first. That's a capability improvement, not a
correctness one, so `ambient-anchor` under `frame: relative` is a
*warning*, not an error.

What **is** an error is the declaration contradicting the code:
`frame: anywhere` claimed for something that anchors to a position, or
`frame: absolute` claimed for something that anchors to wherever the
turtle happens to be. Those are false statements about the code, and
`lint.consistency` refuses to register them. `undefined-global` is always
an error regardless of frame, because the code will simply crash.

The one case that fails *silently* and is worth real enforcement: without
GPS, coordinates are meaningful only within the local frame the turtle
booted into (`nav.localFrame`). A `frame: absolute` routine's literal
coordinates were written against one such frame. Re-place the turtle,
which boots a new local frame, and the same numbers point somewhere else —
nothing throws, the turtle just confidently goes to the wrong place. So
registration stamps `nav.frameId()` onto the entry, and `lib.run` refuses
to call an `absolute` routine if the current frame doesn't match the one
it was registered under. GPS frames all compare equal to each other
(`nav.frameId()` returns the literal string `"gps"`), so this never fires
on a GPS-equipped turtle. Relative routines never reference the frame and
are unaffected either way. See `"coordinate frames: the failure that is
actually silent"`.

If you're tempted to make `ambient-anchor` an error again: don't, without
first writing out the concrete scenario where it produces wrong behavior.
The lesson from 1.1.0 was that "this could theoretically be misused" is not
the same claim as "this misbehaves," and only one of those is worth
refusing a registration over.

## What the lint can and cannot see (`agent/lint.lua`)

Pattern-based, on purpose — Lua has no accessible AST from pure Lua, so
this is regex-shaped heuristics over source with strings/comments blanked
first (`lint.strip`), not a real parser. Known gaps, not closable without
writing one:

- A position captured deep inside a loop, or assigned indirectly through a
  few hops, will not be recognized as an anchor. The check looks for
  `local x = nav.pos()` followed by `x` reaching a position-consuming call;
  anything less direct slips through.
- A coordinate literal `{x=.., y=.., z=..}` is syntactically identical
  whether it's a world position or a relative offset. The only available
  signal is whether it appears as an argument to `geom.add`/`sub`/`v`/
  `iterBox` (then it's an offset, not flagged) — a literal assigned to a
  local first and passed to `geom.add` on the next line reads as a
  hardcoded coordinate and isn't. False positive, not false negative, so
  it costs a warning, not a wrong registration.

Neither gap is worth closing at this scale — a real parser is a lot of
surface area to maintain for heuristics that are backstopped by `needs:`
anyway (see below) and by the fact that registration is an explicit,
reviewable operator action, never automatic.

**What the lint cannot see at all** is semantic preconditions: "assumes a
chest behind me," "assumes a pickaxe rather than a hoe," "assumes a stack
of cobble already in inventory." None of that is in the syntax. That's the
entire reason `needs:` exists as a separate, hand-declared field, checked
by `contract.checkNeeds` before a routine's first instruction runs. A
turtle missing a declared precondition gets a readable thrown error; a
turtle missing an *undeclared* one moves, accomplishes nothing, and reports
success-shaped output. That second failure mode is real and is not
mitigated by anything in this codebase except the operator writing
`needs:` honestly — there's no way to derive it from source.

## The HTTP timeout is CC's, not ours (`claude/client.lua`)

Worth knowing before touching the client, because the obvious reading of a
"Timed out" failure sends you to the wrong setting.

CC:Tweaked puts a Netty `ReadTimeoutHandler` on every `http.request`. It
measures **silence on the socket**, not elapsed time, and it is the thing
that kills long generations:

- default **30s**, maximum **60s**, passed as the `timeout` field of the
  `http.request` options table (seconds). Out of range is an error from
  `http.request`, not a warning.
- there is no server-side config for it — it is per request or nothing.
- when it fires you get `http_failure` with CC's own message, the literal
  string `"Timed out"`, and **no response handle**.

A non-streaming Messages call sends zero bytes until the entire reply has
been generated. So the ceiling on a job is not "how long will the operator
wait" — it is "can Claude write this whole program in under 30 seconds of
wall clock." An 11×11×2 excavation asked for at 4096 `max_tokens` is
comfortably over it, and fails *mid-generation* having spent the output
tokens.

Streaming (`stream: true`, on by default) fixes this and is the only thing
that does: deltas and `ping` events keep bytes arriving, so the read
timeout never fires however long the job takes. Note what it does *not*
buy, because it is tempting to assume otherwise — CC's
`HttpRequestHandler` accumulates the whole body into a composite buffer
and only fires `http_success` at `LastHttpContent`. Lua never sees a
partial response. So:

- there is no progress reporting to be had from streaming here, and no
  spinner that reflects real progress;
- **a timed-out request cannot be recovered from.** The buffer is
  discarded and no handle reaches us. The only partial case we can
  observe is a body that arrived complete but whose SSE stream has no
  `message_stop` — `client.unstream` flags that as `truncated` so a
  half-written program is reported as cut off rather than handed to the
  syntax check.

Two timeouts therefore exist and they are not interchangeable:
`readTimeout` (CC's, ≤60, the silence window) and `timeout` (ours, an
`os.startTimer` backstop so a wedged request can't hang the turtle
forever). Raising ours does nothing about the failure this section
describes.

## Thinking is on unless you turn it off (`claude/client.lua`)

The companion trap to the timeout above, and the same shape of mistake:
a number that looks like a ceiling on the program is really a ceiling on
something else.

Current models (Sonnet 5, Opus 5, and up) run **adaptive thinking when the
`thinking` parameter is omitted**. Leaving it unset is not the same as
switching it off — it is how you ask for the default, and the default is
on. Those thinking tokens are spent out of `max_tokens` *before* the first
character of the program. So `maxTokens = 4096` on a hard request fails as:

```
max_tokens with no text (4096 out, blocks: thinking)
```

Not "the program was too long" — the program was never started. The
response's only content block is a `thinking` block, and since
`thinking.display` defaults to `"omitted"` on these models, that block
comes back with empty text, so it is invisible unless the error names it.
That is why `client.parse` reports the block types rather than just the
stop reason.

The fix is a generous `maxTokens` (32000) plus `effort` as the real cost
control, not disabling thinking — the generated programs are better with
it. Reach for `effort = "low"` before `thinking = "off"`.

Two spellings are dead on current models and will 400 if you reintroduce
them:

- `thinking = { type = "enabled", budget_tokens = N }` — the pre-4.6 form.
  Still sent if the operator writes `thinking = { budget = N }` in
  `config.lua`, because a config may name an older model, but never on
  its own.
- `temperature` — rejected outright. Only sent when no `thinking`
  directive is present.

## Unverified premises

Things the design assumes but that have not been measured against a real
API, listed so a maintainer doesn't mistake "we built around this" for "we
confirmed this":

- **Prompt caching is actually engaging and saving what the architecture
  assumes.** The whole cost model rests on the system-prompt prefix being
  cache-hit on the second and subsequent requests of a session. Nothing in
  `test/` can check this — the client is stubbed in every test that touches
  it. Check with `/stats` after a few real requests; `cacheRead` should
  dominate `inTokens` after the first call.
- **The manifest approach actually beats an unassisted model writing
  turtle control code from scratch.** This is the founding premise of the
  project and it has never been A/B'd. If it's false, the token-cost story
  and the correctness story (position tracking, obstacle memory, protected
  blocks) both weaken, though the correctness story would still hold on
  its own merits.
- **The model reaches for library calls instead of reimplementing them.**
  If a generated program routinely rolls its own movement loop instead of
  calling `nav.moveTo`, both the cost savings and the safety guarantees
  (fuel checks, protected-block refusal, obstacle memory) are bypassed
  without anything failing. Worth spot-checking `/code` output
  periodically, not just trusting the prompt's instructions to work.
- **`config.minTokens = 8000`**, the floor below which the startup
  warning fires, is invented. It is meant to be "obviously too small once
  thinking is on", not a measured boundary.
- **`maxTokens = 32000` and `effort = "medium"`** are guesses. 32000 is
  "comfortably more than the 4096 that failed", not a measured ceiling,
  and nothing has checked whether `low` would do just as well on a typical
  turtle job for less money. Both are cheap to tune from `config.lua` and
  `/doctor` reports them, so start there if jobs feel slow or expensive.
- **`client.timeout = 180`** is a guess: a backstop generous enough not to
  interrupt a legitimately long generation, short enough that a wedged
  request does not strand the turtle. Nothing measured it. `readTimeout`
  is not a guess — 60 is CC's documented maximum.
- **`world.staleAfter = 600000` (10 min) and the A* `enterCost` of `4` for
  a known-diggable block** are both invented numbers, not derived from
  anything. They control "how long do I trust what I saw" and "how much do
  I prefer routing around a wall over digging through it," respectively.
  Reasonable-sounding, untested against real play patterns.
- **`nav.policy.protect`** encodes an assumption about what an operator
  would consider an unacceptable thing to dig through by default (chests,
  spawners, portals, bedrock, other computers). It's a judgment call made
  on your behalf, not a technical necessity — `/notes` or a direct request
  can always ask for something the list would otherwise avoid, since it
  only gates the *default* pathfinding behavior via `nav.policy.dig`.

None of these need to block anything. They're listed so that if something
about cost or correctness feels off in practice, this is the list of
places to look first, rather than re-deriving suspicion from scratch.

## Where the system is deliberately unfinished

`claude/executor.lua`'s contract is `run(code, env, opts) -> result` —
run, capture, repair, report. That's intentionally the simple version. A
fuller session manager (pause/resume, a persistent job queue, scheduled and
repeating tasks, resuming a half-finished quarry after a chunk unload) is
meant to slot in around that same contract without changing it.
`job.checkpoint`/`job.recall` already persist for exactly this reason — a
routine written against them today should resume correctly whenever that
lands, without needing to be rewritten.

## Map of the docs

- **`README.md`** — operator-facing: install, commands, what the generated
  code can call, cost-control knobs.
- **`docs/EXTENDING.md`** — how to add a capability, either as a
  hand-written module (`registry.add`) or a saved routine (`@ccagent`
  contract header). Read this before writing new Lua for the library.
- **`docs/ARCHITECTURE.md`** (this file) — read before changing the core:
  `agent/nav.lua`, `agent/lib.lua`, `claude/prompt.lua`,
  `claude/session.lua`.
- **`manifest.txt`** — what gets installed on a CC machine. New file under
  `agent/`, `claude/` or `ui/`? It goes here too, or turtles installed with
  `install.lua` will not have it.
- **`CHANGELOG.md`** — what changed and why, including the corrections to
  earlier design mistakes. Worth reading in full at least once; it's
  shorter than re-deriving the same mistakes.
- **`CLAUDE.md`** — entry point for an agentic session working on this
  repo; links to all of the above rather than repeating them.
