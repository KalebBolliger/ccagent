--[[ agent/lib.lua ------------------------------------------------------
  The saved-program library: storage, three-state registration, and the
  call machinery that lets one program invoke another.

  THREE STATES, deliberately independent:

    saved        source on disk; the operator can /run it     cost: nothing
    registered   has a validated contract; lib.run will call  cost: nothing
    listed       name + doc in the cached system prompt       cost: ~15 tokens

  Registered-but-unlisted is the useful middle shelf. Claude will not reach
  for such a routine on its own, but it still works when the operator names
  it in a request or mentions it in /notes. That is where the long tail
  lives, so the prompt only carries what you actually want offered.

  NESTING is where the sharp edges are, and they are not about stack depth:

    * The dangerous cycle is distributed. `quarry` calls `restock`, which
      was saved months earlier calling `gofuel`, which calls `restock`. No
      single program contains the loop and nobody reviewing one sees it. A
      call stack of NAMES catches it on entry and can print the chain.

    * Module state is shared. job.result is one slot, so a nested report()
      would clobber its caller's return value. job.checkpoint keys are
      namespaced by job.name, so nested checkpoints would collide -- and
      corrupt the reboot-resume mechanism they exist for. block.restoreFacing
      and nav.policy are module flags a routine may flip; an error between
      flip and restore leaves them wrong for the CALLER, who has no idea.
      All four are saved and restored across every boundary here.

    * Abort must survive. job.ABORT is a sentinel rather than a string
      precisely so a routine's own pcall cannot quietly eat a stop request;
      every boundary re-checks on the way in and on the way out.
--------------------------------------------------------------------------]]

local util     = require("agent.util")
local geom     = require("agent.geom")
local caps     = require("agent.caps")
local nav      = require("agent.nav")
local inv      = require("agent.inv")
local block    = require("agent.block")
local job      = require("agent.job")
local contract = require("agent.contract")
local lint     = require("agent.lint")

local lib = {}

lib.dir       = "/ccagent/jobs"
lib.indexPath = "/ccagent/jobs/index.json"
lib.maxDepth  = 4

local index      = nil    -- name -> { registered, listed, doc, savedAt, request }
local contracts  = {}     -- name -> parsed contract (memo)
local sources    = {}     -- name -> source text (memo)
local callStack  = {}
local sandbox    = nil    -- set by executor via lib.bind

---------------------------------------------------------------- storage ---

local function pathFor(name)
  return lib.dir .. "/" .. tostring(name):gsub("[^%w%-_]", "_") .. ".lua"
end

local function loadIndex()
  if index then return index end
  index = util.readJSON(lib.indexPath) or {}
  return index
end

local function saveIndex()
  return util.writeJSON(lib.indexPath, loadIndex())
end

function lib.source(name)
  if sources[name] then return sources[name] end
  local src = util.readFile(pathFor(name))
  if src then sources[name] = src end
  return src
end

function lib.contract(name)
  if contracts[name] ~= nil then
    return contracts[name] or nil
  end
  local src = lib.source(name)
  if not src then return nil, "no saved program called " .. tostring(name) end
  local c, err = contract.parse(src)
  contracts[name] = c or false
  if not c then return nil, err end
  return c
end

function lib.state(name)
  local e = loadIndex()[name]
  if not e then
    if lib.source(name) then return { registered = false, listed = false } end
    return nil
  end
  return e
end

--- Save source. Always succeeds; registration is a separate, checked step.
--- Returns ok, contractOrNil, message.
function lib.save(name, code, meta)
  if not fs then return false, nil, "no filesystem" end
  if not fs.exists(lib.dir) then fs.makeDir(lib.dir) end
  local header = ("-- ccagent job: %s\n-- saved: %s\n%s\n"):format(
    name,
    tostring(os.date and os.date("%Y-%m-%d %H:%M") or util.now()),
    meta and ("-- request: " .. tostring(meta):gsub("\n", " ")) or "")
  -- Keep the contract header at the very top of the file, where the parser
  -- and a human both expect it.
  local hdr = contract.extract(code)
  local out = hdr and (code) or (header .. code)
  if not util.writeFile(pathFor(name), out) then
    return false, nil, "could not write " .. pathFor(name)
  end
  sources[name], contracts[name] = nil, nil

  local idx = loadIndex()
  idx[name] = idx[name] or {}
  -- Re-saving replaces the source, which means any previous validation is
  -- stale: the contract may no longer describe what the code does. So a
  -- save always revokes registration and the operator must /register again.
  -- `listed` is kept as a preference, not a state, so re-registering
  -- restores whatever visibility you had chosen.
  idx[name].registered = false
  idx[name].savedAt = util.now()
  idx[name].request = meta and tostring(meta):sub(1, 160) or idx[name].request
  saveIndex()
  return true
end

