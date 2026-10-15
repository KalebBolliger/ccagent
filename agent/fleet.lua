--[[ agent/fleet.lua -----------------------------------------------------
  Turtles working the same job, telling each other what they are doing.

  The host is the switchboard and the only judge. Workers talk to it, it
  decides and relays; workers never talk to each other directly, which is
  what makes every decision single-sourced however many probes there are.

  WORK (agent/pool.lua has the rules). A named piece of work is open,
  taken or done. Programs either
    - fleet.offer the pieces (any worker may; repeats are ignored, so N
      probes can all offer the same list) and fleet.take the best open
      one -- nearest to this turtle, or highest data.priority -- or
    - fleet.claim names they made up themselves.
  The host grants each name to one worker. A taken piece ends three ways:
  fleet.finish (done for good), fleet.release (back to open), or the
  host taking it back when the job ends without finishing it or the
  holder has been silent for the claim lease.

  MESSAGES. fleet.post for latest-value facts everyone can see (board);
  fleet.send/receive for messages to one worker or all of them, including
  from the operator (/fleet tell 3 recall).

  DELIVERY. Rednet is fire-and-forget. Everything a worker sends that
  must arrive (posts, offers, finishes, releases, messages, its output
  and its result) goes through an OUTBOX: numbered, applied by the host
  strictly in order, acknowledged in the host's heartbeat, and re-sent
  until acknowledged -- so walking out of range delays these instead of
  losing them. Messages to a worker are queued on the host the same way.
  Only output lines are ever given up, oldest first, when a long silence
  fills the outbox; the host then says how many were lost.
  Claims and takes are questions, not news: asked directly, answered or
  failed at once when out of contact.

  THE LINK. The host sends a heartbeat every few seconds; the worker
  records when it last heard one, the distance CC reported for it, and
  where this turtle stood. fleet.link() hands that to programs.

  Range, read from CC:Tweaked (WirelessModemPeripheral, WirelessNetwork):
  an ender modem has no limit and works across dimensions; a normal
  wireless modem reaches 64 blocks below y=96, rising to 384 at build
  height (server config can change both). A message arrives within the
  LARGER of the two ends' ranges. A worker in relay mode repeats rednet
  the way CC's `repeat` program does, so a probe parked between the host
  and the others extends the reach; distances are then to whichever of
  host or relay was heard last.

  With no host everything works as a fleet of one: posts and offers are
  recorded locally, take and claim always succeed, messages to yourself
  arrive. A program written for twenty probes runs unchanged on one.

  Positions are in each poster's coordinate frame; without GPS they are
  only comparable after the operator aligned the frames (host:
  /forget <id> x,y,z).

  State here is deliberately NOT saved and restored by lib.run's nesting
  boundary: it is a mailbox about other machines, not a setting a
  routine could leave wrong for its caller.
--------------------------------------------------------------------------]]

local util = require("agent.util")
local job  = require("agent.job")
local pool = require("agent.pool")

local fleet = {}

--- The connection to the host, set by ui/worker.lua:
---   { send = function(msg) -> bool, id = number, label = string,
---     session = number, connected = function() -> bool,
---     modem = function() -> kind|nil, setRelay = function(on) -> bool }
--- connected() says a host is known; send returns false without one.
fleet.wire = nil
fleet.timeout   = 5        -- seconds to wait for the host to answer a question
fleet.lapse     = 30       -- seconds of silence after which contact is lost
fleet.resendAfter = 3      -- seconds before an unacknowledged message is re-sent
fleet.outboxMax = 300      -- entries before the oldest output lines are given up
fleet.inboxMax  = 200

local board, cache, replies, seq, contact
local outbox, outSeq, inbox, rxHost

local function reset()
  board   = {}          -- [id] = { label=, at=ms, facts = {key=value} }
  cache   = pool.new()  -- what we have heard of the host's pool
  replies = {}          -- [req] = reply message
  seq     = 0
  contact = {}          -- at=ms, distance=, pos=, hostModem=
  outbox  = {}          -- { n=, upto=, msg=, sent=ms }, ascending n
  outSeq  = 0
  inbox   = {}          -- { from=, label=, topic=, body=, at= }
  rxHost  = {}          -- s = host session, last = highest delivered
