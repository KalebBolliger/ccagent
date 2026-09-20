# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Versions are `agent.VERSION` in `agent/init.lua`, checkable at runtime with
`/state` or the install self-check.

## Unreleased

**Added**

- `boot.lua`: a one-command bootstrapper, so getting this onto a turtle is
  one file and a url rather than copying twenty-nine files through a disk
  drive. It fetches `manifest.txt`, pulls what it lists into `/ccagent`, and
  hands off to `install.lua` for the local setup.
- Where it pulls from is configuration, never code. There is no repo, host
  or url anywhere in `boot.lua` — a deployment is a public forge, a private
  one behind a token, a fork, or a file server on the LAN, and picking one
  of those as "the" default only makes the other three second-class. On a
  machine that has not been told, it asks; the answer is remembered in
  `/.ccagent/source`, so later updates are `ccagent update`. A test fails if
  a url-valued constant reappears, and another fails if it ever guesses
  instead of asking.
- A source can also be a directory this computer can see, so a floppy is a
  first-class install medium: `boot --from /disk/ccagent` reads the manifest
  off the disk and never touches http, which matters because not everyone
  has somewhere to host a tree, and a Minecraft save is already a directory
  on the operator's own machine. The disk is remembered like any other
  source, so a later `ccagent update` re-reads it.
- The source is otherwise a url template: `{path}` is required, `{repo}` and
  `{ref}` are filled from `--repo`/`--ref`. A source without `{path}` — which
  includes every local one — is treated as a directory to append to. `--header "Name: value"` is repeatable and
  remembered; `--token` sends a bearer header and keeps the secret in
  `/.ccagent/token`, deliberately not in `/.ccagent/source`, which is meant
  to stay safe to copy between turtles.
- A forge that answers a file request with base64 JSON metadata used to be
  the worst available outcome: a tree that installs cleanly and fails much
  later as a syntax error in a file nobody edited. That response is now
  detected and refused, naming the `Accept` header that fixes it.
- Every file is buffered before anything is written, so a download that
  dies half way leaves the existing install untouched rather than a turtle
  running a mixed-version library.
- `manifest.txt`: the single list of what belongs on a CC machine.
  `install.lua` had its own copy, which is exactly the kind of thing that
  drifts silently — the drift is only visible in-game, as a missing module.
  `test/run_boot.lua` fails if the manifest and the repo disagree in either
  direction.
- `test/run_boot.lua`: 80 assertions over source resolution, templates,
  local and remote reads, headers and tokens, the remembered source,
  `config.lua` survival, the all-or-nothing write, and refusal of a manifest
  path that would write outside `/ccagent`.

**Fixed**

- The generated `/ccagent.lua` launcher called `table.unpack`, which does
  not exist in CC:Tweaked's Lua. Every `ccagent host <args>` and
  `ccagent worker <args>` with arguments after the mode would have failed
  on a real machine; only the bare forms were ever exercised. It now shims
  `unpack` the way the rest of the codebase does.
- `install.lua` wrote the launcher only if one was not already there, so an
  install over an older copy kept the old launcher forever. It is generated
  content; it is now rewritten every time.

**Changed**

- `install.lua` no longer downloads anything itself. Given a base url it
  fetches `boot.lua` (if this machine has only `install.lua`) and delegates,
  so the fetch loop, the file list and the source configuration each exist
  once.

## 1.1.1

**Fixed**

- `geom.iterBox` was not actually lazy: it built the entire cell list before
  returning the first one. A 48×48×48 excavation allocated ~110,000 tables
  in one non-yielding stretch, on a runtime that terminates a computer for
  going ten seconds without yielding. Rewritten as a true generator —
  constant memory, first cell returns immediately, traversal order verified
  byte-identical to the old implementation across seven cases.
- The `frame` lint was over-strict. `ambient-anchor` (a routine capturing
  `nav.pos()` and building outward from it) was rejected for `frame:
  relative`, but that is *correct* behaviour — called from a new position it
  does the relative thing there, which is the point. Demoted to a warning;
  it now only flags that the routine loses the ability to be aimed via
  `args.origin`, not that it's wrong. Still an error when the header
  contradicts the code (`anywhere`/`absolute` combined with position
  anchoring).
- `claude/prompt.lua`'s contract instructions correspondingly stopped
  telling the model to avoid `nav.pos()`, and now point its attention at
  `needs:`, which is where real silent failures actually live (a missing
  tool or item — the turtle moves, accomplishes nothing, reports
  success-shaped output).

