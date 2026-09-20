--[[ ui/worker.lua ------------------------------------------------------
  The thin end of the fleet. Runs on each turtle.

  It holds no API key and never talks to the internet. It knows how to
  describe itself, run a program it is handed, and stream the output back.
  Everything else -- the conversation, the money, the model choice -- lives
  on the host.

      ccagent/ui/worker            (add to startup to make it automatic)

  You can still type a request here: it is relayed to the host, which does
  the thinking and sends a program back.
--------------------------------------------------------------------------]]

package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local util     = require("agent.util")
local agent    = require("agent.init")
local config   = require("claude.config")
local executor = require("claude.executor")
local console  = require("ui.console")
local net      = require("ui.net")

local M = {}

local cfg, hostId, running = nil, nil, true

local function findHost()
  if not _G.rednet then return nil end
  local id = rednet.lookup(cfg.protocol, cfg.hostname)
  return id
end

local function describe()
  return {
    caps      = agent.caps.detect(),
    situation = agent.situation(),
    label     = (os.getComputerLabel and os.getComputerLabel()) or ("turtle-" .. os.getComputerID()),
  }
end

local function announce()
  local d = describe()
  d.t = "hello"
  if hostId then net.send(hostId, d, cfg.protocol)
  else net.broadcast(d, cfg.protocol) end
end

local function runProgram(msg)
  console.status("running job " .. tostring(msg.job))
  local result = executor.run(msg.src, agent.env(), {
    name = msg.job or "job",
    onOutput = function(kind, text, extra)
      if kind == "warn" then console.warn(text)
      elseif kind == "report" then console.head("= " .. text)
      else console.say(text) end
      if hostId then
        net.send(hostId, { t = "output", kind = kind, text = text,
                           job = msg.job, extra = extra }, cfg.protocol)
      end
    end,
  })
  agent.state.flush()
  if hostId then
    net.send(hostId, {
      t = "result", job = msg.job,
      ok = result.ok, error = result.error, output = result.output,
      result = result.result, aborted = result.aborted, elapsed = result.elapsed,
      situation = agent.situation(),
    }, cfg.protocol)
  end
  if result.ok then console.head(("done in %.1fs"):format(result.elapsed or 0))
  elseif result.aborted then console.warn("stopped")
  else console.err(util.clip(tostring(result.error), 300)) end
end

--- Listen for orders. Runs as one half of a parallel pair with the local
--- prompt, so a turtle can be driven from the host and from its own screen.
local function listen()
  while running do
    local id, msg = net.receive(5, cfg.protocol)
    if id and msg then
      if msg.t == "run" then
        hostId = id
        runProgram(msg)
      elseif msg.t == "poll" then
        hostId = id
        local d = describe(); d.t = "state"
        net.send(id, d, cfg.protocol)
      elseif msg.t == "abort" then
        executor.requestAbort()
      elseif msg.t == "ack" then
        console.dim(tostring(msg.text))
      elseif msg.t == "hostup" then
        hostId = id
        announce()
      end
    elseif not hostId then
      hostId = findHost()
      if hostId then
        console.dim("found host " .. hostId)
        announce()
      end
    end
  end
end

local function prompt()
  local history = {}
  while running do
    local input = console.ask("> ", history)
    if input == nil then running = false; break end
    input = util.trim(input)
    if input == "/exit" then running = false
    elseif input == "/state" then console.info(agent.situation())
    elseif input == "/stop" then executor.requestAbort()
    elseif input == "/host" then
      hostId = findHost()
      console.dim(hostId and ("host is " .. hostId) or "no host found")
    elseif input ~= "" then
      history[#history + 1] = input
      hostId = hostId or findHost()
      if not hostId then
        console.err("no host on the network; run ccagent/ui/host on a computer")
      else
        net.send(hostId, { t = "ask", text = input, situation = agent.situation() },
                 cfg.protocol)
        console.status("sent to host " .. hostId)
      end
    end
  end
end

function M.run()
  cfg = config.load()
  console.head("ccagent worker " .. agent.VERSION)
  agent.boot()

  local ok, err = net.open()
  if not ok then
    console.err("no modem: " .. tostring(err))
    console.dim("attach a wireless modem, or use ccagent/ui/controller instead")
    return
  end
  net.protocol = cfg.protocol
  if rednet.host then
    pcall(rednet.host, cfg.protocol,
          (os.getComputerLabel and os.getComputerLabel()) or ("turtle" .. os.getComputerID()))
  end

  hostId = findHost()
  console.info(agent.situation())
  console.dim(hostId and ("host: " .. hostId) or "waiting for a host...")
  announce()

  if _G.parallel then
    parallel.waitForAny(listen, prompt)
  else
    listen()
  end
  agent.world.save()
end

if not _TEST then M.run() end

return M