end
reset()

local function myId()
  if fleet.wire and fleet.wire.id then return fleet.wire.id end
  return (_G.os and os.getComputerID and os.getComputerID()) or 0
end

local function hostKnown()
  return fleet.wire ~= nil and (fleet.wire.connected == nil or fleet.wire.connected())
end

local function heardAgo()
  if not contact.at then return nil end
  return math.floor((util.now() - contact.at) / 1000)
end

--- Contact is lost only once it was had: a host that has not sent its
--- first heartbeat yet is not a lost host.
local function lapsed()
  local ago = heardAgo()
  return ago ~= nil and ago > fleet.lapse
end

local function rawSend(msg)
  if not fleet.wire then return false end
  return fleet.wire.send(msg) and true or false
end

function fleet.id() return myId() end

--- True when a host is there to relay and arbitrate right now.
function fleet.connected()
  return hostKnown() and not lapsed()
end

--------------------------------------------------------------- outbox ---

local function session()
  return fleet.wire and fleet.wire.session or 0
end

local function stamp(e)
  local m = e.msg
  m.rs = { s = session(), n = e.n, upto = e.upto }
  return m
end

--- Coalesce: a run of given-up entries becomes one gap the host can skip
--- in a single step, so a long silence costs one entry, not hundreds.
local function mergeGaps()
  local i = 2
  while i <= #outbox do
    local a, b = outbox[i - 1], outbox[i]
    if a.msg.t == "gap" and b.msg.t == "gap" and a.upto + 1 == b.n then
      a.upto = b.upto
      a.msg.lines = (a.msg.lines or 0) + (b.msg.lines or 0)
      table.remove(outbox, i)
    else
      i = i + 1
    end
  end
end

local function giveUp(e, lines)
  e.msg = { t = "gap", lines = lines or 0 }
end

local function trim()
  while #outbox > fleet.outboxMax do
    local victim
    for _, e in ipairs(outbox) do
      if e.msg.t == "output" then victim = e; break end
    end
    if not victim then return end      -- only news left: keep it all
    giveUp(victim, 1)
    mergeGaps()
  end
end

