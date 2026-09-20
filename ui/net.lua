--[[ ui/net.lua ---------------------------------------------------------
  The wire protocol between host and workers. Deliberately tiny.

  Worker -> host
    {t="hello",  caps=<flags>, situation=<string>, label=<string>}
    {t="state",  situation=<string>, caps=<flags>}
    {t="output", kind=, text=, job=}
    {t="result", job=, ok=, error=, output=, result=, elapsed=}
    {t="ask",    text=<string>}          -- request typed at the turtle

  Host -> worker
    {t="run",    job=<id>, src=<lua>}
    {t="abort"}
    {t="poll"}                            -- please send state
    {t="ack",    text=<string>}
--------------------------------------------------------------------------]]

local net = {}

net.protocol = "ccagent"

function net.open(side)
  if not _G.rednet then return false, "no rednet API" end
  if side then
    if not rednet.isOpen(side) then rednet.open(side) end
    return true
  end
  if not _G.peripheral then return false, "no peripheral API" end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      return true, name
    end
  end
  return false, "no modem attached"
end

function net.send(id, msg, protocol)
  if not _G.rednet then return false end
  rednet.send(id, msg, protocol or net.protocol)
  return true
end

function net.broadcast(msg, protocol)
  if not _G.rednet then return false end
  rednet.broadcast(msg, protocol or net.protocol)
  return true
end

--- Receive with a timeout. Returns id, msg or nil.
function net.receive(timeout, protocol)
  if not _G.rednet then return nil end
  local id, msg = rednet.receive(protocol or net.protocol, timeout)
  if type(msg) ~= "table" or not msg.t then return nil end
  return id, msg
end

--- Wait for a specific message type from a specific sender.
function net.await(fromId, kinds, timeout, protocol)
  local want = {}
  for _, k in ipairs(type(kinds) == "table" and kinds or { kinds }) do
    want[k] = true
  end
  local deadline = os.clock() + (timeout or 30)
  while os.clock() < deadline do
    local id, msg = net.receive(math.max(deadline - os.clock(), 0.1), protocol)
    if id and (not fromId or id == fromId) and want[msg.t] then
      return msg, id
    end
    if id and msg then
      -- Not what we were waiting for; hand it to the caller's spillover
      -- handler if one is installed, otherwise drop it.
      if net.onStray then net.onStray(id, msg) end
    end
  end
  return nil, "timed out"
end

return net
