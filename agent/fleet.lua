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

  With no host (the standalone controller, or a worker that lost its
  host) everything still works as a fleet of one: post records locally,
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

--- Set by ui/worker.lua: { send = function(msg) -> bool, id = number,
--- label = string }. send returns false when there is no host to send to.
fleet.link = nil
fleet.timeout = 5          -- seconds to wait for the host to answer a claim

local board  = {}          -- [id] = { label=, at=clock, facts = {key=value} }
local claims = {}          -- [name] = holder id
local replies = {}         -- [req] = reply message
local seq = 0

local function myId()
  if fleet.link and fleet.link.id then return fleet.link.id end
  return (_G.os and os.getComputerID and os.getComputerID()) or 0
end

local function send(msg)
  if not fleet.link then return false end
  return fleet.link.send(msg) and true or false
end

function fleet.id() return myId() end

--- True when a host is there to relay and arbitrate.
function fleet.connected()
  return fleet.link ~= nil and (fleet.link.connected == nil or fleet.link.connected())
end

local function record(id, key, value, label)
  local e = board[id] or { facts = {} }
  board[id] = e
  if label then e.label = label end
  e.facts[key] = value
  e.at = util.now()
end

--- Tell the other turtles something. Latest value per key wins.
function fleet.post(key, value)
  key = tostring(key)
  record(myId(), key, value, fleet.link and fleet.link.label)
  send({ t = "post", key = key, value = value })
  return true
end

--- What every turtle last posted, yours included:
---   { [id] = { label=, age=seconds, <key>=value, ... } }
function fleet.board()
  local out, now = {}, util.now()
  for id, e in pairs(board) do
    local row = { label = e.label, age = math.floor((now - (e.at or now)) / 1000) }
    for k, v in pairs(e.facts) do row[k] = v end
    out[id] = row
  end
  return out
end

--- Who holds what, as last heard: { [name] = id }.
function fleet.claims()
  local out = {}
  for k, v in pairs(claims) do out[k] = v end
  return out
end

--- Take a named piece of work. Returns true if it is yours (already
--- yours counts), or false and the holder's id. With no host every claim
--- succeeds. nil, err if the host did not answer -- treat that as "go
--- ahead carefully" or retry, never as a grant from someone else.
function fleet.claim(name)
  name = tostring(name)
  if not fleet.connected() then
    claims[name] = myId()
    return true, myId()
  end
  seq = seq + 1
  local req = ("%d:%d"):format(myId(), seq)
  if not send({ t = "claim", name = name, req = req }) then
    claims[name] = myId()
    return true, myId()
  end
  local deadline = util.now() + fleet.timeout * 1000
  while not replies[req] do
    if util.now() >= deadline then return nil, "host did not answer" end
    job.sleep(0.1)
  end
  local r = replies[req]
  replies[req] = nil
  if r.ok then claims[name] = myId() else claims[name] = r.holder end
  return r.ok and true or false, r.holder
end

--- Give a claim back (for work you could not finish, so another turtle
--- can take it). Releasing something you do not hold does nothing.
function fleet.release(name)
  name = tostring(name)
  if claims[name] == myId() then claims[name] = nil end
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
    elseif msg.kind == "release" then
      if claims[msg.name] == msg.holder then claims[msg.name] = nil end
    elseif msg.kind == "snapshot" then
      board, claims = {}, {}
      for id, e in pairs(msg.board or {}) do
        board[id] = { label = e.label, at = util.now(), facts = e.facts or {} }
      end
      for k, v in pairs(msg.claims or {}) do claims[k] = v end
    end
  end
end

--- Forget everything heard. For tests, and for a worker joining a new host.
function fleet.reset()
  board, claims, replies, seq = {}, {}, {}, 0
end

return fleet
