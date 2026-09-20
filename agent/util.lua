--[[ agent/util.lua ------------------------------------------------------
  Small shared helpers. No CC APIs required beyond fs/textutils/os, so this
  file also loads under a plain Lua interpreter for testing.
--------------------------------------------------------------------------]]

local util = {}

util.unpack = table.unpack or unpack

---------------------------------------------------------------- tables ----

function util.copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = util.copy(v) end
  return o
end

function util.merge(base, over)
  local o = util.copy(base) or {}
  for k, v in pairs(over or {}) do
    if type(v) == "table" and type(o[k]) == "table" then
      o[k] = util.merge(o[k], v)
    else
      o[k] = v
    end
  end
  return o
end

function util.keys(t)
  local o = {}
  for k in pairs(t) do o[#o + 1] = k end
  table.sort(o, function(a, b) return tostring(a) < tostring(b) end)
  return o
end

function util.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function util.contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

---------------------------------------------------------------- strings ---

function util.trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

function util.startsWith(s, p) return s:sub(1, #p) == p end

--- Case-insensitive glob match. "*log*" matches "minecraft:oak_log".
function util.glob(s, pattern)
  s, pattern = s:lower(), pattern:lower()
  if not pattern:find("[%*%?]") then
    if s == pattern then return true end
    -- A bare name is shorthand for any namespace: "wheat" means
    -- "minecraft:wheat". Generated code writes the short form constantly
    -- -- it is how people say these names -- and an exact-match-only rule
    -- turns that into "no such item", which reads like an empty
    -- inventory rather than a spelling difference.
    if not pattern:find(":", 1, true) then
      return s:match("^[^:]*:(.+)$") == pattern
    end
    return false
  end
  local lua = pattern:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
                     :gsub("%*", ".*")
                     :gsub("%?", ".")
  return s:match("^" .. lua .. "$") ~= nil
end

function util.wrap(text, width)
  local out, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if #line == 0 then
      line = word
    elseif #line + #word + 1 <= width then
      line = line .. " " .. word
    else
      out[#out + 1] = line; line = word
    end
  end
  if #line > 0 then out[#out + 1] = line end
  return out
end

--- Truncate a long string from the middle; keeps head and tail context.
function util.clip(s, max)
  s = tostring(s)
  if #s <= max then return s end
  local half = math.floor((max - 5) / 2)
  return s:sub(1, half) .. "\n...\n" .. s:sub(-half)
end

----------------------------------------------------------------- errors ---

--- pcall that returns (ok, result, traceback-ish detail).
function util.try(fn, ...)
  local args = { ... }
  local ok, err = pcall(function() return fn(util.unpack(args)) end)
  return ok, err
end

--- Standard result convention used everywhere in this library:
---   ok(value)  -> true, value
---   fail(msg)  -> false, msg
function util.ok(v) return true, v end
function util.fail(msg, ...)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end
  return false, msg
end

------------------------------------------------------------------ time ----

function util.now()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.time() * 1000)
end

function util.sleep(n)
  if _G.sleep then _G.sleep(n) end
end

------------------------------------------------------------------- log ----

local LOG_LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

util.log = {
  level = "info",
  sink = nil,   -- optional function(level, text)
  file = nil,   -- optional path; appended to
}

local function emit(level, fmt, ...)
  if LOG_LEVELS[level] < LOG_LEVELS[util.log.level] then return end
  local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  if util.log.sink then util.log.sink(level, text) end
  if util.log.file and fs then
    local h = fs.open(util.log.file, "a")
    if h then h.writeLine(("[%s] %s"):format(level, text)); h.close() end
  end
  if not util.log.sink then print(("[" .. level .. "] ") .. text) end
end

function util.log.debug(...) emit("debug", ...) end
function util.log.info(...)  emit("info",  ...) end
function util.log.warn(...)  emit("warn",  ...) end
function util.log.error(...) emit("error", ...) end

------------------------------------------------------------------ files ---

function util.readFile(path)
  if not fs or not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local data = h.readAll()
  h.close()
  return data
end

function util.writeFile(path, data)
  if not fs then return false end
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(path, "w")
  if not h then return false end
  h.write(data)
  h.close()
  return true
end

function util.readJSON(path)
  local raw = util.readFile(path)
  if not raw then return nil end
  local decode = textutils and (textutils.unserialiseJSON or textutils.unserializeJSON)
  if not decode then return nil end
  local ok, val = pcall(decode, raw)
  if ok then return val end
  return nil
end

function util.writeJSON(path, tbl)
  local encode = textutils and (textutils.serialiseJSON or textutils.serializeJSON)
  if not encode then return false end
  return util.writeFile(path, encode(tbl))
end

return util
