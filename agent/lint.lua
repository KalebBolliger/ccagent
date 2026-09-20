--[[ agent/lint.lua -----------------------------------------------------
  Static checks on a generated program, used at registration time.

  What this can and cannot do, stated plainly because the difference is the
  whole safety story:

  A NOTE ON WHAT THIS IS FOR, because it is easy to overstate.

  A routine that captures nav.pos() and works outward from it is CORRECT.
  Called from a new position it does the relative thing at the new position,
  which is exactly what "relative" means. That is not a bug and this file
  does not treat it as one. The same goes for a routine built on fixed
  coordinates: it does the same thing from anywhere, unambiguously.

  So the lint reports two genuinely different things:

  ERRORS -- the declaration contradicts the source. Declaring "I do not
    depend on position" while anchoring to one is a false statement about
    the code, and a false statement is worth refusing. So is a reference to
    a name that does not exist in the sandbox, which will simply crash.

  WARNINGS -- style and reach. Anchoring to nav.pos() instead of
    args.origin costs a caller the ability to aim the routine somewhere
    else without physically moving the turtle first. Worth saying; not
    worth refusing.

  What the lint CANNOT see at all is semantic preconditions -- "assumes a
  chest behind me", "assumes a pickaxe rather than a hoe", "assumes a stack
  of cobble". Those are what the contract's `needs:` field is for, and they
  are where the real silent failures live: a turtle holding a hoe will move,
  dig nothing, and report success-shaped output.

  Lua gives no AST access, so the anchor check is a heuristic: a local bound
  from nav.pos() that later feeds a position-consuming call. It will miss a
  position captured deep inside a loop and assigned indirectly. That is the
  known hole, and it is why registration is an explicit operator action
  rather than something that happens automatically.
--------------------------------------------------------------------------]]

local util = require("agent.util")

local lint = {}

local KEYWORDS = {
  ["and"]=1,["break"]=1,["do"]=1,["else"]=1,["elseif"]=1,["end"]=1,
  ["false"]=1,["for"]=1,["function"]=1,["goto"]=1,["if"]=1,["in"]=1,
  ["local"]=1,["nil"]=1,["not"]=1,["or"]=1,["repeat"]=1,["return"]=1,
  ["then"]=1,["true"]=1,["until"]=1,["while"]=1,["self"]=1,
}

local MOVEMENT = {
  "nav%.moveTo", "nav%.moveBy", "nav%.step", "nav%.forward", "nav%.back",
  "nav%.up", "nav%.down", "nav%.goHome", "nav%.follow",
  "block%.fill", "block%.clear", "block%.digVein", "lib%.run",
}

local POSITION_CONSUMERS = {
  "nav%.moveTo", "nav%.findPath", "nav%.distanceTo", "nav%.faceToward",
  "block%.fill", "block%.clear",
  "geom%.add", "geom%.sub", "geom%.eq", "geom%.manhattan", "geom%.iterBox",
  "geom%.inBox", "world%.get", "world%.set", "world%.isSolid",
}

--------------------------------------------------------------- scanning ---