--- Queue something that must reach the host, in order. Sent at once when
--- in contact; re-sent by fleet.flush until acknowledged.
---   opts.key  -- a later message with the same key supersedes this one
---                (posts: only the newest value per key is worth sending)
function fleet.queue(msg, opts)
  if not fleet.wire then return false end
  if opts and opts.key then
    for _, e in ipairs(outbox) do
      if e.key == opts.key and e.msg.t ~= "gap" then giveUp(e, 0); e.key = nil end
    end
    mergeGaps()
  end
  outSeq = outSeq + 1
  local e = { n = outSeq, upto = outSeq, msg = msg, key = opts and opts.key }
  outbox[#outbox + 1] = e
  trim()
  if hostKnown() and not lapsed() then
    e.sent = util.now()
    rawSend(stamp(e))
  end
  return true
end

--- Drop what the host has confirmed (its heartbeat carries, per worker,
--- the session and the highest number it applied).
function fleet.acked(ack)
  if type(ack) ~= "table" or ack.s ~= session() then return end
  while outbox[1] and outbox[1].upto <= (ack.n or 0) do table.remove(outbox, 1) end
end

--- Re-send everything unacknowledged that has had time to be answered.
function fleet.flush(force)
  if not hostKnown() then return 0 end
  local now, n = util.now(), 0
  for _, e in ipairs(outbox) do
    if force or not e.sent or now - e.sent >= fleet.resendAfter * 1000 then
      e.sent = now
      rawSend(stamp(e))
      n = n + 1
    end
  end
  return n
end

--- How many messages are waiting to reach the host.
function fleet.pending() return #outbox end

----------------------------------------------------------------- link ---

--- How this turtle is in touch with its host:
---   { connected, heardAgo=s|nil, distance=blocks|nil, lastContact=pos|nil,
---     modem="ender"|"wireless"|nil, hostModem=..., unlimited=bool,
---     pending=n }
--- distance is nil across dimensions or before the first heartbeat.
function fleet.link()
  local own = fleet.wire and fleet.wire.modem and fleet.wire.modem() or nil
  local l = {
    connected   = fleet.connected(),
    heardAgo    = heardAgo(),
    distance    = contact.distance,
    lastContact = contact.pos and { x = contact.pos.x, y = contact.pos.y,
                                    z = contact.pos.z } or nil,
    modem       = own,
    hostModem   = contact.hostModem,
    pending     = #outbox,
  }
  l.unlimited = own == "ender" or contact.hostModem == "ender"
  return l
end

--- Called by the worker whenever its host is heard. distance is what CC
--- reported for that message (nil across dimensions); pos is where this
--- turtle stood, so a program can walk back to it to reconnect.
function fleet.heard(distance, pos, hostModem)
  contact.at = util.now()
  if distance then contact.distance = distance end
  if pos then contact.pos = pos end
  if hostModem then contact.hostModem = hostModem end
end

--- One line for the state description Claude reads before writing a
--- program. Worded as what it means for the program, not just what it is.
function fleet.summary()
  if not fleet.wire then return nil end
  if not hostKnown() then return "link: no host -- fleet calls act alone" end
  local l = fleet.link()
  local range
  if l.unlimited then
    range = "ender modem, no range limit"
  else
    range = "wireless: ~64 blocks below y=96, more higher up"
  end
  local queued = l.pending > 0 and ("; %d message(s) waiting to send"):format(l.pending) or ""
  if l.heardAgo == nil then
    return "link: host known, not heard yet; " .. range .. queued
  end
  if not l.connected then
    local at = l.lastContact and ("%d,%d,%d"):format(l.lastContact.x,
                 l.lastContact.y, l.lastContact.z) or "?"
    return ("link: LOST %ds (last heard at %s) -- messages wait in the "
            .. "outbox and claims fail; move back toward there to "
            .. "reconnect; %s%s"):format(l.heardAgo, at, range, queued)
  end
  return ("link: host heard %ds ago%s; %s%s"):format(l.heardAgo,
    l.distance and (", " .. math.floor(l.distance) .. " blocks away") or "",
    range, queued)
end

---------------------------------------------------------------- board ---

local function record(id, key, value, label, at)
  local e = board[id] or { facts = {} }
  board[id] = e
  if label then e.label = label end
  e.facts[key] = value
  e.at = at or util.now()
end

--- Tell the other turtles something. Latest value per key wins; only the
--- newest unsent value per key is kept while out of range.
function fleet.post(key, value)
  key = tostring(key)
  record(myId(), key, value, fleet.wire and fleet.wire.label)
  fleet.queue({ t = "post", key = key, value = value }, { key = "post:" .. key })
  return true
end

--- What every turtle last posted, yours included:
---   { [id] = { label=, age=seconds, <key>=value, ... } }
--- age is how old the turtle's latest post is -- a large age means it has
--- gone quiet, not that its facts are wrong.
function fleet.board()
  local out, now = {}, util.now()
  for id, e in pairs(board) do
    local row = { label = e.label, age = math.floor((now - (e.at or now)) / 1000) }
    for k, v in pairs(e.facts) do row[k] = v end
    out[id] = row
  end
  return out
end

----------------------------------------------------------------- work ---

local function ask(msg)
  seq = seq + 1
  local req = ("%d:%d"):format(myId(), seq)
  msg.req = req
  if not rawSend(msg) then return nil, "could not send to the host" end
  local deadline = util.now() + fleet.timeout * 1000
  while not replies[req] do
    if util.now() >= deadline then return nil, "host did not answer" end
    job.sleep(0.1)
  end
  local r = replies[req]
  replies[req] = nil
  return r
end

--- Add pieces of work for any worker to take. name, data? -- data is a
--- small table; data.pos lets take() hand out the nearest piece and
--- data.priority (higher first) the most urgent. Offering a known name
--- does nothing, so every probe may offer the same list.
function fleet.offer(name, data)
  name = tostring(name)
  pool.offer(cache, name, data)
  if hostKnown() then fleet.queue({ t = "offer", name = name, data = data }) end
  return true
end

--- Take the best open piece of work: highest data.priority, then nearest
--- (to opts.near, default this turtle), then oldest.
---   -> name, data, info     info = { open=, taken=, done= }
---   -> nil, nil, info       info.reason = "none" (nothing open; if
---                           info.taken > 0 others are still working and
---                           their pieces may come back) or "contact"
function fleet.take(opts)
  opts = opts or {}
  local near = opts.near
  if near == nil then
    local okNav, nav = pcall(require, "agent.nav")
    near = okNav and nav.pos() or nil
  end
  if not hostKnown() then
    local name, data = pool.take(cache, myId(), near)
    local info = pool.counts(cache)
    if not name then info.reason = "none" end
    return name, data, info
  end
  if lapsed() then
    local info = pool.counts(cache)
    info.reason = "contact"
    return nil, nil, info
  end
  -- Offers still unacknowledged get another try first, so the host can
  -- hand them out. Not forced: re-sending the whole outbox (output and
  -- all) on every take would be most of the radio traffic.
  fleet.flush()
  local r, err = ask({ t = "take", near = near })
  if not r then
    local info = pool.counts(cache)
    info.reason, info.error = "contact", err
    return nil, nil, info
  end
  local info = r.counts or { open = 0, taken = 0, done = 0 }
  if r.name then
    if r.data ~= nil or not cache.items[r.name] then
      pool.offer(cache, r.name, r.data)
    end
    cache.claims[r.name] = myId()
    return r.name, r.data, info
  end
  info.reason = "none"
  return nil, nil, info
end

--- How much work there is, as last heard: { open=, taken=, done= }.
--- On a fleet this is a cache -- fleet.take is the authority.
function fleet.work()
  return pool.counts(cache)
end

--- Take a named piece of work. Returns true if it is yours (already
--- yours counts -- claiming again is how to check a long-held claim has
--- not lapsed), or false and the holder's id. With no host every claim
--- succeeds. nil, err when out of contact or the host did not answer:
--- that is "unknown", never "someone else has it".
function fleet.claim(name)
  name = tostring(name)
  if not hostKnown() then
    return pool.claim(cache, name, myId())
  end
  if lapsed() then return nil, "out of contact with the host" end
  local r, err = ask({ t = "claim", name = name })
  if not r then return nil, err end
  cache.claims[name] = r.holder
  if r.done then cache.done[name] = true end
  return r.ok and true or false, r.holder
end

--- Mark a piece of work finished. It stays taken for good, so no other
--- turtle re-does it, and it survives the end of this job.
function fleet.finish(name)
  name = tostring(name)
  pool.finish(cache, name, myId())
  if hostKnown() then fleet.queue({ t = "finish", name = name }) end
  return true
end

--- Give a piece of work back (could not finish it) so another turtle can
--- take it. Releasing something you do not hold does nothing.
function fleet.release(name)
  name = tostring(name)
  pool.release(cache, name, myId())
  if hostKnown() then fleet.queue({ t = "release", name = name }) end
  return true
end

--- Who holds or finished what, as last heard: { [name] = id }.
function fleet.claims()
  local out = {}
  for k, v in pairs(cache.claims) do out[k] = v end
  return out
end

--- Was this named piece of work finished (by anyone)?
function fleet.isDone(name)
  return cache.done[tostring(name)] == true
end

------------------------------------------------------------- messages ---

--- Send a message: to = a worker id, or "all" for every other worker.
--- Delivered in order, and held until delivered while either end is out
--- of range. With no host, only a message to yourself arrives.
function fleet.send(to, topic, body)
  topic = tostring(topic)
  if not hostKnown() then
    if to == myId() then
      inbox[#inbox + 1] = { from = myId(), topic = topic, body = body,
                            at = util.now() }
    end
    return true
  end
  fleet.queue({ t = "msg", to = to, topic = topic, body = body })
  return true
end

local function takeFromInbox(topic)
  for i, m in ipairs(inbox) do
    if topic == nil or m.topic == topic then
      table.remove(inbox, i)
      return m
    end
  end
end

--- Next message, oldest first: { from=, label=, topic=, body= }, or nil.
--- from is a worker id, or "operator" for /fleet tell on the host.
--- timeout in seconds (default 0: just look); topic filters, leaving
--- other messages in the inbox.
function fleet.receive(timeout, topic)
  local m = takeFromInbox(topic)
  if m or not timeout or timeout <= 0 then return m end
  local deadline = util.now() + timeout * 1000
  while util.now() < deadline do
    job.sleep(0.2)
    m = takeFromInbox(topic)
    if m then return m end
  end
  return nil
end

--- Messages waiting, optionally of one topic.
function fleet.inbox(topic)
  local n = 0
  for _, m in ipairs(inbox) do
    if topic == nil or m.topic == topic then n = n + 1 end
  end
  return n
end

--- Turn relay mode on or off: this turtle then repeats rednet for the
--- others, the way CC's `repeat` program does. Park a relay between the
--- host and turtles working beyond its range. Survives the end of the
--- job; returns false where this machine cannot relay.
function fleet.relay(on)
  if not (fleet.wire and fleet.wire.setRelay) then return false end
  return fleet.wire.setRelay(on and true or false) and true or false
end

------------------------------------------------------------ the wire ---

--- The acknowledgement this worker gives the host for its queued
--- messages: session and highest number delivered.
function fleet.hostAck()
  return { s = rxHost.s, n = rxHost.last }
end

--- A message the host queued for this worker. Returns true when the host
--- should be acknowledged (new, or a duplicate of something delivered).
local function deliverQueued(msg)
  local hs = msg.hs
  if type(hs) ~= "table" then return false end
  if rxHost.s ~= hs.s then rxHost = { s = hs.s, last = hs.n - 1 } end
  if hs.n <= rxHost.last then return true end        -- duplicate: re-ack
  if hs.n ~= rxHost.last + 1 then return false end    -- gap: wait for resend
  rxHost.last = hs.n
  inbox[#inbox + 1] = { from = msg.from, label = msg.label, topic = msg.topic,
                        body = msg.body, at = util.now() }
  while #inbox > fleet.inboxMax do table.remove(inbox, 1) end
  return true
end

--- Fed by ui/worker.lua with every fleet message from the host. Returns
--- true when the host should be sent an acknowledgement right away.
function fleet.deliver(msg)
  if msg.t == "claimed" or msg.t == "took" then
    replies[msg.req] = msg
  elseif msg.t == "fleet" then
    local k = msg.kind
    if k == "msg" then
      return deliverQueued(msg)
    elseif k == "post" then
      record(msg.from, msg.key, msg.value, msg.label)
    elseif k == "offer" then
      pool.offer(cache, msg.name, msg.data)
    elseif k == "claim" then
      cache.claims[msg.name] = msg.holder
    elseif k == "finish" then
      cache.claims[msg.name], cache.done[msg.name] = msg.holder, true
    elseif k == "release" then
      if cache.claims[msg.name] == msg.holder and not cache.done[msg.name] then
        cache.claims[msg.name] = nil
      end
    elseif k == "snapshot" then
      board = {}
      local now = util.now()
      -- Ages travel as ages: stamping everything "now" made a probe that
      -- went silent an hour ago look as fresh as one that just posted.
      for id, e in pairs(msg.board or {}) do
        board[id] = { label = e.label, at = now - (e.age or 0) * 1000,
                      facts = e.facts or {} }
      end
      cache = pool.import(msg.pool)
    end
  end
  return false
end

local function sendAlive()
  rawSend({ t = "alive", distance = contact.distance, ack = fleet.hostAck(),
            relay = fleet.wire and fleet.wire.relaying and fleet.wire.relaying() or nil })
end

--- Everything the host sends that is fleet business, routed here by
--- ui/worker.lua (only from its own host). pos is where this turtle is,
--- recorded as the last place contact was had.
---   beat                -- heard; drop what the host acknowledged; re-send
---                          the rest; answer with our own acknowledgement
---   fleet/claimed/took  -- see fleet.deliver; a queued message is
---                          acknowledged at once so it is not sent twice
function fleet.handle(msg, pos)
  if msg.t == "beat" then
    fleet.heard(nil, pos, msg.modem)
    fleet.acked(msg.acks and msg.acks[myId()])
    fleet.flush()
    sendAlive()
  elseif fleet.deliver(msg) then
    sendAlive()
  end
end

--- Forget everything heard. For tests, and for a worker joining a new host.
function fleet.reset() reset() end

return fleet