--- Remove a saved program: its source, its index entry -- which is where
--- registration lives, so this unregisters it too -- and the in-memory
--- copies. Returns false when there was nothing of that name, so the
--- operator is not told a typo was deleted.
function lib.delete(name)
  local idx = loadIndex()
  local existed = (fs and fs.exists(pathFor(name))) or idx[name] ~= nil
  if not existed then return false, "no saved program called " .. tostring(name) end
  if fs and fs.exists(pathFor(name)) then fs.delete(pathFor(name)) end
  idx[name] = nil
  sources[name], contracts[name] = nil, nil
  saveIndex()
  return true
end

function lib.names()
  local out, seen = {}, {}
  for name in pairs(loadIndex()) do
    if lib.source(name) then out[#out + 1] = name; seen[name] = true end
  end
  if fs and fs.exists(lib.dir) then
    for _, f in ipairs(fs.list(lib.dir)) do
      local n = f:match("^(.+)%.lua$")
      if n and not seen[n] then out[#out + 1] = n end
    end
  end
  table.sort(out)
  return out
end

----------------------------------------------------------- registration ---

--- The gate. A header alone does not register a program: it triggers this
--- check. Parse, lint, and confirm the declaration is not contradicted by
--- what the source demonstrably does.
--- Returns ok, contract, errors, warnings, findings.
function lib.validate(name, allowed)
  local src = lib.source(name)
  if not src then return false, nil, { "no saved program called " .. name } end

  local c, perr = contract.parse(src)
  if not c then return false, nil, { perr } end
  if c.name ~= name then
    return false, nil, { ("header says name: %s but the program is saved as %s")
      :format(c.name, name) }
  end

  local findings = lint.check(src, allowed or lib.allowedNames())
  local errors, warnings = lint.consistency(c, findings)
  return #errors == 0, c, errors, warnings, findings
end

--- Names that legitimately exist inside the sandbox, for the undefined-global
--- check. Built from the live registry plus the standard-library subset the
--- executor exposes.
function lib.allowedNames()
  local out = {}
  for _, n in ipairs({ "string", "table", "math", "os", "pairs", "ipairs",
                       "next", "select", "type", "tostring", "tonumber",
                       "pcall", "xpcall", "error", "assert", "setmetatable",
                       "getmetatable", "rawget", "rawset", "rawequal",
                       "rawlen", "unpack", "sleep", "print", "write",
                       "textutils", "colors", "keys", "vector", "turtle",
                       "args", "_G", "_ENV" }) do
    out[n] = true
  end
  local ok, registry = pcall(require, "agent.registry")
  if ok then
    for ns in pairs(registry.namespaces()) do out[ns] = true end
  end
  return out
end

function lib.register(name, allowed)
  local ok, c, errors, warnings, findings = lib.validate(name, allowed)
  if not ok then return false, errors, warnings, findings end
  local idx = loadIndex()
  idx[name] = idx[name] or {}
  idx[name].registered = true
  -- Absent means "never chosen" -> listed. Explicit false is an operator
  -- decision and survives re-registration.
  if idx[name].listed == nil then idx[name].listed = true end
  idx[name].doc = c.doc
  idx[name].frame = c.frame
  -- Record which coordinate system the literals in this routine were
  -- written against. Only meaningful for frame: absolute, but it is free.
  idx[name].frameId = nav.frameId()
  saveIndex()
  return true, errors, warnings, findings, c
end

function lib.unregister(name)
  local idx = loadIndex()
  if not idx[name] or not idx[name].registered then
    return false, (name or "?") .. " is not registered"
  end
  idx[name].registered = false
  idx[name].listed = false
  saveIndex()
  return true
end

function lib.expose(name, on)
  local idx = loadIndex()
  if not idx[name] or not idx[name].registered then
    return false, "register it first"
  end
  idx[name].listed = on and true or false
  saveIndex()
  return true
end

------------------------------------------------------------------ calls ---

function lib.bind(env) sandbox = env end

function lib.depth() return #callStack end

function lib.chain(extra)
  local out = {}
  for _, n in ipairs(callStack) do out[#out + 1] = n end
  if extra then out[#out + 1] = extra end
  return table.concat(out, " -> ")
end

--- Call a registered routine. Errors are raised, not returned, so a caller
--- that does not handle them fails loudly rather than continuing on bad
--- assumptions -- and the message is written for the repair loop to read.
function lib.run(name, args)
  job.checkAbort()

  for _, n in ipairs(callStack) do
    if n == name then
      error(("routine cycle detected: %s (a saved routine eventually calls " ..
             "itself; the loop is spread across separately saved programs)")
            :format(lib.chain(name)), 0)
    end
  end
  if #callStack >= lib.maxDepth then
    error(("routine nesting too deep (limit %d): %s")
          :format(lib.maxDepth, lib.chain(name)), 0)
  end

  local st = lib.state(name)
  if not st then error(("no saved routine called '%s'"):format(tostring(name)), 0) end
  if not st.registered then
    error(("'%s' is saved but not registered -- the operator must /register it")
          :format(name), 0)
  end

  local c, cerr = lib.contract(name)
  if not c then error(("'%s' has no usable contract: %s"):format(name, tostring(cerr)), 0) end

  local bound, berr = contract.bindArgs(c, args)
  if not bound then error(("calling '%s': %s"):format(name, berr), 0) end

  -- frame: relative routines anchor to the caller, not to ambient state.
  -- Supplying these explicitly is what makes the idiom available; the lint
  -- is what stops a routine reaching for nav.pos() instead.
  if c.frame == "relative" then
    if bound.origin == nil then bound.origin = nav.pos() end
    if bound.facing == nil then bound.facing = nav.facing() end
  end

  -- The one genuinely silent failure in this whole scheme: a routine built
  -- on literal coordinates means something different under a different
  -- coordinate system. Without GPS the frame is anchored wherever the turtle
  -- booted, so a re-placed turtle running a routine saved under its previous
  -- frame drives confidently to the wrong place and nothing throws.
  -- Position-relative routines are immune, which is why only `absolute` is
  -- checked here.
  if c.frame == "absolute" then
    local authored, current = st.frameId, nav.frameId()
    if authored and current and authored ~= current then
      error(("routine '%s' has fixed coordinates recorded in a different " ..
             "coordinate frame (%s, now %s) -- those numbers no longer point " ..
             "where they did. Re-register it here, or re-establish GPS.")
            :format(name, authored, current), 0)
    end
  end

  local okNeeds, why = contract.checkNeeds(c, bound,
    { caps = caps, inv = inv, nav = nav })
  if not okNeeds then
    error(("routine '%s' %s"):format(name, why), 0)
  end

  local src = lib.source(name)
  if not src then error(("source for '%s' disappeared"):format(name), 0) end

  -- Compile against a child environment so any global the routine assigns
  -- stays inside the routine and cannot leak into its caller's namespace.
  local env = setmetatable({ args = bound }, { __index = sandbox or _G })
  local chunk, lerr = load(src, "@" .. name, "t", env)
  if not chunk then error(("'%s' failed to compile: %s"):format(name, tostring(lerr)), 0) end

  -- Snapshot the module state a routine could leave wrong for its caller.
  local savedFacing = block.restoreFacing
  local savedPolicy = util.copy(nav.policy)

  callStack[#callStack + 1] = name
  job.push(name)

  local ok, err = pcall(chunk)

  local inner = job.pop()
  table.remove(callStack)
  block.restoreFacing = savedFacing
  nav.policy = savedPolicy

  if not ok then
    job.rethrowAbort(err)
    error(("routine '%s' failed: %s"):format(name, tostring(err)), 0)
  end

  job.checkAbort()
  return inner
end

--- Introspection available to a running program. Two manifest lines total,
--- regardless of library size. Note this cannot inform code *generation* --
--- the program is already written by the time it runs -- so it is for
--- defensive checks ("is the restock routine available?"), not discovery.
function lib.list()
  local out = {}
  for _, name in ipairs(lib.names()) do
    local st = lib.state(name)
    if st and st.registered then
      out[#out + 1] = { name = name, doc = st.doc, frame = st.frame,
                        listed = st.listed }
    end
  end
  return out
end

function lib.doc(name)
  local c = lib.contract(name)
  if not c then return nil end
  return contract.describe(c)
end

function lib.has(name)
  local st = lib.state(name)
  return st ~= nil and st.registered == true
end

--------------------------------------------------------------- manifest ---

--- The library index for the cached system prompt. Only `listed` routines.
--- This belongs in the CACHED prefix, not the per-request state line: it is
--- stable between registrations, so putting it in the live state block
--- would mean paying full price for it on every single request forever.
function lib.manifest()
  local lines = {}
  for _, name in ipairs(lib.names()) do
    local st = lib.state(name)
    if st and st.registered and st.listed then
      local c = lib.contract(name)
      if c then lines[#lines + 1] = contract.manifestLine(c) end
    end
  end
  if #lines == 0 then return nil end
  table.insert(lines, 1,
    "lib  -- saved routines, already written and proven. Prefer these over\n" ..
    "        rewriting the same logic. Arguments are checked before the first\n" ..
    "        instruction runs, so a mismatch fails loudly rather than silently.")
  return table.concat(lines, "\n")
end

--- Cheap fingerprint of what is currently listed. The session compares this
--- to decide whether the cached prompt has to be rebuilt.
function lib.listingVersion()
  local parts = {}
  for _, name in ipairs(lib.names()) do
    local st = lib.state(name)
    if st and st.registered and st.listed then
      parts[#parts + 1] = name .. ":" .. tostring(st.doc)
    end
  end
  return table.concat(parts, "|")
end

function lib.invalidate()
  index, contracts, sources = nil, {}, {}
end

return lib