--- Replace every string literal and comment with spaces of equal length, so
--- offsets still line up but their contents cannot produce false matches.
--- Doing this first is what keeps `job.say("go forward")` from being read
--- as a movement instruction.
function lint.strip(src)
  local out, i, n = {}, 1, #src
  local function blank(len) return string.rep(" ", len) end
  while i <= n do
    local c = src:sub(i, i)
    local two = src:sub(i, i + 1)

    if two == "--" then
      local lvl = src:match("^%-%-(%[=*%[)", i)
      if lvl then
        local close = "]" .. lvl:sub(2, -2) .. "]"
        local s, e = src:find(close, i, true)
        e = e or n
        out[#out + 1] = blank(e - i + 1); i = e + 1
      else
        local e = src:find("\n", i) or (n + 1)
        out[#out + 1] = blank(e - i); i = e
      end

    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c then break
        elseif d == "\n" then break
        else j = j + 1 end
      end
      out[#out + 1] = blank(math.min(j, n) - i + 1); i = j + 1

    elseif c == "[" then
      local lvl = src:match("^(%[=*%[)", i)
      if lvl then
        local close = "]" .. lvl:sub(2, -2) .. "]"
        local s, e = src:find(close, i, true)
        e = e or n
        out[#out + 1] = blank(e - i + 1); i = e + 1
      else
        out[#out + 1] = c; i = i + 1
      end

    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return table.concat(out)
end

--- Every name bound locally: `local a, b`, loop variables, function params.
function lint.locals(code)
  local set = {}
  local function addList(list)
    for name in tostring(list):gmatch("[%a_][%w_]*") do set[name] = true end
  end
  for list in code:gmatch("local%s+function%s+([%a_][%w_]*)") do addList(list) end
  for list in code:gmatch("local%s+([%w_%s,]+)") do addList(list) end
  for list in code:gmatch("for%s+([%w_%s,]+)%s*=") do addList(list) end
  for list in code:gmatch("for%s+([%w_%s,]+)%s+in%s") do addList(list) end
  for params in code:gmatch("function%s*[%w_%.:]*%s*%(([^%)]*)%)") do addList(params) end
  return set
end

--- Identifiers used as globals (not preceded by `.` or `:`).
function lint.globals(code)
  local locals = lint.locals(code)
  local seen = {}
  local pos = 1
  while true do
    local s, e, name = code:find("([%a_][%w_]*)", pos)
    if not s then break end
    pos = e + 1
    local prev = s > 1 and code:sub(s - 1, s - 1) or ""
    -- `x` in `{x = 4}` is a table key, and `foo` in `foo = 1` is an
    -- assignment target, not a read of an undefined global. Neither can
    -- fail at runtime, so neither is a finding.
    local nextTwo = code:sub(e + 1):match("^%s*(==?)") or ""
    local isBindingTarget = nextTwo == "="
    if prev ~= "." and prev ~= ":" and not KEYWORDS[name]
       and not locals[name] and not isBindingTarget then
      seen[name] = (seen[name] or 0) + 1
    end
  end
  return seen
end

------------------------------------------------------------------ check ---

local function firstMatch(code, patterns)
  local best = nil
  for _, p in ipairs(patterns) do
    local s = code:find(p)
    if s and (not best or s < best) then best = s end
  end
  return best
end

local function lineOf(code, index)
  if not index then return nil end
  local _, n = code:sub(1, index):gsub("\n", "")
  return n + 1
end

--- Run every check. Returns a list of findings:
---   { kind, line, detail }
--- `allowed` is the set of names legitimately in the sandbox (pass
--- registry.environment() keys plus the standard-library names).
function lint.check(src, allowed)
  allowed = allowed or {}
  local code = lint.strip(src)
  local findings = {}
  local function add(kind, index, detail)
    findings[#findings + 1] = { kind = kind, line = lineOf(code, index),
                                detail = detail }
  end

  -- 1. Ambient anchoring: a local bound from nav.pos()/nav.facing() that
  --    later feeds a position-consuming call.
  local firstMove = firstMatch(code, MOVEMENT)
  local pos = 1
  while true do
    local s, e, name, call = code:find("local%s+([%a_][%w_]*)%s*=%s*nav%.(pos)%s*%(", pos)
    if not s then
      s, e, name, call = code:find("local%s+([%a_][%w_]*)%s*=%s*nav%.(facing)%s*%(", pos)
    end
    if not s then break end
    pos = e + 1

    local usedAsPosition = false
    for _, consumer in ipairs(POSITION_CONSUMERS) do
      if code:find(consumer .. "%s*%(%s*" .. name .. "%f[%W]") then
        usedAsPosition = true; break
      end
      if code:find(consumer .. "%s*%([^%)]-,%s*" .. name .. "%f[%W]") then
        usedAsPosition = true; break
      end
    end
    local capturedEarly = (not firstMove) or s < firstMove
    if usedAsPosition and capturedEarly then
      add("ambient-anchor", s,
          ("'%s' is the turtle's own position at start-up, and the program " ..
           "anchors to it"):format(name))
    end
  end

  -- 2. Hardcoded world coordinates.
  --    A literal {x=,y=,z=} is syntactically identical whether it is a world
  --    position or a relative offset -- {x=4,y=-16,z=4} could be either. The
  --    only available signal is context: an offset is what you hand to
  --    geom.add/sub/v, a position is what you hand to nav.moveTo. So a
  --    literal inside a geom call is not reported. A literal assigned to a
  --    local and then passed to geom.add is missed; that is the known limit.
  local p2 = 1
  while true do
    local s, e = code:find("{%s*x%s*=%s*%-?%d+%s*,", p2)
    if not s then break end
    p2 = e + 1
    local before = code:sub(math.max(1, s - 48), s - 1)
    local isOffset = before:match("geom%.add%s*%([^%)]*$")
                  or before:match("geom%.sub%s*%([^%)]*$")
                  or before:match("geom%.v%s*%([^%)]*$")
                  or before:match("geom%.iterBox%s*%([^%)]*$")
    if not isOffset then
      add("absolute-coords", s, "a literal world coordinate appears in the source")
    end
  end

  -- 3. Facing-relative direction words.
  --    Strings were blanked in step 0, so look at the original source for
  --    these -- but only where they are the argument to a direction-taking
  --    call, which keeps prose in job.say() out of it.
  for _, fn in ipairs({ "nav%.step", "nav%.face", "block%.inspect", "block%.detect",
                        "block%.dig", "block%.place", "block%.is", "block%.attack",
                        "block%.drop", "block%.suck" }) do
    local p3 = 1
    while true do
      local s, e, word = src:find(fn .. "%s*%(%s*[\"']([%a]+)[\"']", p3)
      if not s then break end
      p3 = e + 1
      if word == "forward" or word == "back" or word == "left" or word == "right" then
        add("relative-facing", s,
            ("'%s' depends on which way the turtle is facing when called")
              :format(word))
      end
    end
  end

  -- 4. Library calls, for cycle awareness.
  local p4 = 1
  while true do
    local s, e, name = src:find("lib%.run%s*%(%s*[\"']([%w_%-]+)[\"']", p4)
    if not s then break end
    p4 = e + 1
    add("calls-library", s, name)
  end

  -- 5. Globals that will not exist in the sandbox.
  for name, count in pairs(lint.globals(code)) do
    if not allowed[name] then
      add("undefined-global", code:find("%f[%w_]" .. name .. "%f[%W]"),
          ("'%s' is not in the sandbox (used %d time%s)")
            :format(name, count, count == 1 and "" or "s"))
    end
  end

  table.sort(findings, function(a, b) return (a.line or 0) < (b.line or 0) end)
  return findings
end

function lint.has(findings, kind)
  for _, f in ipairs(findings) do if f.kind == kind then return f end end
  return nil
end

------------------------------------------------------------ consistency ---

--- Does the declaration survive contact with the source?
--- Returns errors, warnings (both lists of strings). A non-empty `errors`
--- means the program saves but does NOT register.
function lint.consistency(c, findings)
  local errors, warnings = {}, {}

  local undef = lint.has(findings, "undefined-global")
  if undef then
    for _, f in ipairs(findings) do
      if f.kind == "undefined-global" then
        errors[#errors + 1] = ("line %s: %s"):format(tostring(f.line), f.detail)
      end
    end
  end

  local anchor   = lint.has(findings, "ambient-anchor")
  local absolute = lint.has(findings, "absolute-coords")
  local relDir   = lint.has(findings, "relative-facing")

  if c.frame == "anywhere" then
    if anchor then
      errors[#errors + 1] =
        "declares frame: anywhere but anchors to the turtle's start position" ..
        " (line " .. tostring(anchor.line) .. ") -- this should be frame: relative"
    end
    if absolute then
      errors[#errors + 1] =
        "declares frame: anywhere but contains a literal world coordinate" ..
        " (line " .. tostring(absolute.line) .. ") -- this should be frame: absolute"
    end
  elseif c.frame == "absolute" then
    if anchor then
      errors[#errors + 1] =
        "declares frame: absolute but anchors to wherever the turtle happens" ..
        " to be (line " .. tostring(anchor.line) .. ")"
    end
  elseif c.frame == "relative" then
    if anchor then
      -- NOT an error. A routine that captures nav.pos() and works outward
      -- from it is a *correct* expression of "relative to me", and calling
      -- it from a new position does the relative thing at the new position,
      -- which is the whole point. The only thing lost is targetability: a
      -- caller who wants the work done somewhere else has to physically
      -- move the turtle there first, instead of passing an origin.
      warnings[#warnings + 1] =
        "anchors to nav.pos() (line " .. tostring(anchor.line) ..
        ") -- correct, but callers cannot aim it. Anchoring to args.origin" ..
        " (which lib.run defaults to nav.pos()) keeps this behaviour and" ..
        " lets a caller target a different spot"
    end
    if absolute then
      warnings[#warnings + 1] =
        "frame: relative but contains a literal world coordinate (line " ..
        tostring(absolute.line) .. ") -- fine if it is a fixed landmark"
    end
  end

  if relDir and c.frame ~= "relative" then
    warnings[#warnings + 1] =
      "uses facing-relative direction words (line " .. tostring(relDir.line) ..
      ") -- behaviour depends on the caller's heading; consider compass words"
  end

  return errors, warnings
end

--- Human-readable findings, and the same text fed to the model when a
--- retrofit registration asks it to parameterise an existing program.
function lint.report(findings)
  if #findings == 0 then return "no findings" end
  local out = {}
  for _, f in ipairs(findings) do
    out[#out + 1] = ("  line %-4s %-17s %s")
      :format(tostring(f.line or "?"), f.kind, f.detail or "")
  end
  return table.concat(out, "\n")
end

return lint
