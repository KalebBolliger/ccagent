--[[ agent/fleet.lua -----------------------------------------------------
  Turtles working the same job, telling each other what they are doing.

  The host is the switchboard. A worker posts small facts ("I am at
  12,0,40", "east wing done") and the host relays them to every other
  worker; a worker claims a named piece of work and the host, which
  handles one message at a time, grants each name to exactly one turtle.
  That is the whole protocol: a board of latest facts, and claims.

  Claims are what make splitting work safe. Two turtles reading the board
  and both deciding "nobody has the north wing" is a race; two turtles
  claiming it is not -- the second is told who has it.

  A claim lasts while the job that took it runs. It ends three ways:
  fleet.finish (done; stays taken for good, so nobody re-does it),
  fleet.release (given back), or the host taking it back -- when the job
  ends without finishing it, or when the holder has been silent for the
  host's lease (claimLease, five minutes by default) and is presumably
  stuck or out of range.

  The LINK. Rednet is fire-and-forget: out of range, posts and output are
  simply lost. The host sends a heartbeat every few seconds, and the
  worker records when it last heard one, how far away the host was
  (CC reports the distance of every wireless message), and where this
  turtle stood at the time. fleet.link() hands that to programs so they
  can keep contact on purpose -- and a claim made after contact lapsed
  fails at once instead of waiting out a timeout.

  Range, read from CC:Tweaked (WirelessModemPeripheral, WirelessNetwork):
  an ender modem has no limit and works across dimensions; a normal
  wireless modem reaches 64 blocks below y=96, rising to 384 at build
  height (server config can change both). A message arrives if it is
  within the LARGER of the two ends' ranges -- so one ender modem, at
  either end, removes the limit for that pair.

  With no host (the standalone controller, or a worker that never found
  one) everything still works as a fleet of one: post records locally,
  board shows only you, and every claim succeeds. A program written for
  three probes therefore runs unchanged on one.

  Positions posted here are in the poster's coordinate frame. Without
  GPS each turtle's frame is its own unless the operator aligned them
  (host: /forget <id> x,y,z), so a probe's "12,0,40" is only comparable
  to yours when that has been done.

  State here is deliberately NOT saved and restored by lib.run's nesting
  boundary: it is a mailbox about other machines, not a setting a
  routine could leave wrong for its caller.
--------------------------------------------------------------------------]]

local util = require("agent.util")
local job  = require("agent.job")

local fleet = {}

--- The connection to the host, set by ui/worker.lua:
---   { send = function(msg) -> bool, id = number, label = string,
---     connected = function() -> bool, modem = function() -> kind|nil }
--- connected() says a host is known; send returns false without one.
fleet.wire = nil
fleet.timeout = 5          -- seconds to wait for the host to answer a claim
fleet.lapse   = 30         -- seconds of silence after which contact is lost
                           -- (three missed heartbeats at the default 10s)

local board   = {}         -- [id] = { label=, at=ms, facts = {key=value} }
local claims  = {}         -- [name] = holder id
local done    = {}         -- [name] = true once finished
local replies = {}         -- [req] = reply message
local seq = 0
local contact = {}         -- at=ms, distance=, pos=, hostModem=

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

local function send(msg)
  if not fleet.wire then return false end
  return fleet.wire.send(msg) and true or false
end

function fleet.id() return myId() end

--- True when a host is there to relay and arbitrate right now.
function fleet.connected()
  return hostKnown() and not lapsed()
end

--- How this turtle is in touch with its host:
---   { connected, heardAgo=s|nil, distance=blocks|nil, lastContact=pos|nil,
---     modem="ender"|"wireless"|nil, hostModem=..., unlimited=bool }
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
  if l.heardAgo == nil then
    return "link: host known, not heard yet; " .. range
  end
  if not l.connected then
    local at = l.lastContact and ("%d,%d,%d"):format(l.lastContact.x,
                 l.lastContact.y, l.lastContact.z) or "?"
    return ("link: LOST %ds (last heard at %s) -- output and posts are "
            .. "dropped and claims fail; move back toward there to reconnect; %s")
           :format(l.heardAgo, at, range)
  end
  return ("link: host heard %ds ago%s; %s"):format(l.heardAgo,
    l.distance and (", " .. math.floor(l.distance) .. " blocks away") or "", range)
end

local function record(id, key, value, label, at)
  local e = board[id] or { facts = {} }
  board[id] = e
  if label then e.label = label end
  e.facts[key] = value
  e.at = at or util.now()
end

--- Tell the other turtles something. Latest value per key wins. Lost
--- silently out of range, so re-post state you care about periodically.
function fleet.post(key, value)
  key = tostring(key)
  record(myId(), key, value, fleet.wire and fleet.wire.label)
  send({ t = "post", key = key, value = value })
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

--- Who holds what, as last heard: { [name] = id }. Finished work stays
--- listed, so "not in claims()" means nobody has it or did it.
function fleet.claims()
  local out = {}
  for k, v in pairs(claims) do out[k] = v end
  return out
end

--- Was this named piece of work finished (by anyone)?
function fleet.isDone(name)
  return done[tostring(name)] == true
end

--- Take a named piece of work. Returns true if it is yours (already
--- yours counts -- claiming again is how to check a long-held claim has
--- not lapsed), or false and the holder's id. With no host every claim
--- succeeds. nil, err when out of contact or the host did not answer:
--- that is "unknown", never "someone else has it".
function fleet.claim(name)
  name = tostring(name)
  if not hostKnown() then
    claims[name] = myId()
    return true, myId()
  end
  if lapsed() then return nil, "out of contact with the host" end
  seq = seq + 1
  local req = ("%d:%d"):format(myId(), seq)
  if not send({ t = "claim", name = name, req = req }) then
    return nil, "could not send to the host"
  end
  local deadline = util.now() + fleet.timeout * 1000
  while not replies[req] do
    if util.now() >= deadline then return nil, "host did not answer" end
    job.sleep(0.1)
  end
  local r = replies[req]
  replies[req] = nil
  claims[name] = r.holder
  if r.done then done[name] = true end
  return r.ok and true or false, r.holder
end

--- Mark a claimed piece of work finished. It stays taken for good, so no
--- other turtle re-does it, and it survives the end of this job.
function fleet.finish(name)
  name = tostring(name)
  claims[name] = claims[name] or myId()
  done[name] = true
  send({ t = "finish", name = name })
  return true
end

--- Give a claim back (for work you could not finish, so another turtle
--- can take it). Releasing something you do not hold does nothing.
function fleet.release(name)
  name = tostring(name)
  if claims[name] == myId() and not done[name] then claims[name] = nil end
  send({ t = "release", name = name })
  return true
end

--- Fed by ui/worker.lua with every fleet message from the host.
function fleet.deliver(msg)
  if msg.t == "claimed" then
    replies[msg.req] = msg
  elseif msg.t == "fleet" then
    if msg.kind == "post" then
      record(msg.from, msg.key, msg.value, msg.label)
    elseif msg.kind == "claim" then
      claims[msg.name] = msg.holder
    elseif msg.kind == "finish" then
      claims[msg.name] = msg.holder
      done[msg.name] = true
    elseif msg.kind == "release" then
      if claims[msg.name] == msg.holder then claims[msg.name] = nil end
    elseif msg.kind == "snapshot" then
      board, claims, done = {}, {}, {}
      local now = util.now()
      -- Ages travel as ages: stamping everything "now" made a probe that
      -- went silent an hour ago look as fresh as one that just posted.
      for id, e in pairs(msg.board or {}) do
        board[id] = { label = e.label, at = now - (e.age or 0) * 1000,
                      facts = e.facts or {} }
      end
      for k, v in pairs(msg.claims or {}) do claims[k] = v end
      for k in pairs(msg.done or {}) do done[k] = true end
    end
  end
end

--- Forget everything heard. For tests, and for a worker joining a new host.
function fleet.reset()
  board, claims, done, replies, seq, contact = {}, {}, {}, {}, 0, {}
end

return fleet
