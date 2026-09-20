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

**Added**

- `inv.craft(pattern)` and `inv.clearGrid()`. With the capability bug
  below fixed, the turtle equipped its crafting table and then crafted
  nothing: "No matching recipes". A turtle crafts from the left 3x3 of
  its inventory (slots 1,2,3 / 5,6,7 / 9,10,11), so wheat sitting in slot
  8 is invisible to `turtle.craft`, anything else left in the grid joins
  the recipe, and recipes are shaped — three wheat in one slot is not
  bread, three wheat across three cells is. None of that is derivable
  from the API surface, so no generated script should be expected to get
  it right; `inv.craft({{"*wheat","*wheat","*wheat"}})` now does the
  clearing, the placement and the craft. The prompt says to use it and
  never `turtle.craft`.

**Added**

- `inv.equip(spec, side?)` and `inv.unequip(side?)`. Equipping was left to
  generated programs, which meant every one of them re-derived the same
  swap by hand — and got it wrong in the same way, leaving a turtle's
  pickaxe in the inventory. `inv.craft` now equips a carried crafting
  table itself and puts the displaced tool back, so a script asks for
  bread and gets bread. `opts.restore = false` keeps the table on for a
  script crafting in a loop.
- A failed craft reports the layout it refused (`1=wheat 2=wheat 6=dirt`)
  rather than only that it refused. A craft that fails is debuggable only
  if you can see the grid it was looking at.

**Fixed**

- **`turtle.craft` existing does not mean a crafting table is attached.**
  On at least some builds the method outlives the upgrade that added it:
  unequip the table and `turtle.craft` is still there, still callable,
  and returns a bare `false` — no message — which reads as "your recipe
  is wrong" when the truth is "there is nothing attached". Everything
  here treated the method's presence as the capability, so `inv.craft`
  skipped equipping and crafted against a turtle with bare sides. It now
  asks what is on each side (`turtle.getEquippedLeft`/`Right`) and only
  falls back to the method on builds too old to answer — and on those,
  a failed craft with a table in the inventory is retried once with it
  equipped, because trying is the only way to find out. `caps.equipped`
  exposes the same question, and the `crafting` probe uses it, so
  `/caps` stops reporting crafting on a turtle that cannot craft.
- Item names could not be written bare. `inv.find("crafting_table")`
  returned nothing, because matching was exact and the item is
  `minecraft:crafting_table`. Generated code writes the short form
  constantly — it is how people say these names — and the failure reads
  like an empty inventory rather than a spelling difference. A pattern
  with no namespace and no wildcard now matches any namespace, so
  `"wheat"` finds `minecraft:wheat` and `"stone"` still does not find
  `minecraft:cobblestone`.

**Changed**

- A command typed without its slash no longer goes to Claude as a
  request. `save makeBread` instead of `/save makeBread` cost an API call
  *and* overwrote the working program it was meant to keep — the two
  failures compound, which is what makes it worth catching. Both front
  ends now ask first. The check only fires on at most two words, so
  "run a quarry down to y=12" is still a request: a false positive costs
  one keystroke, and asking about every sentence would be worse than the
  mistake it prevents.
- The input prompt is `cc>` rather than `>`. Both the shell and ccagent
  prompted identically, which made a screenshot — or a glance — ambiguous
  about which one was waiting, and the two take different things: one
  takes CC programs, the other takes English and spends money on it.
  Colour does not settle it, since a plain turtle is not an advanced
  computer and `term.isColour()` is false there. It lives in
  `console.PROMPT` so all three front ends agree, and a host aimed at one
  turtle shows `cc@7>`.

**Fixed**

- **Equipping a crafting table did not make the turtle able to craft.**
  A turtle carrying a crafting table, asked to bake bread, equipped the
  table — correctly — and then reported "crafting capability unavailable
  even when equipped". Two independent staleness bugs, either of which
  was enough on its own:
  - `agent/caps.lua` probes once and caches. Nothing invalidated that
    cache on equip, so `caps.has("crafting")` kept returning the answer
    from boot. `caps.detect`'s own comment said to force a re-probe
    "after the turtle equips a different tool"; nothing ever did. There is
    now `caps.refresh()`, the sandbox calls it after `equipLeft`/
    `equipRight`, and `caps.require` re-probes once before refusing —
    a script that just equipped the tool it needs is right and the cache
    is wrong.
  - `claude/executor.lua` built the script's `turtle` table by copying
    `pairs(turtle)` once. `turtle.craft` does not exist until a crafting
    table is equipped, so it was absent from that copy and stayed absent
    however successfully the script equipped one — and the loop that
    wraps inventory-mutating calls skipped `craft` for the same reason.
    The table is now resolved live through `__index`, wrapping mutators
    as they appear.
- Capability-gated entries had the same shape of bug one level up.
  `registry.environment` replaced an unavailable function with an error
  stub, discarding the real one — from the live module table, so the
  function was gone for the whole session, for every caller, even after
  the capability appeared. The stub now keeps the real function and
  re-checks before refusing.
- A mistyped API key said nothing until the first request came back 401,
  which on a 39-column screen is a long way from the typing that caused
  it. `install.lua` now reports the length it stored and says so when the
  value does not start with `sk-ant-` or looks truncated, and
  `install --key` re-asks without anyone having to delete
  `/.ccagent/key` by hand. The 401 message names that file rather than
  saying "check the API key in config", which pointed at `config.lua` —
  the wrong file, since the key deliberately lives outside the tree.
- **The front ends could not load the library at all.** `ui/controller.lua`,
  `ui/worker.lua` and `ui/host.lua` each set
  `package.path = "/?.lua;/?/init.lua;"`, which resolves `agent.util` to
  `/agent/util.lua` — the tree at the filesystem root, not at `/ccagent`
  where it installs. Running `/ccagent` died on the first `require`.
  `install.lua` had the same wrong prefix and survived it by accident,
  because CC also searches the running program's own directory and
  `install.lua` sits in `/ccagent` itself; the `ui/` files are one level
  deeper, so that fallback lands on `/ccagent/ui/agent/util.lua` and
  misses. Every entry point now names `/ccagent` explicitly.
  `test/run_boot.lua` simulates module resolution against the real repo
  layout rather than matching strings, so it fails if any entry point
  stops being able to find what it requires.
- `install.lua` printed its key prompt and self-check at up to 66 columns
  onto the same 39-column screen, so the capability report a first-time
  operator most wants to read was the part that scrolled away. Now at most
  33, and short enough to fit in 13 rows.
- The launcher was documented, in `install.lua` and in `README.md`, as
  making `ccagent` work "from any directory". It does not: CC's shell path
  is `.:/rom/programs`, so `/ccagent.lua` resolves by bare name only when
  the current directory is `/`. From anywhere else it is "No such
  program", which is what a first install actually produced. Everything
  now says `/ccagent`, which works from anywhere, and the reason is
  written down next to the launcher rather than left to be rediscovered.
- The first-run prompt did not fit a turtle. It printed about twenty lines
  once wrapped, onto a 39x13 screen with no scrollback, so the explanation
  scrolled away and left an unexplained `from>`. Found on the first real
  in-game run, which is the only place it could have been found: every
  automated check here renders to a terminal that does not exist. The
  prompt is now 10 lines of at most 32 characters, and
  `test/run_boot.lua` measures what the prompts actually print rather than
  trusting them. Error messages got the same treatment.
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
