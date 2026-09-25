--[[ claude/config.lua ---------------------------------------------------
  Configuration loading.

  Precedence, lowest to highest:
    1. the defaults below
    2. /ccagent/config.lua           (a table; edit this one)
    3. /.ccagent/key                 (API key only, kept out of the code so
                                      you can share or version the rest)
    4. the `ccagent.*` settings namespace, if you prefer `set` at the shell
--------------------------------------------------------------------------]]

local util = require("agent.util")

local config = {}

config.defaults = {
  apiKey      = "",
  model       = "claude-sonnet-5",
  -- Generous on purpose: current models think by default, and those
  -- tokens come out of this budget before any program is written.
  maxTokens   = 32000,
  effort      = "medium",     -- low | medium | high | xhigh | max
  temperature = nil,          -- rejected by current models; older only
  stream      = true,         -- keep true: see claude/client.lua's header
  timeout     = 180,          -- our ceiling on one attempt, seconds
  readTimeout = 60,           -- CC's silence window, seconds (its max)
  retries     = 3,
  maxRepairs  = 2,            -- automatic fix attempts after a runtime error
  cache       = true,         -- cache_control on the system prompt
  -- nil lets the model decide (adaptive on current models). false or
  -- "off" disables it; { budget = N } is the pre-4.6 spelling, which
  -- current models reject with a 400.
  thinking    = nil,
  operatorNotes = "",         -- free text appended to the system prompt

  -- fleet (host/worker mode)
  protocol    = "ccagent",
  hostname    = "ccagent-host",

  -- Where /share posts a run report. A default is shipped so the command
  -- works out of the box, and it is overridable field by field because
  -- the request is described rather than built in (see ui/share.lua).
  --
  -- The safeguard against a bad default is not the absence of one: /share
  -- says what it is about to publish and asks first. To turn it off,
  -- set url = "" -- `share = {}` merges over this and changes nothing.
  share       = {
    url  = "https://paste.rs",
    link = "body",
  },

  logFile     = "/.ccagent/log.txt",
  logLevel    = "info",
}

--- Below this, a thinking model is likely to spend the whole budget
--- before writing anything. A guess, not a measurement -- see
--- docs/ARCHITECTURE.md's list of invented numbers.
config.minTokens = 8000

config.paths = {
  file = "/ccagent/config.lua",
  key  = "/.ccagent/key",
}

local function loadTableFile(path)
  if not fs or not fs.exists(path) then return nil end
  local src = util.readFile(path)
  if not src then return nil end
  local fn, err = load(src, "@" .. path, "t", _ENV or _G)
  if not fn then
    util.log.warn("config %s: %s", path, tostring(err))
    return nil
  end
  local ok, tbl = pcall(fn)
  if not ok or type(tbl) ~= "table" then
    util.log.warn("config %s did not return a table", path)
    return nil
  end
  return tbl
end

function config.load()
  local cfg = util.copy(config.defaults)

  local fromFile = loadTableFile(config.paths.file)
  if fromFile then cfg = util.merge(cfg, fromFile) end

  if fs and fs.exists(config.paths.key) then
    local key = util.trim(util.readFile(config.paths.key) or "")
    if key ~= "" then cfg.apiKey = key end
  end

  if _G.settings then
    for _, k in ipairs({ "apiKey", "model", "maxTokens", "maxRepairs",
                         "protocol", "hostname", "logLevel" }) do
      local v = settings.get("ccagent." .. k)
      if v ~= nil then cfg[k] = v end
    end
  end

  util.log.level = cfg.logLevel or "info"
  util.log.file  = cfg.logFile
  return cfg
end

--- Settings that will probably bite, given what else is set.
---
--- A config file is written once and kept across every update, so it
--- pins values the code has since moved past -- and the failure surfaces
--- much later as something that does not look like a config problem at
--- all. maxTokens is the one that has actually cost a run: an install
--- from before thinking was on by default keeps 4096, and every hard
--- request dies as "max_tokens with no text".
--- Returns an array of strings, empty when there is nothing to say.
function config.warnings(cfg)
  local out = {}
  cfg = cfg or {}
  local thinking = not (cfg.thinking == false or cfg.thinking == "off")
  local maxTok = tonumber(cfg.maxTokens) or 0
  if thinking and maxTok > 0 and maxTok < config.minTokens then
    out[#out + 1] = ("maxTokens %d may all go to thinking"):format(maxTok)
    out[#out + 1] = "  edit /ccagent/config.lua"
  end
  return out
end

--- Write the API key to its own file (used by the first-run prompt).
function config.saveKey(key)
  return util.writeFile(config.paths.key, util.trim(key))
end

function config.hasKey(cfg)
  return cfg and cfg.apiKey and cfg.apiKey ~= ""
end

return config
