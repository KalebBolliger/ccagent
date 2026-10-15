--[[ ui/net.lua ---------------------------------------------------------
  The wire protocol between host and workers. Deliberately tiny.

  Worker -> host
    {t="hello",  caps=<flags>, situation=<string>, label=<string>}
    {t="state",  situation=<string>, caps=<flags>}
    {t="state",  busy=<job id>, last=<string>, label=}   -- poll mid-job
    {t="output", kind=, text=, job=}
    {t="result", job=, ok=, error=, output=, result=, elapsed=}
                                          -- error "busy with job <id>" when
                                          -- a run arrives mid-job
    {t="ask",    text=<string>}          -- request typed at the turtle

  Host -> worker
    {t="run",    job=<id>, src=<lua>}
    {t="abort"}                           -- heard mid-job, too
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

-- rednet's channel numbers (rom/apis/rednet.lua). Read from the API when
-- it is there; the literals are its values, for tests.
net.CHANNEL_REPEAT    = (_G.rednet and rednet.CHANNEL_REPEAT) or 65533
net.CHANNEL_BROADCAST = (_G.rednet and rednet.CHANNEL_BROADCAST) or 65535
net.MAX_ID_CHANNELS   = (_G.rednet and rednet.MAX_ID_CHANNELS) or 65500

--- What a relay should do with one modem message: the channel to send it
--- on to, or nil to leave it. Mirrors CC's rom/programs/rednet/repeat.lua:
--- only rednet packets heard on the repeat channel, each message id once
--- (remembered 30s in `seen`, which this prunes). The caller transmits on
--- the returned channel and on the repeat channel, for further relays.
function net.repeatTarget(channel, m, seen, now)
  for k, expiry in pairs(seen) do
    if expiry < now then seen[k] = nil end
  end
  if channel ~= net.CHANNEL_REPEAT or type(m) ~= "table" then return nil end
  if not m.nMessageID or type(m.nRecipient) ~= "number" then return nil end
  if seen[m.nMessageID] then return nil end
  seen[m.nMessageID] = now + 30000
  local to = m.nRecipient
  if to ~= net.CHANNEL_BROADCAST then to = to % net.MAX_ID_CHANNELS end
  return to
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