**Added**

- The coordinate-frame check the `frame` rework should have shipped with in
  1.1.0: without GPS, `nav.localFrame()` now stamps a fresh frame id each
  time a *new* local frame is established. A `frame: absolute` routine
  records the id it was registered under; `lib.run` refuses to call it if
  the turtle has since booted a different local frame (e.g. after being
  broken and re-placed), rather than driving confidently to coordinates that
  no longer mean what they did. GPS frames are all mutually consistent, so
  GPS turtles never trip this. See `test/run_lib.lua` >
  `"coordinate frames: the failure that is actually silent"`.

## 1.1.0 — saved routines

**Added**

- `agent/contract.lua`, `agent/lint.lua`, `agent/lib.lua`: programs can be
  promoted from one-off scripts to routines Claude can call by name —
  `lib.run("quarry", {depth = 24})` — via a `@ccagent` contract header
  (name, doc, `frame`, typed `args`, `needs`).
- Three independent states per saved program: **saved** (source on disk,
  operator-runnable, free) / **registered** (contract validated, callable by
  generated code, free) / **listed** (name + doc in the cached system
  prompt, ~15 tokens each). Tracked in `jobs/index.json`.
- `+<request>` asks the model to write the contract header during the
  original generation, in the call that was already being paid for.
  `/register` on a headerless saved program offers a retrofit — one extra
  call that re-parameterises it, seeded with the lint findings so the model
  works from facts about its own source rather than re-reading it.
- Registration is a gate, not a formality: it parses the header, lints the
  source, and refuses to register when the declaration contradicts what the
  code demonstrably does (`prompt.CONTRACT`, `lint.consistency`).
- Nesting support in `agent/lib.lua`, because the hazards are almost never
  about stack depth:
  - **Distributed cycles** (`a → b → c → a` spread across separately saved
    files, so no single file shows the loop) caught by a call stack of
    *names*, which also prints the full chain in the error.
  - **Shared module state** — `job.result`, `job.checkpoint` namespacing,
    `block.restoreFacing`, `nav.policy` — saved and restored across every
    `lib.run` boundary, including when the callee throws.
  - **Swallowed aborts** — the stop signal (`job.ABORT`) is a sentinel
    table, not a string, so a routine's own `pcall` cannot silently eat a
    stop request.
  - **Leaked globals** — routines compile against a child environment.
- New commands: `/register`, `/unregister`, `/expose`, `/check`, `+` prefix.
  `/jobs` now shows state per saved program.

**Changed**

- `ui/jobs.lua` rewritten as a thin operator-facing wrapper over
  `agent/lib.lua`, which is where the actual store now lives (it has to be
  reachable from `agent/` because running code calls into it).
- System prompt grew from ~2,700 to ~3,500 tokens (rules + manifest +
  contract instructions + examples), still fully cached. The saved-routine
  index is part of the cached prefix, not the per-request state line, and
  is rebuilt only when `lib.listingVersion()` actually changes.

## 1.0.0 — initial

- Core capability library: `nav` (position tracking, A* pathfinding,
  obstacle memory, fuel), `block` (inspect/dig/place/attack in ten
  direction words), `inv` (glob/tag/predicate item queries over a
  tick-saving cache), `world` (persistent sparse block memory), `job`
  (operator I/O, reboot-safe checkpoints), `caps` (runtime capability
  probing).
- `agent/registry.lua`: single source of declarations that generates both
  the sandbox environment a generated program runs in and the API manifest
  shown to Claude, so the two cannot drift apart. Capability-gated entries
  are hidden from machines that lack the hardware and raise a readable
  error if called anyway.
- `claude/`: Messages API client (async via `http.request` + the event
  loop, so a request never blocks the ability to cancel), cached system
  prompt, code-fence extraction tolerant of untagged and truncated fences,
  a sandboxed executor, and a session that repairs a failing program by
  sending the error and prior output back for a fix.
- Two front ends over the same core: `ui/controller.lua` (standalone
  turtle, own key, own conversation) and `ui/host.lua` + `ui/worker.lua`
  (a computer holds the key and dispatches to turtles over rednet, one
  conversation per worker).
- `test/mock.lua` + `test/run.lua`: a voxel world, a mocked turtle, and
  enough of `fs`/`textutils`/`os` to exercise the whole core with `lua5.3`
  outside Minecraft.
