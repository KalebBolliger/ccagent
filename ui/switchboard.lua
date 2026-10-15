--[[ ui/switchboard.lua ----------------------------------------------------
  The host's half of agent/fleet.lua: the single place fleet decisions
  are made, and the delivery guarantees in both directions.

  No I/O of its own. It is handed functions to send, broadcast, read the
  clock and list workers, so the host wires it to rednet and the tests
  wire it to tables.

  FROM WORKERS. Messages that must arrive carry rs = {s=session, n, upto}:
  the worker's boot session and a number. accept() applies them strictly
  in order -- a duplicate (n already applied) or an early one (a gap
  before it) is dropped, and the worker re-sends until the heartbeat's
  acks() says it got through. A new session (the worker rebooted) starts
  the count again.

  TO WORKERS. Messages for one worker (fleet.send, /fleet tell) go into
  that worker's queue with hs = {s=host session, n}, are sent at once,
  and are re-sent whenever the worker reports in without having
  acknowledged them. The host session survives restarts (it is saved), so
  a worker never mistakes a restarted host's numbering for a new one.

  Board updates and pool changes are BROADCAST once, not sent per worker:
  the cost of keeping everyone current does not grow with the fleet. They
  are best-effort; a worker that missed some is brought up to date by a
  snapshot when it rejoins or is launched.
--------------------------------------------------------------------------]]

local pool = require("agent.pool")

local SB = {}
SB.__index = SB

local switchboard = {}

--- io = { send(id, msg), broadcast(msg), now() -> ms, workers() -> {ids},
---        label(id) -> string|nil }
function switchboard.new(io)
  local self = setmetatable({ io = io }, SB)
  self:reset(true)
  self.session = io.now()
  self.rx = {}            -- [id] = { s = worker session, last = n }
  self.tx = {}            -- [id] = { n = last assigned, queue = { {n,msg,sent} } }
  self.dirty = false
  return self
end

--- Clear the work and the board. Delivery state (sessions, queues) is
--- kept unless `all`: numbering must not restart under a running worker.
function SB:reset(all)
  self.pool  = pool.new()
  self.board = {}          -- [id] = { label=, at=ms, facts = {} }
  if all then self.rx, self.tx = {}, {} end
  self.dirty = true
end

--------------------------------------------------------- from workers --

--- Gate a message from a worker. Returns the message when it should be
--- applied now, nil when it is a duplicate or arrived out of order.
function SB:accept(id, msg)
  local rs = msg.rs
  if type(rs) ~= "table" then return msg end
  local r = self.rx[id]
  if not r then
    -- Never heard from (or this host lost its file): join the count
    -- wherever it is. Nothing better is possible.
    r = { s = rs.s, last = rs.n - 1 }
    self.rx[id] = r
  elseif r.s ~= rs.s then
    -- The worker rebooted. Its numbering restarts at 1 and it re-sends
    -- from 1, so wait for 1: syncing to whatever arrived first would
    -- write off everything lost in the air before it as "already seen".
    if rs.n ~= 1 then return nil end
    r = { s = rs.s, last = 0 }
    self.rx[id] = r
  end
  if rs.n <= r.last then return nil end
  if rs.n ~= r.last + 1 then return nil end
  r.last = rs.upto or rs.n
  self.dirty = true
  return msg
end

--- For the heartbeat: what has been applied, per worker.
function SB:acks()
  local out = {}
  for id, r in pairs(self.rx) do out[id] = { s = r.s, n = r.last } end
  return out
end

------------------------------------------------------------ to workers --

