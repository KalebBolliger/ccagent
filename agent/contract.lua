--[[ agent/contract.lua -------------------------------------------------
  Parses and validates the @ccagent header that makes a saved program
  callable by Claude.

      --[=[ @ccagent
      name:    quarry
      doc:     excavate a box downward from the caller's position
      frame:   relative
      args:    width:number=5, depth:number=16
      needs:   caps=digging, item=*_pickaxe, fuel=200
      returns: number of blocks dug
      ]=]

  The header is written by Claude during the original generation, when the
  operator asked for something reusable -- not reconstructed later from the
  source. The model that wrote the program knows what it meant; a model
  reading it back is guessing.

  Presence of a header is not registration. It is the trigger for a check:
  parse, validate, lint, and confirm the declaration does not contradict
  what the source actually does. A header claiming `frame: anywhere` on a
  program that anchors to nav.pos() is exactly the landmine this exists to
  stop, so it fails here rather than three weeks later in a stone wall.
--------------------------------------------------------------------------]]

local util = require("agent.util")

local contract = {}

contract.FRAMES = { relative = true, absolute = true, anywhere = true }
contract.TYPES  = { number = true, string = true, boolean = true,
                    pos = true, table = true, any = true }

contract.MAX_DOC = 140   -- this string is sent on every cached prompt

------------------------------------------------------------------ parse ---

