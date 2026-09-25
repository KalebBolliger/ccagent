--[[ ui/share.lua ---------------------------------------------------------
  Get a failure off the turtle and somewhere it can be read.

  A CC terminal is 39x13 with no scrollback, so the moment a program
  misbehaves the useful evidence -- the generated source, the output
  before the error, what the turtle believed about the world -- has
  already scrolled past. Transcribing a screen by hand is slow and drops
  exactly the detail that decides between two explanations.

  WHAT THIS ASSUMES ABOUT THE SINK: only what config describes.

  The request is described in config rather than written into this file,
  because the shape of "paste somewhere" varies more than it looks: some
  sinks want the raw body, some a multipart field, some answer with the
  link in the body, some in a header, some in a JSON key. All of those
  are expressible without editing code, so pointing this at a self-hosted
  sink is a config change, not a patch.

  A default ships (paste.rs) so the command works out of the box. Its
  server software reaps uploads after a configurable age, 30 days by
  default, which is a materially better position than a sink that keeps
  everything -- but it is the operator's setting rather than a promise,
  and there is no per-paste expiry parameter to request one with.

  WHAT IT ASSUMES ABOUT RETENTION: nothing.

  Treat anything posted as public and lasting. `redact` is the control
  that actually works, because it decides what leaves the turtle rather
  than what happens to it afterwards.
--------------------------------------------------------------------------]]

local util = require("agent.util")

local share = {}

share.logLines = 40      -- tail of /.ccagent/log.txt to include
share.maxChars = 16000   -- most sinks refuse much more, and nobody reads it

local function rule(title) return ("\n----- %s -----\n"):format(title) end

