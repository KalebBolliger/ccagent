--[[ claude/client.lua ---------------------------------------------------
  Minimal Anthropic Messages API client for CC:Tweaked.

  Asynchronous on purpose: `http.post` blocks the whole computer, which
  means no spinner, no way to cancel, and no timeout you control. We use
  http.request plus the event loop instead, so the controller can draw a
  "thinking..." line and honour a keypress while the request is in flight.

  Streaming is on by default, and not for the usual reason. CC:Tweaked
  puts a Netty ReadTimeoutHandler on every request: 30s by default, 60s
  maximum, settable per request as the `timeout` field of the http.request
  options table. It measures *silence*, not elapsed time. A non-streaming
  Messages call sends no bytes at all until the whole reply is generated,
  so any job whose program takes longer than that to write is killed
  mid-generation and comes back as `http_failure` with CC's own message,
  "Timed out". Streaming keeps deltas and pings flowing, so the read
  timeout never fires however long the job takes. CC still buffers the
  whole body before it hands us a handle, so this costs no latency and
  gains no progress reporting -- it only stops the connection dying.

  Handles the things that actually bite in practice:
    * error bodies -- CC hands them back as a third return value that is
      easy to drop on the floor, and it is where the real message lives;
    * extended thinking -- responses come back as a content *array* whose
      first blocks may be `thinking`, not `text`;
    * rate limits and overloads -- 429 / 529 / 5xx get retried with backoff
      and honour Retry-After;
    * transport failures -- retried with backoff too, rather than three
      immediate re-sends of the same request.
--------------------------------------------------------------------------]]

local util = require("agent.util")

local client = {}

client.endpoint   = "https://api.anthropic.com/v1/messages"
client.apiVersion = "2023-06-01"
client.retries    = 3
client.stream     = true    -- see the note above; turning this off brings
                            -- the 30s generation ceiling back

-- Our own ceiling on one attempt, enforced with os.startTimer. It exists
-- so a wedged request cannot hang the turtle forever, not to bound
-- generation: a guess, generous on purpose.
client.timeout    = 180

-- What we ask CC to use for *its* read timeout. 60 is its maximum; builds
-- too old to know the field fall back to 30, which streaming makes
-- survivable anyway.
client.readTimeout = 60

local function encode(t)
  local fn = textutils and (textutils.serialiseJSON or textutils.serializeJSON)
  if not fn then error("this CC:Tweaked build has no JSON encoder", 0) end
  return fn(t)
end

local function decode(s)
  local fn = textutils and (textutils.unserialiseJSON or textutils.unserializeJSON)
  if not fn then error("this CC:Tweaked build has no JSON decoder", 0) end
  local ok, v = pcall(fn, s)
  if ok then return v end
  return nil
end

--------------------------------------------------------------- transport --

--- Clamp to the range CC:Tweaked will accept for its read timeout. Out of
--- range is an error from http.request, not a warning, so this is not
--- cosmetic.
local function readWindow(n)
  n = tonumber(n) or client.readTimeout
  if n < 1 then n = 1 end
  if n > 60 then n = 60 end
  return n
end

