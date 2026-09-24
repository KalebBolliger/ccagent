--[[ ui/share.lua ---------------------------------------------------------
  Get a failure off the turtle and somewhere it can be read.

  A CC terminal is 39x13 with no scrollback, so the moment a program
  misbehaves the useful evidence -- the generated source, the output
  before the error, what the turtle believed about the world -- has
  already scrolled past and cannot be recovered. Debugging by
  transcribing a screen is slow and lossy, and it loses exactly the
  detail that decides between two explanations.

  So: bundle it and POST it somewhere, print the short url the sink
  answers with, and read it from anywhere. The turtle already has http --
  it is talking to the Messages API -- and it already keeps a log.

  No sink is built in. Any service that takes a POST body and answers
  with a url works (`paste.rs` and `0x0.st` both do); picking one for
  somebody is picking who gets their coordinates.
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

--- Refuse to publish anything carrying the key. The bundle is not built
--- from config, so this should never fire -- which is exactly why it is
--- cheap to keep: the day someone adds the config dump to it, this is
--- what stops an api key reaching a public paste.
function share.carriesSecret(text, secret)
  if not secret or secret == "" then return false end
  return text:find(secret, 1, true) ~= nil
end

--- POST the bundle. Returns the sink's answer (a url, for the services
--- worth using) or nil, err.
---
--- Blocking http.post rather than the async dance in claude/client.lua:
--- a few kilobytes to a paste service returns quickly, and there is no
--- spinner to keep alive or generation to abort.
function share.post(url, text, headers)
  if not _G.http then return nil, "the http API is disabled in this world" end
  if not url or url == "" then return nil, "no sink configured" end
  local res, err, errRes = http.post(url, text, headers)
  if not res then
    local detail = err or "request failed"
    if errRes then
      local body = errRes.readAll and errRes.readAll() or nil
      if errRes.close then errRes.close() end
      if body and body ~= "" then detail = detail .. ": " .. util.clip(body, 120) end
    end
    return nil, detail
  end
  local body = res.readAll and res.readAll() or ""
  if res.close then res.close() end
  body = util.trim(body or "")
  if body == "" then return nil, "the sink answered with nothing" end
  return body
end

return share