--- Last N lines of a file, or nil.
local function tailFile(path, n)
  if not fs or not path or not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local all = h.readAll() or ""
  h.close()
  local lines = {}
  for line in all:gmatch("[^\n]+") do lines[#lines + 1] = line end
  if #lines <= n then return table.concat(lines, "\n") end
  local out = {}
  for i = #lines - n + 1, #lines do out[#out + 1] = lines[i] end
  return table.concat(out, "\n")
end

--- Everything worth knowing about the last run, as one blob of text.
---   parts { version, settings, situation, request, code, result, log }
--- Every field is optional; a bundle of what is known beats none.
function share.bundle(parts)
  parts = parts or {}
  local out = {}
  out[#out + 1] = "ccagent report"
  if parts.version then out[#out + 1] = "version: " .. tostring(parts.version) end
  if parts.settings then out[#out + 1] = "settings: " .. tostring(parts.settings) end

  if parts.situation then
    out[#out + 1] = rule("state") .. tostring(parts.situation)
  end
  if parts.request and parts.request ~= "" then
    out[#out + 1] = rule("request") .. tostring(parts.request)
  end
  if parts.code then
    out[#out + 1] = rule("program") .. tostring(parts.code)
  end

  local r = parts.result
  if r then
    local head = r.ok and "ok" or ("failed: " .. tostring(r.error or "?"))
    if r.aborted then head = "aborted" end
    out[#out + 1] = rule("result") .. head
    if r.elapsed then out[#out + 1] = ("elapsed: %ss"):format(tostring(r.elapsed)) end
    if r.output and r.output ~= "" then
      out[#out + 1] = rule("output") .. tostring(r.output)
    end
  end

  if parts.log and parts.log ~= "" then
    out[#out + 1] = rule("log") .. tostring(parts.log)
  end

  local text = table.concat(out, "\n")
  if #text > share.maxChars then
    text = text:sub(1, share.maxChars) .. "\n[truncated]"
  end
  return text
end

--- Collect a bundle from the live session. Kept apart from bundle() so
--- the formatting can be tested without a turtle.
function share.gather(ctx)
  ctx = ctx or {}
  local sess = ctx.sess
  return share.bundle({
    version   = ctx.version,
    settings  = ctx.settings,
    situation = ctx.situation,
    request   = ctx.lastRequest,
    code      = sess and sess.lastCode,
    result    = sess and sess.lastResult,
    log       = tailFile(ctx.logFile, share.logLines),
  })
end

--- Scrub before sending, because nothing downstream can be taken back.
--- `patterns` is a list of Lua patterns; each match becomes [redacted].
--- Deliberately not clever: a rule the operator wrote and can read beats
--- a heuristic that decides on their behalf what counts as private.
function share.redact(text, patterns)
  if not patterns or #patterns == 0 then return text end
  for _, pat in ipairs(patterns) do
    local ok, out = pcall(string.gsub, text, pat, "[redacted]")
    if ok then text = out
    else util.log.warn("share: bad redact pattern %s", tostring(pat)) end
  end
  return text
end

--- Refuse to publish anything carrying the key. The bundle is not built
--- from config, so this should never fire -- which is exactly why it is
--- cheap to keep: the day someone adds the config dump to it, this is
--- what stops an api key reaching a sink that never forgets.
function share.carriesSecret(text, secret)
  if not secret or secret == "" then return false end
  return text:find(secret, 1, true) ~= nil
end

--------------------------------------------------------------- sending ---

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

--- Build the multipart body for a sink that wants a form field.
local function multipart(field, text, boundary)
  return table.concat({
    "--" .. boundary,
    ('Content-Disposition: form-data; name="%s"; filename="report.txt"')
      :format(field),
    "Content-Type: text/plain",
    "",
    text,
    "--" .. boundary .. "--",
    "",
  }, "\r\n")
end

--- Pull the link out of whatever the sink answered with.
---   "body"            the whole body is the link (trimmed)
---   "header:<name>"   a response header, e.g. header:location
---   "json:<key>"      a top-level key of a JSON object
function share.link(where, body, headers)
  where = where or "body"
  local kind, arg = where:match("^(%a+):(.+)$")
  if not kind then kind = where end

  if kind == "body" then return util.trim(body or "") end

  if kind == "header" then
    for k, v in pairs(headers or {}) do
      if tostring(k):lower() == arg:lower() then return util.trim(tostring(v)) end
    end
    return nil, ("the sink sent no %s header"):format(arg)
  end

  if kind == "json" then
    local fn = textutils and (textutils.unserialiseJSON or textutils.unserializeJSON)
    if not fn then return nil, "no JSON decoder" end
    local ok, data = pcall(fn, body or "")
    if not ok or type(data) ~= "table" then return nil, "the sink sent no JSON" end
    local v = data[arg]
    if v == nil then return nil, ("the sink's JSON has no %s"):format(arg) end
    return util.trim(tostring(v))
  end

  return nil, ("unknown link rule %s"):format(tostring(where))
end

--- Send a report to a configured sink.
---   dest {
---     url     = "https://...",          -- required
---     headers = { name = value },       -- merged over the default
---     field   = "file",                 -- send multipart under this name
---     params  = { expires = "1d" },     -- appended as a query string
---     link    = "body" | "header:location" | "json:<key>",
---     redact  = { "pattern", ... },
---   }
--- Returns the link, or nil, err.
---
--- Blocking http.post rather than the async dance in claude/client.lua: a
--- few kilobytes returns quickly, and there is no spinner to keep alive.
function share.send(dest, text)
  dest = dest or {}
  if not _G.http then return nil, "the http API is disabled in this world" end
  if not dest.url or dest.url == "" then return nil, "no sink configured" end

  text = share.redact(text, dest.redact)

  local url = dest.url
  if dest.params and next(dest.params) then
    local q = {}
    for k, v in pairs(dest.params) do
      q[#q + 1] = urlencode(k) .. "=" .. urlencode(v)
    end
    table.sort(q)
    url = url .. (url:find("?", 1, true) and "&" or "?") .. table.concat(q, "&")
  end

  local body, headers = text, { ["content-type"] = "text/plain" }
  if dest.field and dest.field ~= "" then
    local boundary = "ccagent" .. tostring(os.epoch and os.epoch("utc") or 0)
    body = multipart(dest.field, text, boundary)
    headers["content-type"] = "multipart/form-data; boundary=" .. boundary
  end
  for k, v in pairs(dest.headers or {}) do headers[k] = v end

  local res, err, errRes = http.post(url, body, headers)
  if not res then
    local detail = err or "request failed"
    if errRes then
      local b = errRes.readAll and errRes.readAll() or nil
      if errRes.close then errRes.close() end
      if b and b ~= "" then detail = detail .. ": " .. util.clip(b, 120) end
    end
    return nil, detail
  end

  local answer = res.readAll and res.readAll() or ""
  local hdrs = res.getResponseHeaders and res.getResponseHeaders() or {}
  if res.close then res.close() end

  local link, lerr = share.link(dest.link, answer, hdrs)
  if not link or link == "" then
    return nil, lerr or "the sink answered with nothing"
  end
  return link
end

return share