--- Pull the raw header text out of a source file. Tolerates any long
--- bracket level so the header itself can contain brackets.
function contract.extract(src)
  if not src then return nil end
  local open, body = src:match("%-%-(%[=*%[)%s*@ccagent%s*\r?\n(.-)%]=*%]")
  if not body then
    -- Also accept a line-comment block: -- @ccagent then -- key: value
    if src:match("^%s*%-%-%s*@ccagent") then
      local lines = {}
      for line in src:gmatch("[^\n]*") do
        local k = line:match("^%s*%-%-%s?(.*)$")
        if k == nil then break end
        if not k:match("^%s*@ccagent") then lines[#lines + 1] = k end
      end
      body = table.concat(lines, "\n")
    end
  end
  return body
end

local function parseArgs(text)
  local out = {}
  for piece in tostring(text):gmatch("[^,]+") do
    piece = util.trim(piece)
    if piece ~= "" then
      local name, typ, default = piece:match("^([%w_]+)%s*:%s*([%w_]+)%s*=%s*(.+)$")
      if not name then
        name, typ = piece:match("^([%w_]+)%s*:%s*([%w_]+)$")
      end
      if not name then
        name = piece:match("^([%w_]+)$")
        typ = "any"
      end
      if not name then return nil, "cannot parse argument '" .. piece .. "'" end
      if not contract.TYPES[typ] then
        return nil, ("argument '%s' has unknown type '%s'"):format(name, typ)
      end
      local d = default and util.trim(default) or nil
      if d then
        if d == "nil" then d = nil
        elseif d == "true" then d = true
        elseif d == "false" then d = false
        elseif tonumber(d) then d = tonumber(d)
        else d = (d:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")) end
      end
      out[#out + 1] = { name = name, type = typ, default = d,
                        required = default == nil }
    end
  end
  return out
end

local function parseNeeds(text)
  local out = {}
  for piece in tostring(text):gmatch("[^,]+") do
    piece = util.trim(piece)
    if piece ~= "" then
      local k, v = piece:match("^([%w_]+)%s*=%s*(.+)$")
      if not k then return nil, "cannot parse requirement '" .. piece .. "'" end
      v = util.trim(v)
      if k == "fuel" then
        out.fuel = v            -- may be a number or an expression over args
      elseif k == "caps" then
        out.caps = out.caps or {}
        table.insert(out.caps, v)
      elseif k == "item" then
        out.items = out.items or {}
        table.insert(out.items, v)
      elseif k == "gps" then
        out.gps = (v == "true" or v == "yes")
      else
        return nil, "unknown requirement '" .. k .. "'"
      end
    end
  end
  return out
end

--- Parse a header body into a contract table. Returns nil, err on a
--- malformed header -- which is a *failed registration*, not a failed save.
function contract.parse(src)
  local body = contract.extract(src)
  if not body then return nil, "no @ccagent header" end

  local raw = {}
  local key
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local k, v = line:match("^%s*([%w_]+)%s*:%s*(.*)$")
    if k then
      key = k:lower()
      raw[key] = util.trim(v)
    elseif key and util.trim(line) ~= "" then
      raw[key] = util.trim((raw[key] or "") .. " " .. util.trim(line))
    end
  end

  local c = { raw = raw }
  c.name = raw.name
  c.doc  = raw.doc
  c.frame = (raw.frame or "anywhere"):lower()
  c.returns = raw.returns

  if not c.name or c.name == "" then return nil, "header is missing 'name'" end
  if not c.name:match("^[%w_%-]+$") then
    return nil, "name must be alphanumeric/underscore/dash"
  end
  if not c.doc or c.doc == "" then return nil, "header is missing 'doc'" end
  if #c.doc > contract.MAX_DOC then
    return nil, ("doc is %d chars; keep it under %d (it rides in every prompt)")
      :format(#c.doc, contract.MAX_DOC)
  end
  if not contract.FRAMES[c.frame] then
    return nil, ("frame must be relative, absolute or anywhere (got '%s')")
      :format(c.frame)
  end

  if raw.args and raw.args ~= "" then
    local args, err = parseArgs(raw.args)
    if not args then return nil, err end
    c.args = args
  else
    c.args = {}
  end

  if raw.needs and raw.needs ~= "" then
    local needs, err = parseNeeds(raw.needs)
    if not needs then return nil, err end
    c.needs = needs
  else
    c.needs = {}
  end

  return c
end

--------------------------------------------------------------- checking ---

--- Coerce and validate a call's arguments against the contract. Returns a
--- filled args table, or nil, err.
function contract.bindArgs(c, given)
  given = given or {}
  local out = {}
  for k, v in pairs(given) do out[k] = v end
  for _, a in ipairs(c.args or {}) do
    local v = out[a.name]
    if v == nil then
      if a.required then
        return nil, ("missing required argument '%s' (%s)"):format(a.name, a.type)
      end
      v = a.default
    end
    if v ~= nil and a.type ~= "any" then
      local t = type(v)
      if a.type == "pos" then
        if t ~= "table" or v.x == nil or v.y == nil or v.z == nil then
          return nil, ("argument '%s' must be a position {x,y,z}"):format(a.name)
        end
      elseif a.type == "number" and t ~= "number" then
        local n = tonumber(v)
        if not n then
          return nil, ("argument '%s' must be a number"):format(a.name)
        end
        v = n
      elseif a.type ~= "pos" and a.type ~= "number" and t ~= a.type then
        return nil, ("argument '%s' must be a %s, got %s")
          :format(a.name, a.type, t)
      end
    end
    out[a.name] = v
  end
  return out
end

--- Check the machine actually satisfies `needs` before the first
--- instruction runs. This is the whole point of the contract: it turns a
--- silent wrong-behaviour into a thrown error the repair loop can read.
function contract.checkNeeds(c, args, deps)
  local caps, inv, nav = deps.caps, deps.inv, deps.nav
  local needs = c.needs or {}

  for _, flag in ipairs(needs.caps or {}) do
    if not caps.has(flag) then
      return false, ("needs capability '%s', which this machine lacks"):format(flag)
    end
  end

  for _, spec in ipairs(needs.items or {}) do
    local want, minCount = spec, 1
    local s, n = spec:match("^(.-)%s*x%s*(%d+)$")
    if s then want, minCount = s, tonumber(n) end
    if inv.count(want) < minCount then
      return false, ("needs %s (have %d)"):format(
        minCount > 1 and (want .. " x" .. minCount) or want, inv.count(want))
    end
  end

  if needs.gps and not caps.has("gps") then
    return false, "needs a GPS fix, which is not available here"
  end

  if needs.fuel then
    local want = tonumber(needs.fuel)
    if not want then
      -- An expression over args, e.g. "width*depth*2". Evaluated in a
      -- sandbox containing only the bound arguments and math.
      local env = { math = math }
      for k, v in pairs(args or {}) do env[k] = v end
      local fn = load("return " .. needs.fuel, "@needs", "t", env)
      if fn then
        local ok, v = pcall(fn)
        want = ok and tonumber(v) or nil
      end
    end
    if want and nav.fuel() < want then
      return false, ("needs %d fuel, has %s"):format(want, tostring(nav.fuel()))
    end
  end

  return true
end

--------------------------------------------------------------- rendering --

--- One line for the library index in the cached system prompt. This is the
--- per-program token cost, so it is kept tight.
function contract.signature(c)
  local parts = {}
  for _, a in ipairs(c.args or {}) do
    parts[#parts + 1] = a.required and a.name
                        or (a.name .. "?")
  end
  return ("lib.run('%s'%s)"):format(
    c.name,
    #parts > 0 and (", {" .. table.concat(parts, ", ") .. "}") or "")
end

function contract.manifestLine(c)
  local line = "  " .. contract.signature(c)
  local pad = math.max(1, 44 - #line)
  return line .. string.rep(" ", pad) .. "-- " .. c.doc
end

--- Full detail, for /jobs <name>.
function contract.describe(c)
  local out = { c.name .. " -- " .. c.doc, "  frame: " .. c.frame }
  if #(c.args or {}) > 0 then
    for _, a in ipairs(c.args) do
      out[#out + 1] = ("  arg %s: %s%s"):format(a.name, a.type,
        a.required and " (required)" or (" = " .. tostring(a.default)))
    end
  end
  local n = c.needs or {}
  for _, f in ipairs(n.caps or {})  do out[#out + 1] = "  needs cap " .. f end
  for _, i in ipairs(n.items or {}) do out[#out + 1] = "  needs item " .. i end
  if n.fuel then out[#out + 1] = "  needs fuel " .. tostring(n.fuel) end
  if c.returns then out[#out + 1] = "  returns " .. c.returns end
  return table.concat(out, "\n")
end

return contract