local function enqueue(self, id, msg)
  local t = self.tx[id] or { n = 0, queue = {} }
  self.tx[id] = t
  t.n = t.n + 1
  msg.hs = { s = self.session, n = t.n }
  local e = { n = t.n, msg = msg, sent = self.io.now() }
  t.queue[#t.queue + 1] = e
  self.io.send(id, msg)
  self.dirty = true
end

--- A worker reported what it has delivered: drop that, re-send the rest
--- that has had time to arrive.
function SB:ackFrom(id, ack, resendAfterMs)
  local t = self.tx[id]
  if not t then return 0 end
  if type(ack) == "table" and ack.s == self.session then
    while t.queue[1] and t.queue[1].n <= (ack.n or 0) do table.remove(t.queue, 1) end
  end
  local now, n = self.io.now(), 0
  for _, e in ipairs(t.queue) do
    if now - (e.sent or 0) >= (resendAfterMs or 3000) then
      e.sent = now
      self.io.send(id, e.msg)
      n = n + 1
    end
  end
  return n
end

--- Messages waiting for a worker to acknowledge.
function SB:queued(id)
  local t = self.tx[id]
  return t and #t.queue or 0
end

--- Deliver a message to workers. to = id, "all" (everyone but `from`),
--- or a list of ids.
function SB:deliver(from, to, topic, body)
  local targets = {}
  if to == "all" then
    for _, wid in ipairs(self.io.workers()) do
      if wid ~= from then targets[#targets + 1] = wid end
    end
  elseif type(to) == "table" then
    targets = to
  else
    targets = { tonumber(to) or to }
  end
  local label = type(from) == "number" and self.io.label(from) or nil
  for _, wid in ipairs(targets) do
    enqueue(self, wid, { t = "fleet", kind = "msg", from = from, label = label,
                         topic = topic, body = body })
  end
  return #targets
end

------------------------------------------------------------ the work --

local function bcast(self, msg) self.io.broadcast(msg) end

--- Apply a fleet message from a worker (already through accept). Returns
--- a note for the operator, or nil.
function SB:apply(id, msg)
  local t = msg.t
  local p = self.pool
  if t == "post" then
    local e = self.board[id] or { facts = {} }
    self.board[id] = e
    e.label = self.io.label(id)
    e.at = self.io.now()
    e.facts[tostring(msg.key)] = msg.value
    self.dirty = true
    bcast(self, { t = "fleet", kind = "post", from = id, label = e.label,
                  key = msg.key, value = msg.value })
  elseif t == "offer" then
    if pool.offer(p, msg.name, msg.data) then
      self.dirty = true
      bcast(self, { t = "fleet", kind = "offer", name = tostring(msg.name),
                    data = msg.data })
    end
  elseif t == "claim" then
    local name = tostring(msg.name)
    local ok, holder = pool.claim(p, name, id)
    self.io.send(id, { t = "claimed", req = msg.req, name = name, ok = ok,
                       holder = holder, done = p.done[name] })
    if ok then
      self.dirty = true
      bcast(self, { t = "fleet", kind = "claim", name = name, holder = id })
    end
  elseif t == "take" then
    local name, data = pool.take(p, id, msg.near)
    self.io.send(id, { t = "took", req = msg.req, name = name, data = data,
                       counts = pool.counts(p) })
    if name then
      self.dirty = true
      bcast(self, { t = "fleet", kind = "claim", name = name, holder = id })
    end
  elseif t == "finish" then
    if pool.finish(p, msg.name, id) then
      self.dirty = true
      bcast(self, { t = "fleet", kind = "finish", name = tostring(msg.name), holder = id })
    end
  elseif t == "release" then
    if pool.release(p, msg.name, id) then
      self.dirty = true
      bcast(self, { t = "fleet", kind = "release", name = tostring(msg.name), holder = id })
    end
  elseif t == "msg" then
    self:deliver(id, msg.to, msg.topic, msg.body)
  elseif t == "gap" then
    if (msg.lines or 0) > 0 then
      return ("%d output line(s) lost while out of range"):format(msg.lines)
    end
  end
  return nil
end

--- Take back what a worker holds and has not finished. Returns the names.
function SB:releaseAll(id)
  local freed = pool.releaseAll(self.pool, id)
  for _, name in ipairs(freed) do
    bcast(self, { t = "fleet", kind = "release", name = name, holder = id })
  end
  if #freed > 0 then self.dirty = true end
  return freed
end

--- Take back the unfinished work of every holder silent for longer than
--- leaseMs. heardAt(id) -> ms or nil; silence counts from `since` (the
--- host's start) for a worker not heard yet. Returns { [id] = {names} }.
function SB:expire(now, leaseMs, heardAt, since)
  local holders = {}
  for name, holder in pairs(self.pool.claims) do
    if not self.pool.done[name] then holders[holder] = true end
  end
  local out = {}
  for id in pairs(holders) do
    local heard = heardAt(id) or since or now
    if now - heard > leaseMs then out[id] = self:releaseAll(id) end
  end
  return out
end

--- Everything a worker needs to join a fleet in progress. Ages, not
--- timestamps: clocks differ between computers.
function SB:snapshot()
  local board, now = {}, self.io.now()
  for id, e in pairs(self.board) do
    board[id] = { label = e.label, facts = e.facts,
                  age = math.floor((now - (e.at or now)) / 1000) }
  end
  return { t = "fleet", kind = "snapshot", board = board,
           pool = pool.export(self.pool) }
end

function SB:counts() return pool.counts(self.pool) end

------------------------------------------------------------ persistence --

function SB:export()
  local tx = {}
  for id, t in pairs(self.tx) do
    local q = {}
    for i, e in ipairs(t.queue) do q[i] = { n = e.n, msg = e.msg } end
    tx[id] = { n = t.n, queue = q }
  end
  return { session = self.session, pool = pool.export(self.pool),
           board = self.board, rx = self.rx, tx = tx }
end

function SB:import(data)
  if type(data) ~= "table" then return false end
  self.session = data.session or self.session
  self.pool  = pool.import(data.pool)
  self.board = data.board or {}
  self.rx    = data.rx or {}
  self.tx    = data.tx or {}
  -- This computer's clock from before the restart means nothing now:
  -- ages start over, and everything queued is due for re-sending.
  local now = self.io.now()
  for _, e in pairs(self.board) do e.at = now end
  for _, t in pairs(self.tx) do
    for _, e in ipairs(t.queue or {}) do e.sent = 0 end
  end
  self.dirty = false
  return true
end

return switchboard
