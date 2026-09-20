--[[ /ccagent/install.lua ------------------------------------------------
  First-run setup, and optionally a fetcher.

    ccagent/install                     -- local setup only
    ccagent/install <base-url>          -- also download the library
    ccagent/install --startup worker    -- and boot into worker mode

  "Local setup" means: make the directories, ask for the API key once, drop
  a /ccagent shim on the path so you can type `ccagent` from anywhere, and
  run a self-check that tells you what this machine can and cannot do.
--------------------------------------------------------------------------]]

local FILES = {
  "agent/util.lua", "agent/geom.lua", "agent/state.lua", "agent/caps.lua",
  "agent/world.lua", "agent/nav.lua", "agent/inv.lua", "agent/block.lua",
  "agent/job.lua", "agent/registry.lua",
  "agent/contract.lua", "agent/lint.lua", "agent/lib.lua",
  "agent/init.lua",
  "claude/client.lua", "claude/prompt.lua", "claude/extract.lua",
  "claude/executor.lua", "claude/session.lua", "claude/config.lua",
  "ui/console.lua", "ui/jobs.lua", "ui/net.lua",
  "ui/controller.lua", "ui/worker.lua", "ui/host.lua",
  "config.lua",
}

local args = { ... }
local base, startupMode = nil, nil
for i = 1, #args do
  if args[i] == "--startup" then startupMode = args[i + 1]
  elseif args[i]:match("^https?://") then base = args[i]:gsub("/$", "") end
end

local function say(s) print(s) end

---------------------------------------------------------------- download --

if base then
  if not http then
    error("the http API is disabled in this world; copy the files in by hand", 0)
  end
  for _, f in ipairs(FILES) do
    local url = base .. "/" .. f
    write("fetching " .. f .. " ... ")
    local res = http.get(url)
    if not res then
      print("FAILED")
      error("could not fetch " .. url, 0)
    end
    local data = res.readAll()
    res.close()
    local path = "/ccagent/" .. f
    -- Never clobber an edited config.
    if f == "config.lua" and fs.exists(path) then
      print("kept existing")
    else
      local dir = fs.getDir(path)
      if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
      local h = fs.open(path, "w")
      h.write(data); h.close()
      print("ok")
    end
  end
end

------------------------------------------------------------------ setup ---

for _, d in ipairs({ "/ccagent", "/ccagent/jobs", "/.ccagent" }) do
  if not fs.exists(d) then fs.makeDir(d) end
end

-- A shim so `ccagent` works from any directory.
if not fs.exists("/ccagent.lua") then
  local h = fs.open("/ccagent.lua", "w")
  h.write([[
-- ccagent launcher
local mode = ...
local map = {
  host = "/ccagent/ui/host.lua",
  worker = "/ccagent/ui/worker.lua",
  solo = "/ccagent/ui/controller.lua",
}
local rest = { select(2, ...) }
if mode and map[mode] then
  shell.run(map[mode], table.unpack(rest))
else
  shell.run("/ccagent/ui/controller.lua", ...)
end
]])
  h.close()
  say("installed /ccagent.lua launcher")
end

-- API key.
local keyPath = "/.ccagent/key"
if not fs.exists(keyPath) then
  say("")
  say("Anthropic API key (from console.anthropic.com).")
  say("Stored in " .. keyPath .. " only. Leave blank to skip (worker-only machines")
  say("do not need one).")
  write("key> ")
  local key = read()
  if key and key:gsub("%s", "") ~= "" then
    local h = fs.open(keyPath, "w")
    h.write((key:gsub("^%s+", ""):gsub("%s+$", "")))
    h.close()
    say("saved")
  else
    say("skipped")
  end
end

if startupMode then
  local h = fs.open("/startup.lua", "w")
  h.write(('shell.run("/ccagent.lua", "%s")\n'):format(startupMode))
  h.close()
  say("startup set to " .. startupMode)
end

----------------------------------------------------------------- check ----

package.path = "/?.lua;/?/init.lua;" .. (package.path or "")
local ok, agent = pcall(require, "agent.init")
if not ok then
  say("")
  say("self-check FAILED: " .. tostring(agent))
  say("are all the files under /ccagent/ ?")
  return
end

agent.boot({ calibrate = false })
local registry = require("agent.registry")
local tokens = registry.manifestCost()

say("")
say("ccagent " .. agent.VERSION .. " ready")
say("  capabilities : " .. agent.caps.summary())
say("  api manifest : ~" .. tokens .. " tokens (cached after the first call)")
say("  http         : " .. (http and "available" or "DISABLED in this world"))
say("")
if agent.caps.has("turtle") then
  say("  run  ccagent          -- standalone (needs a key on this turtle)")
  say("  run  ccagent worker   -- join a host over rednet (no key needed)")
else
  say("  run  ccagent host     -- drive turtles over rednet from here")
end
if not agent.caps.has("gps") then
  say("")
  say("  note: no GPS fix. Coordinates will be local to wherever the turtle")
  say("        booted. A GPS constellation makes them match the world's.")
end