--- One HTTP attempt. Returns status, bodyString, headers.
---   opts { timeout = our ceiling, readTimeout = CC's silence window }
local function attempt(url, body, headers, opts)
  if not _G.http then return nil, "the http API is disabled in this world" end
  opts = opts or {}
  local timeout = opts.timeout or client.timeout
  local window  = readWindow(opts.readTimeout)

  -- `timeout` here is CC's, in seconds, and it is the one that actually
  -- kills long generations. Builds that predate the field ignore it.
  http.request({ url = url, body = body, headers = headers, method = "POST",
                 timeout = window })

  local timer = os.startTimer(timeout)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "http_success" and a == url then
      local handle = b
      local status = handle.getResponseCode and handle.getResponseCode() or 200
      local hdrs   = handle.getResponseHeaders and handle.getResponseHeaders() or {}
      local text   = handle.readAll()
      handle.close()
      os.cancelTimer(timer)
      return status, text, hdrs
    elseif ev == "http_failure" and a == url then
      -- b is the message, c is a response handle when the server replied
      -- with an error status. That body is the useful part.
      local msg, handle = b, c
      if handle then
        local status = handle.getResponseCode and handle.getResponseCode() or 0
        local hdrs   = handle.getResponseHeaders and handle.getResponseHeaders() or {}
        local text   = handle.readAll()
        handle.close()
        os.cancelTimer(timer)
        return status, text, hdrs
      end
      os.cancelTimer(timer)
      msg = msg or "request failed"
      -- CC's own wording for its read timeout. Say what it means, since
      -- "Timed out" reads like our timer and sends people to the wrong knob.
      if tostring(msg):lower():find("timed out") then
        msg = ("no data for %ds -- the reply was cut off"):format(window)
      end
      return nil, msg
    elseif ev == "timer" and a == timer then
      return nil, ("gave up waiting after %ds"):format(timeout)
    elseif ev == "ccagent_abort" then
      os.cancelTimer(timer)
      return nil, "cancelled"
    end
  end
end

local function retryAfter(headers)
  if not headers then return nil end
  for k, v in pairs(headers) do
    if tostring(k):lower() == "retry-after" then return tonumber(v) end
  end
  return nil
end

-------------------------------------------------------------- streaming ---

--- Rebuild a Messages response from a server-sent-events body.
---
--- CC buffers the whole body before we ever see it, so this is not
--- incremental parsing -- it is undoing the streaming encoding to get back
--- the object the non-streaming endpoint would have returned. The one
--- extra thing it tells us is `truncated`: a body with no `message_stop`
--- is a reply that was cut off, which is worth saying out loud rather than
--- handing a half-written program to the syntax check.
---
--- Returns data, err. `data.truncated` is true when the stream did not end.
function client.unstream(text)
  local data = { content = {}, usage = {}, truncated = true }
  local byIndex, order = {}, {}

  for line in tostring(text or ""):gmatch("[^\n]+") do
    line = line:gsub("\r$", "")
    local payload = line:match("^data:%s*(.*)$")
    if payload and payload ~= "" and payload ~= "[DONE]" then
      local ev = decode(payload)
      local t = ev and ev.type
      if t == "error" then
        local e = ev.error or {}
        return nil, ("API error: %s"):format(e.message or e.type or "unknown")

      elseif t == "message_start" and ev.message then
        local m = ev.message
        data.id, data.model, data.role = m.id, m.model, m.role
        data.stop_reason = m.stop_reason
        for k, v in pairs(m.usage or {}) do data.usage[k] = v end

      elseif t == "content_block_start" then
        local b = {}
        for k, v in pairs(ev.content_block or {}) do b[k] = v end
        byIndex[ev.index or 0] = b
        order[#order + 1] = ev.index or 0

      elseif t == "content_block_delta" then
        local b = byIndex[ev.index or 0]
        if not b then
          b = { type = "text", text = "" }
          byIndex[ev.index or 0] = b
          order[#order + 1] = ev.index or 0
        end
        local d = ev.delta or {}
        if d.text then b.text = (b.text or "") .. d.text end
        if d.thinking then b.thinking = (b.thinking or "") .. d.thinking end
        if d.partial_json then
          b.partial_json = (b.partial_json or "") .. d.partial_json
        end
        if d.signature then b.signature = (b.signature or "") .. d.signature end

      elseif t == "message_delta" then
        if ev.delta and ev.delta.stop_reason then
          data.stop_reason = ev.delta.stop_reason
        end
        -- Output tokens only arrive here; input tokens only in message_start.
        for k, v in pairs(ev.usage or {}) do data.usage[k] = v end

      elseif t == "message_stop" then
        data.truncated = false
      end
    end
  end

  for _, idx in ipairs(order) do
    data.content[#data.content + 1] = byIndex[idx]
  end
  if #data.content == 0 and data.truncated then
    return nil, "the reply was cut off before any content arrived"
  end
  return data
end

--------------------------------------------------------------- requests ---

--- Send a Messages request.
---   cfg   { apiKey, model, maxTokens, temperature, thinking = {budget} }
---   body  { system = <string|array>, messages = {...}, tools = ... }
--- Returns a table {text, blocks, usage, stop, raw} or nil, err.
function client.message(cfg, body)
  assert(cfg and cfg.apiKey and cfg.apiKey ~= "", "no API key configured")

  local payload = {
    model       = cfg.model or "claude-sonnet-5",
    max_tokens  = cfg.maxTokens or 32000,
    messages    = body.messages,
  }
  if body.system then payload.system = body.system end
  if body.stop_sequences then payload.stop_sequences = body.stop_sequences end

  -- Thinking. The thing to know, because it is the opposite of what the
  -- old comment here assumed: current models think by DEFAULT. Omitting
  -- this parameter on Sonnet 5 or Opus 5 runs adaptive thinking, and
  -- those tokens come out of max_tokens before a single character of
  -- program is written. That is not a reason to switch it off -- it makes
  -- the programs better -- but it is the reason max_tokens has to be
  -- generous and why `effort` is the knob to reach for first.
  --
  --   cfg.thinking == nil          -> send nothing; the model decides
  --   cfg.thinking == false|"off"  -> {type = "disabled"}
  --   cfg.thinking == true|"adaptive" -> {type = "adaptive"}
  --   cfg.thinking == {budget = N} -> the pre-4.6 spelling, which current
  --                                   models reject with a 400. Only for
  --                                   an older model set in config.
  if cfg.thinking == false or cfg.thinking == "off" then
    payload.thinking = { type = "disabled" }
  elseif cfg.thinking == true or cfg.thinking == "adaptive" then
    payload.thinking = { type = "adaptive" }
  elseif type(cfg.thinking) == "table" and cfg.thinking.budget
         and cfg.thinking.budget > 0 then
    local budget = cfg.thinking.budget
    if payload.max_tokens <= budget then
      payload.max_tokens = budget + (cfg.thinkingHeadroom or 2048)
    end
    payload.thinking = { type = "enabled", budget_tokens = budget }
  end

  -- How hard to think, and so how much of max_tokens thinking may eat.
  -- Cheaper and more direct than trying to switch thinking off.
  if cfg.effort then
    payload.output_config = { effort = cfg.effort }
  end

  -- temperature is rejected outright by current models, and cannot be
  -- combined with a thinking budget on older ones. Only send it if the
  -- operator asked for it on a model old enough to take it.
  if cfg.temperature and not payload.thinking then
    payload.temperature = cfg.temperature
  end

  local streaming = (cfg.stream ~= false) and (client.stream ~= false)
  if streaming then payload.stream = true end

  local headers = {
    ["x-api-key"]         = cfg.apiKey,
    ["anthropic-version"] = client.apiVersion,
    ["content-type"]      = "application/json",
    ["accept"]            = streaming and "text/event-stream" or "application/json",
  }
  if cfg.beta then headers["anthropic-beta"] = cfg.beta end

  local json = encode(payload)
  local lastErr

  local tries = cfg.retries or client.retries
  for tryN = 1, tries do
    local status, text, hdrs = attempt(client.endpoint, json, headers, {
      timeout     = cfg.timeout or client.timeout,
      readTimeout = cfg.readTimeout or client.readTimeout,
    })

    if status == nil then
      lastErr = text
      if lastErr == "cancelled" then return nil, lastErr end
      -- A transport failure used to re-send immediately, three times, which
      -- turns one bad minute into three and helps nothing.
      if tryN < tries then
        local wait = math.min(2 ^ tryN, 30)
        util.log.warn("request failed (%s); retrying in %ss",
                      tostring(lastErr), tostring(wait))
        util.sleep(wait)
      end
    elseif status >= 200 and status < 300 then
      local data, derr
      if streaming then
        data, derr = client.unstream(text)
        if not data then return nil, derr end
      else
        data = decode(text)
      end
      if not data then return nil, "could not parse API response" end
      local out, perr = client.parse(data)
      if not out and data.truncated then
        return nil, "the reply was cut off mid-program -- try a smaller job"
      end
      if out and data.truncated then out.truncated = true end
      return out, perr
    else
      local data = decode(text or "")
      local msg = data and data.error and data.error.message
                  or ("HTTP " .. tostring(status))
      lastErr = ("HTTP %s: %s"):format(tostring(status), msg)

      -- 400/401/403/404 will not get better by trying again.
      if status == 401 or status == 403 then
        return nil, lastErr .. "  (key: /.ccagent/key)"
      end
      if status >= 400 and status < 500 and status ~= 429 then
        return nil, lastErr
      end
      local wait = retryAfter(hdrs) or (2 ^ tryN)
      util.log.warn("api %s; retrying in %ss", tostring(status), tostring(wait))
      util.sleep(math.min(wait, 30))
    end
  end

  return nil, lastErr or "request failed"
end

--- Pull the useful parts out of a Messages response, tolerating thinking,
--- redacted_thinking and tool_use blocks appearing before the text.
function client.parse(data)
  local out = {
    blocks   = data.content or {},
    stop     = data.stop_reason,
    usage    = data.usage or {},
    raw      = data,
    thinking = nil,
  }
  local texts, thoughts = {}, {}
  for _, b in ipairs(data.content or {}) do
    if b.type == "text" and b.text then
      texts[#texts + 1] = b.text
    elseif b.type == "thinking" and b.thinking then
      thoughts[#thoughts + 1] = b.thinking
    end
  end
  out.text = table.concat(texts, "\n")
  if #thoughts > 0 then out.thinking = table.concat(thoughts, "\n") end

  if out.text == "" and out.stop == "max_tokens" then
    -- Say what was actually in the response. Without the block types this
    -- reads as "the program was too long", when the usual cause is the
    -- opposite: thinking consumed the whole budget and the program was
    -- never started. Thinking blocks come back with empty text by
    -- default, so they are invisible unless named.
    local kinds = {}
    for _, b in ipairs(data.content or {}) do
      kinds[#kinds + 1] = tostring(b.type or "?")
    end
    return nil, ("max_tokens with no text (%d out, blocks: %s) -- raise "
              .. "maxTokens in /ccagent/config.lua, or lower effort")
              :format(out.usage.output_tokens or 0,
                      #kinds > 0 and table.concat(kinds, ",") or "none")
  end
  if out.text == "" then
    return nil, "model returned no text (stop_reason: "
             .. tostring(out.stop) .. ")"
  end
  return out
end

--- What this build will actually do on the wire, for `/doctor`. Exists
--- because the failure mode it diagnoses is "the turtle is running older
--- code than you think", and every other symptom of that is ambiguous.
function client.settings(cfg)
  cfg = cfg or {}
  local streaming = (cfg.stream ~= false) and (client.stream ~= false)
  return {
    stream      = streaming,
    timeout     = cfg.timeout or client.timeout,
    readTimeout = readWindow(cfg.readTimeout or client.readTimeout),
    retries     = cfg.retries or client.retries,
    model       = cfg.model or "claude-sonnet-5",
    maxTokens   = cfg.maxTokens or 32000,
    effort      = cfg.effort or "(model default)",
    -- nil here means "the model decides", which on current models means
    -- thinking is on. Reported as such, because "not configured" and
    -- "off" are not the same thing and the difference is what broke.
    thinking    = (cfg.thinking == false or cfg.thinking == "off")
                  and "off" or "on",
  }
end

--- One cheap round trip, to prove the transport end to end.
--- Returns seconds, nil on success, or nil, err.
function client.ping(cfg)
  local started = os.clock()
  local resp, err = client.message({
    apiKey = cfg.apiKey, model = cfg.model, maxTokens = 16,
    stream = cfg.stream, timeout = cfg.timeout,
    readTimeout = cfg.readTimeout, retries = 1,
  }, { messages = { { role = "user", content = "Reply with the word ok." } } })
  if not resp then return nil, err end
  return os.clock() - started
end

--- Cost line for the status bar. Cache reads are the number to watch: if
--- this stays near zero across turns, the system prompt is not being
--- cached and every request is paying full price for the manifest.
function client.usageLine(usage)
  if not usage then return "" end
  return ("in %d  out %d  cache write %d  cache read %d"):format(
    usage.input_tokens or 0,
    usage.output_tokens or 0,
    usage.cache_creation_input_tokens or 0,
    usage.cache_read_input_tokens or 0)
end

return client
