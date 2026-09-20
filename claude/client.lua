--[[ claude/client.lua ---------------------------------------------------
  Minimal Anthropic Messages API client for CC:Tweaked.

  Asynchronous on purpose: `http.post` blocks the whole computer, which
  means no spinner, no way to cancel, and no timeout you control. We use
  http.request plus the event loop instead, so the controller can draw a
  "thinking..." line and honour a keypress while the request is in flight.

  Handles the three things that actually bite in practice:
    * error bodies -- CC hands them back as a third return value that is
      easy to drop on the floor, and it is where the real message lives;
    * extended thinking -- responses come back as a content *array* whose
      first blocks may be `thinking`, not `text`;
    * rate limits and overloads -- 429 / 529 / 5xx get retried with backoff
      and honour Retry-After.
--------------------------------------------------------------------------]]

local util = require("agent.util")

local client = {}

client.endpoint   = "https://api.anthropic.com/v1/messages"
client.apiVersion = "2023-06-01"
client.timeout    = 60      -- seconds per attempt
client.retries    = 3

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

--- One HTTP attempt. Returns status, bodyString, headers.
local function attempt(url, body, headers, timeout)
  if not _G.http then return nil, "the http API is disabled in this world" end

  http.request({ url = url, body = body, headers = headers, method = "POST" })

  local timer = os.startTimer(timeout or client.timeout)
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
      return nil, msg or "request failed"
    elseif ev == "timer" and a == timer then
      return nil, ("request timed out after %ds"):format(timeout or client.timeout)
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

--------------------------------------------------------------- requests ---

--- Send a Messages request.
---   cfg   { apiKey, model, maxTokens, temperature, thinking = {budget} }
---   body  { system = <string|array>, messages = {...}, tools = ... }
--- Returns a table {text, blocks, usage, stop, raw} or nil, err.
function client.message(cfg, body)
  assert(cfg and cfg.apiKey and cfg.apiKey ~= "", "no API key configured")

  local payload = {
    model       = cfg.model or "claude-sonnet-5",
    max_tokens  = cfg.maxTokens or 4096,
    messages    = body.messages,
  }
  if body.system then payload.system = body.system end
  if cfg.temperature and not (cfg.thinking and cfg.thinking.budget) then
    payload.temperature = cfg.temperature
  end
  if body.stop_sequences then payload.stop_sequences = body.stop_sequences end

  -- Extended thinking: the budget must be strictly less than max_tokens,
  -- and temperature must not be set alongside it. Getting either wrong is
  -- a 400 with a message that is easy to misread as a model-name problem.
  if cfg.thinking and cfg.thinking.budget and cfg.thinking.budget > 0 then
    local budget = cfg.thinking.budget
    if payload.max_tokens <= budget then
      payload.max_tokens = budget + (cfg.thinkingHeadroom or 2048)
    end
    payload.thinking = { type = "enabled", budget_tokens = budget }
  end

  local headers = {
    ["x-api-key"]         = cfg.apiKey,
    ["anthropic-version"] = client.apiVersion,
    ["content-type"]      = "application/json",
    ["accept"]            = "application/json",
  }
  if cfg.beta then headers["anthropic-beta"] = cfg.beta end

  local json = encode(payload)
  local lastErr

  for tryN = 1, (cfg.retries or client.retries) do
    local status, text, hdrs = attempt(client.endpoint, json, headers,
                                       cfg.timeout or client.timeout)

    if status == nil then
      lastErr = text
      if lastErr == "cancelled" then return nil, lastErr end
    elseif status >= 200 and status < 300 then
      local data = decode(text)
      if not data then return nil, "could not parse API response" end
      return client.parse(data)
    else
      local data = decode(text or "")
      local msg = data and data.error and data.error.message
                  or ("HTTP " .. tostring(status))
      lastErr = ("HTTP %s: %s"):format(tostring(status), msg)

      -- 400/401/403/404 will not get better by trying again.
      if status == 401 or status == 403 then
        return nil, lastErr .. "  (check the API key in config)"
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
    return nil, "response hit max_tokens before producing any text -- "
             .. "raise maxTokens, or lower the thinking budget"
  end
  if out.text == "" then
    return nil, "model returned no text (stop_reason: "
             .. tostring(out.stop) .. ")"
  end
  return out
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
