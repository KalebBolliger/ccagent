--[[ ui/jobs.lua --------------------------------------------------------
  Operator-facing wrapper over the saved-program library.

  The store itself lives in agent/lib.lua, because a running program has to
  be able to call into it and agent/ may not depend on ui/. This file is the
  part the controllers talk to: the command implementations for save,
  register, expose, unregister and listing, including the retrofit path that
  promotes an existing one-off into a routine.
--------------------------------------------------------------------------]]

local util     = require("agent.util")
local lib      = require("agent.lib")
local contract = require("agent.contract")
local lint     = require("agent.lint")

local jobs = {}

jobs.lib = lib

------------------------------------------------------------------ basic ---

function jobs.save(name, code, meta) return lib.save(name, code, meta) end
function jobs.load(name)
  local src = lib.source(name)
  if not src then return nil, "no saved job called " .. tostring(name) end
  return src
end
function jobs.list()   return lib.names() end
function jobs.delete(name) return lib.delete(name) end

--- One row per saved program, with its three states.
function jobs.table()
  local out = {}
  for _, name in ipairs(lib.names()) do
    local st = lib.state(name) or {}
    out[#out + 1] = {
      name = name,
      registered = st.registered == true,
      listed = st.listed == true,
      doc = st.doc,
      frame = st.frame,
    }
  end
  return out
end

function jobs.row(e)
  local mark = e.registered and (e.listed and "[listed]" or "[reg]") or "[saved]"
  return ("  %-9s %-14s %s"):format(mark, e.name, e.doc or "")
end

----------------------------------------------------------- registration ---

--- Try to register. Returns a result table the caller renders:
---   { ok, errors, warnings, findings, contract, needsRetrofit }
--- `needsRetrofit` means there was no header at all, which is the signal to
--- offer the one-extra-call promotion rather than just reporting failure.
function jobs.register(name)
  local src = lib.source(name)
  if not src then
    return { ok = false, errors = { "no saved program called " .. name } }
  end
  if not contract.extract(src) then
    return { ok = false, needsRetrofit = true,
             errors = { name .. " has no @ccagent contract header" },
             findings = lint.check(src, lib.allowedNames()) }
  end
  local ok, errors, warnings, findings, c = lib.register(name)
  return { ok = ok, errors = errors or {}, warnings = warnings or {},
           findings = findings or {}, contract = c }
end

function jobs.unregister(name) return lib.unregister(name) end
function jobs.expose(name, on)  return lib.expose(name, on) end

--- Lint a program without registering it, for /check.
function jobs.check(name)
  local src = lib.source(name)
  if not src then return nil, "no saved program called " .. name end
  local findings = lint.check(src, lib.allowedNames())
  local c = contract.parse(src)
  local errors, warnings = {}, {}
  if c then errors, warnings = lint.consistency(c, findings) end
  return { findings = findings, contract = c, errors = errors, warnings = warnings }
end

--- Render a registration outcome for the terminal. `out` is a table of
--- console functions {head, warn, err, dim}.
function jobs.report(name, res, out)
  if res.ok then
    out.head(("registered %s -- %s"):format(name, res.contract.doc))
    out.dim("  " .. contract.signature(res.contract)
            .. "   frame: " .. res.contract.frame)
    for _, w in ipairs(res.warnings or {}) do out.warn(w) end
    out.dim("  listed in the prompt; /expose " .. name .. " off to keep it"
            .. " callable but unadvertised")
  else
    out.err("not registered: " .. (res.errors[1] or "?"))
    for i = 2, #(res.errors or {}) do out.err("  " .. res.errors[i]) end
    for _, w in ipairs(res.warnings or {}) do out.warn(w) end
    if res.findings and #res.findings > 0 then
      out.dim(lint.report(res.findings))
    end
    out.dim("the program is still saved and still /run-able")
  end
end

return jobs
