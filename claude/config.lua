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
  maxTokens   = 4096,
  temperature = nil,          -- leave nil to let the API default
  timeout     = 60,
  retries     = 3,
  maxRepairs  = 2,            -- automatic fix attempts after a runtime error
  cache       = true,         -- cache_control on the system prompt
  thinking    = nil,          -- e.g. { budget = 2048 } for extended thinking
  operatorNotes = "",         -- free text appended to the system prompt

  -- fleet (host/worker mode)
  protocol    = "ccagent",
  hostname    = "ccagent-host",

  logFile     = "/.ccagent/log.txt",
  logLevel    = "info",
}

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

--- Write the API key to its own file (used by the first-run prompt).
function config.saveKey(key)
  return util.writeFile(config.paths.key, util.trim(key))
end

function config.hasKey(cfg)
  return cfg and cfg.apiKey and cfg.apiKey ~= ""
end

return config
