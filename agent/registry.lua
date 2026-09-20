--[[ agent/registry.lua --------------------------------------------------
  The registry is what makes this a platform rather than a pile of scripts.

  Every callable the generated code is allowed to use is *declared* here
  with a one-line signature, a one-line description, and an optional
  capability requirement. From those declarations we produce:

    * the sandbox environment the script actually runs in, and
    * the API manifest embedded in the (cached) system prompt.

  Those two always agree, by construction. Adding a capability -- your own
  farming module, an Advanced Peripherals scanner, a rednet fleet command --
  is one `registry.declare` call away, and Claude learns about it on the
  next request without anyone editing a prompt.

  Declaration fields:
    ns       namespace the function is reached through  ("nav")
    fn       function name                              ("moveTo")
    sig      signature, terse                           ("(pos, opts?) -> ok, err")
    doc      one line, imperative, no fluff
    requires capability flag from agent/caps (optional)
    tags     list of strings for selective manifests (optional)
    hidden   true to expose but not advertise (optional)
--------------------------------------------------------------------------]]

local util = require("agent.util")
local caps = require("agent.caps")

local registry = {}

local namespaces = {}   -- name -> { table = <lua table>, doc = "", order = n }
local decls      = {}   -- list of declarations in insertion order

function registry.namespace(name, tbl, doc)
  namespaces[name] = { table = tbl, doc = doc or "", order = util.count(namespaces) }
  return tbl
end

function registry.declare(d)
  assert(d.ns and d.fn, "declaration needs ns and fn")
  decls[#decls + 1] = d
  return d
end

--- Declare a whole namespace at once from a compact list.
function registry.declareAll(ns, list)
  for _, d in ipairs(list) do
    d.ns = ns
    registry.declare(d)
  end
end

--- Register a brand-new capability module in one call. `tbl` is the Lua
--- table of functions, `list` the declarations for the ones you want
--- Claude to see.
function registry.add(name, tbl, doc, list)
  registry.namespace(name, tbl, doc)
  if list then registry.declareAll(name, list) end
  return tbl
end

function registry.namespaces() return namespaces end
function registry.declarations() return decls end

--------------------------------------------------------------------------

local function available(d)
  if not d.requires then return true end
  local reqs = type(d.requires) == "table" and d.requires or { d.requires }
  for _, r in ipairs(reqs) do
    if not caps.has(r) then return false end
  end
  return true
end

--- Build the sandbox namespace table. Functions whose capability is missing
--- are replaced by a stub that raises a clear error, so a script that tries
--- anyway fails with "this turtle has no crafting upgrade" rather than
--- "attempt to call a nil value".
---
--- The stub keeps the real function and re-checks before refusing: a
--- capability can appear mid-program (equipping a modem, or a crafting
--- table) and the script that just equipped it is right where this table
--- is stale. Without holding `real`, replacing the entry here would also
--- destroy the function for the rest of the session -- these are the live
--- module tables, not copies, which is deliberate: a script is allowed to
--- set fields like job.abortFlag through them.
function registry.environment()
  local env = {}
  for name, ns in pairs(namespaces) do
    env[name] = ns.table
  end
  for _, d in ipairs(decls) do
    if not available(d) then
      local ns = env[d.ns]
      if ns then
        local missing = type(d.requires) == "table" and table.concat(d.requires, "+")
                        or tostring(d.requires)
        local fnName = d.fn
        local real = ns[fnName]
        ns[fnName] = function(...)
          if available(d) and type(real) == "function" then return real(...) end
          error(("%s.%s needs '%s', which this machine does not have")
                :format(d.ns, fnName, missing), 2)
        end
      end
    end
  end
  return env
end

--- The manifest string embedded in the system prompt.
--- `opts.tags` restricts to declarations carrying any of those tags.
--- `opts.all` includes capability-gated entries that are unavailable
--- (useful for documentation, never for the live prompt).
function registry.manifest(opts)
  opts = opts or {}
  local byNS, order = {}, {}
  for _, d in ipairs(decls) do
    local keep = (opts.all or available(d)) and not d.hidden
    if keep and opts.tags then
      keep = false
      for _, t in ipairs(d.tags or {}) do
        if util.contains(opts.tags, t) then keep = true; break end
      end
    end
    if keep then
      if not byNS[d.ns] then byNS[d.ns] = {}; order[#order + 1] = d.ns end
      table.insert(byNS[d.ns], d)
    end
  end
  table.sort(order, function(a, b)
    return (namespaces[a] and namespaces[a].order or 99)
         < (namespaces[b] and namespaces[b].order or 99)
  end)

  local out = {}
  for _, ns in ipairs(order) do
    local header = ns
    local nsDoc = namespaces[ns] and namespaces[ns].doc
    if nsDoc and nsDoc ~= "" then header = header .. "  -- " .. nsDoc end
    out[#out + 1] = header
    for _, d in ipairs(byNS[ns]) do
      local line = ("  %s.%s%s"):format(ns, d.fn, d.sig or "()")
      if d.doc then
        local pad = math.max(1, 44 - #line)
        line = line .. string.rep(" ", pad) .. "-- " .. d.doc
      end
      out[#out + 1] = line
    end
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

--- Rough token estimate so the operator can see what the manifest costs.
function registry.manifestCost()
  local m = registry.manifest()
  return math.ceil(#m / 3.6), #m
end

return registry
