--[[ ui/host.lua --------------------------------------------------------
  The fleet front-end. Runs on a stationary computer that holds the API key.

      /ccagent host

  Workers announce themselves; you address one (or all of them) and the host
  does the thinking, then ships the resulting program out over rednet.

  Why bother, when ui/controller already works: one key instead of N, one
  place to update the library, and a separate conversation per turtle so a
  follow-up like "now do the same one chunk east" lands on the right one.

      > @3 mine out the room below you
      > all  come home and unload
      > /use 3
      > dig a 2x2 shaft down to y=-50
--------------------------------------------------------------------------]]

-- The tree lives at /ccagent (agent/lib.lua and claude/config.lua say so
-- too). CC also searches the running program's own directory, which is
-- why a wrong prefix here still works from /ccagent/setup.lua and
-- fails from /ccagent/ui/ one level down.
package.path = "/ccagent/?.lua;/ccagent/?/init.lua;" .. (package.path or "")

local util     = require("agent.util")
local agent    = require("agent.init")
local caps     = require("agent.caps")
local registry = require("agent.registry")
local config   = require("claude.config")
local session  = require("claude.session")
local console  = require("ui.console")
local jobs     = require("ui.jobs")
local net      = require("ui.net")

local M = {}

local cfg, running = nil, true
local workers = {}     -- id -> { label, caps, situation, session, lastSeen }
local target  = nil    -- currently addressed worker id
local jobSeq  = 0

-- Fleet decisions and delivery (ui/switchboard.lua). Built in M.run and
-- M.configure, once cfg exists.
local sb

-- Kept on disk because the host is a computer in a chunk like any other:
-- an unload wipes memory, and a fleet that forgets its claims sends the
-- next probe into a wing that was already searched.
local FLEET_FILE = "/.ccagent/fleet.dat"

-- True while listen() runs. rednet delivers every message to every
-- coroutine waiting for one, so with the listener up, a second handler
-- in remoteRun or net.await handles the same message twice -- a claim
-- answered twice, a post relayed twice, a line printed twice. With the
-- listener up it is the ONLY dispatcher, and others wait on it.
local listening = false

--------------------------------------------------------------- plumbing ---

local function events()
  return function(kind, text, extra)
    if kind == "status" then console.status(text)
    elseif kind == "code" then console.code(text)
    elseif kind == "warn" then console.warn(text)
    elseif kind == "usage" then console.dim(text)
    elseif kind == "output" then
      local k = extra and extra.kind
      if k == "warn" then console.warn(text)
      elseif k == "report" then console.head("= " .. text)
      else console.say(text) end
    else console.info(text) end
  end
end

--- Ask a worker for fresh state before we spend a request describing it.
local function poll(id, timeout)
  net.send(id, { t = "poll" }, cfg.protocol)
  local msg = net.await(id, { "state", "hello" }, timeout or 4, cfg.protocol)
  if msg then
    local w = workers[id] or {}
    w.caps, w.situation, w.label = msg.caps or w.caps, msg.situation or w.situation,
                                   msg.label or w.label
    -- A worker that is mid-job answers with what it is doing instead of a
    -- fresh probe; see runProgram in ui/worker.lua.
    w.busy, w.last = msg.busy, msg.last or w.last
    w.lastSeen = os.clock()
    workers[id] = w
    return w
  end
  return workers[id]
end

--- Send a program to a worker and wait for its result.
-- The busy worker's output and result are routed by handleStray into a
-- SINK this function registers, rather than read off rednet here: the
-- listener receives every message anyway, and two readers is how a line
-- gets printed twice or a resent one gets lost to whichever reader saw it
-- second. Without a listener (tests, a machine with no parallel API) this
-- loop does the receiving itself and feeds handleStray.
local sinks = {}   -- [id] = { job=, onOutput=, result= }

local function remoteRun(id)
  return function(code, opts)
    jobSeq = jobSeq + 1
    local jobId = ("j%d"):format(jobSeq)
    local sink = { job = jobId, onOutput = opts and opts.onOutput }
    sinks[id] = sink
    net.send(id, { t = "run", job = jobId, src = code }, cfg.protocol)

    local deadline = os.clock() + (cfg.jobTimeout or 900)
    while os.clock() < deadline and not sink.result do
      if listening then
        local timer = os.startTimer(1)
        repeat
          local ev, p1 = os.pullEvent()
        until ev == "ccagent_sink" or (ev == "timer" and p1 == timer)
      else
        local from, msg = net.receive(1, cfg.protocol)
        if from and msg then M.handleStray(from, msg) end
      end
    end
    sinks[id] = nil
    if not sink.result then
      return { ok = false, error = "worker did not report back in time" }
    end
    M.jobEnded(id)
    local m = sink.result
    return { ok = m.ok, error = m.error, output = m.output,
             result = m.result, aborted = m.aborted, elapsed = m.elapsed }
  end
end

--- A session per worker, with that worker's capabilities baked into the
--- manifest. Switching between turtles of different builds re-caches the
--- system prompt once; identical turtles share a cache hit.
local function sessionFor(id)
  local w = workers[id]
  if not w then return nil, "unknown worker " .. tostring(id) end
  if not w.session then
    local proxy = {
      situation = function()
        return w.situation or ("worker " .. id .. " (state unknown)")
      end,
      env = function() error("the host does not execute programs", 0) end,
    }
    -- fleet = true: every program this host writes runs on a worker, so
    -- the prompt carries the fleet guidance. The turtle never sees it --
    -- generation happens here.
    w.session = session.new(cfg, proxy, remoteRun(id), { fleet = true })
  end
  -- Make the manifest reflect *this* turtle before the prompt is built.
  if w.caps then
    local flags = caps.detect()
    for k, v in pairs(w.caps) do flags[k] = v end
  end
  return w.session
end

--- Everything a worker needs to join a fleet already in progress.
function M.fleetSnapshot() return sb:snapshot() end

--- The switchboard, for tests and the /fleet command.
function M.switchboard() return sb end

local function newSwitchboard()
  return require("ui.switchboard").new({
    send = function(id, msg) net.send(id, msg, cfg.protocol) end,
    broadcast = function(msg) net.broadcast(msg, cfg.protocol) end,
    now = util.now,
    workers = function() return util.keys(workers) end,
    label = function(id) return workers[id] and workers[id].label end,
  })
end

--- Written to a new file and moved into place, so a chunk unloading
--- mid-write leaves the old file or the new one, never half of one.
function M.saveFleet()
  sb.dirty = false
  if not (_G.fs and _G.textutils) then return end
  local tmp = FLEET_FILE .. ".new"
  local h = fs.open(tmp, "w")
  if not h then return end
  h.write(textutils.serialize(sb:export()))
  h.close()
  if fs.exists(FLEET_FILE) then fs.delete(FLEET_FILE) end
  fs.move(tmp, FLEET_FILE)
end

function M.loadFleet()
  if not (_G.fs and _G.textutils) then return false end
  -- Stopped between the delete and the move: the new file is complete.
  local path = FLEET_FILE
  if not fs.exists(path) and fs.exists(FLEET_FILE .. ".new") then
    path = FLEET_FILE .. ".new"
  end
  if not fs.exists(path) then return false end
  local h = fs.open(path, "r")
  if not h then return false end
  local ok, data = pcall(textutils.unserialize, h.readAll() or "")
  h.close()
  if not ok or type(data) ~= "table" then return false end
  return sb:import(data)
end

function M.fleetReset()
  sb:reset()
  M.saveFleet()
end

--- A job ending leaves nothing in progress: whatever it took and did not
--- finish goes back to the pool, so the next probe can take it.
function M.jobEnded(id)
  local freed = sb:releaseAll(id)
  if #freed > 0 then
    console.dim(("[%d] %d unfinished claim(s) returned"):format(id, #freed))
    M.saveFleet()
  end
end

--- One heartbeat: tell every worker we are here and what of theirs we
--- have applied (acks), then take back the work of the silent ones.
function M.beat(now)
  -- Never acknowledge what is not written down. A worker discards what
  -- the host acknowledges; if the host then restarted from a file older
  -- than its acknowledgements, those messages would exist nowhere.
  if sb.dirty then M.saveFleet() end
  net.broadcast({ t = "beat", modem = cfg.hostModem, acks = sb:acks() },
                cfg.protocol)
  return M.expireLeases(now)
end

--- Take back the unfinished work of workers silent past the lease.
function M.expireLeases(now)
  now = now or util.now()
  local out = sb:expire(now, (cfg.claimLease or 300) * 1000,
    function(id) return workers[id] and workers[id].heardAt end, M.startedAt)
  for id, names in pairs(out) do
    if #names > 0 then
      console.warn(("[%d] silent too long; %d claim(s) returned"):format(id, #names))
    end
  end
  if next(out) then M.saveFleet() end
  return out
end

-- Fleet traffic: news through the outbox (in order, once), questions
-- answered directly.
local FLEET_MSG = { post = true, offer = true, claim = true, take = true,
                    finish = true, release = true, msg = true, gap = true }

function M.handleStray(id, msg)
  -- Anything from a worker is proof of life; the claim lease runs on this.
  if workers[id] then workers[id].heardAt = util.now() end

  -- Duplicates and early arrivals of numbered messages stop here.
  local note
  msg, note = sb:accept(id, msg)
  if note then console.warn(("[%d] %s"):format(id, note)) end
  if not msg then return end

  if FLEET_MSG[msg.t] then
    local note = sb:apply(id, msg)
    if note then console.warn(("[%d] %s"):format(id, note)) end
    -- Pool changes are saved at once; the board can wait for the
    -- listener's periodic save.
    if msg.t ~= "post" and msg.t ~= "gap" and sb.dirty then M.saveFleet() end
    return
  end

  if msg.t == "alive" then
    local w = workers[id]
    if w then w.distance, w.relay = msg.distance, msg.relay end
    sb:ackFrom(id, msg.ack, (cfg.resendAfter or 3) * 1000)
    return
  end

  local sink = sinks[id]
  if sink and msg.t == "output" then
    if sink.onOutput then sink.onOutput(msg.kind or "say", msg.text, msg.extra) end
    return
  end
  if sink and msg.t == "result" and msg.job == sink.job then
    if msg.situation and workers[id] then workers[id].situation = msg.situation end
    sink.result = msg
    if _G.os and os.queueEvent then os.queueEvent("ccagent_sink") end
    return
  end

  if msg.t == "hello" or msg.t == "state" then
    local isNew = workers[id] == nil
    workers[id] = workers[id] or {}
    workers[id].caps      = msg.caps or workers[id].caps
    workers[id].situation = msg.situation or workers[id].situation
    workers[id].label     = msg.label or workers[id].label
    workers[id].lastSeen  = os.clock()
    workers[id].heardAt   = util.now()
    if isNew or msg.t == "hello" then
      -- A hello is a worker (re)starting: whatever it knew of the fleet
      -- is gone, so it gets the current state.
      net.send(id, sb:snapshot(), cfg.protocol)
    end
    if isNew then
      console.head(("worker %d (%s) joined"):format(id, workers[id].label or "?"))
      target = target or id
      net.send(id, { t = "ack", text = "host " .. os.getComputerID() .. " here" },
               cfg.protocol)
    end
  elseif msg.t == "ask" then
    console.head(("worker %d asks: %s"):format(id, tostring(msg.text)))
    if msg.situation then
      workers[id] = workers[id] or {}
      workers[id].situation = msg.situation
    end
    M.dispatch(id, msg.text)
  elseif msg.t == "output" then
    -- Launched jobs arrive here: nothing is blocking on them, so this is
    -- the only place their progress is seen. Keep the latest line so /who
    -- can show where each probe is without scrolling back.
    local w = workers[id] or {}
    workers[id] = w
    w.last, w.lastSeen = tostring(msg.text), os.clock()
    local line = ("[%d] %s"):format(id, tostring(msg.text))
    if msg.kind == "warn" then console.warn(line) else console.say(line) end
  elseif msg.t == "result" then
    local w = workers[id] or {}
    workers[id] = w
    -- A "busy" refusal is about the job we tried to start, not the one
    -- still running there.
    local refused = not msg.ok and tostring(msg.error):match("^busy with")
    if not refused then w.busy = nil end
    w.lastSeen = os.clock()
    if msg.situation then w.situation = msg.situation end
    if msg.ok then
      console.head(("[%d] done in %.1fs"):format(id, msg.elapsed or 0))
    elseif msg.aborted then
      console.warn(("[%d] stopped"):format(id))
    else
      console.err(("[%d] %s"):format(id, util.clip(tostring(msg.error), 300)))
    end
    if not refused then
      w.last = msg.ok and "done" or (msg.aborted and "stopped" or "failed")
      M.jobEnded(id)
    end
  end
end

--- Start a program on several workers at once and return immediately.
--- /run waits for one worker to finish before the prompt comes back, and
--- `all` asks Claude once per worker and runs them one after another, so
--- neither can put a fleet to work at the same time. Output and the final
--- result come back through handleStray, prefixed with the worker's id.
function M.launch(src, ids, name)
  local sent = {}
  for _, id in ipairs(ids) do
    jobSeq = jobSeq + 1
    local w = workers[id] or {}
    workers[id] = w
    w.busy, w.last = name or ("j" .. jobSeq), "launched"
    -- So a probe launched into a fleet already at work starts out knowing
    -- what the others have claimed.
    net.send(id, sb:snapshot(), cfg.protocol)
    net.send(id, { t = "run", job = ("j%d"):format(jobSeq), src = src }, cfg.protocol)
    sent[#sent + 1] = id
  end
  return sent
end

--- "all", "3", "3,7,9" -> sorted ids, or nil and why.
function M.parseIds(spec, default)
  if spec == nil or spec == "" then
    return default and { default } or nil, "no worker selected"
  end
  if spec == "all" then
    local ids = util.keys(workers)
    if #ids == 0 then return nil, "no workers yet" end
    return ids
  end
  local ids = {}
  for part in spec:gmatch("[^,%s]+") do
    local n = tonumber(part)
    if not n then return nil, "not a worker id: " .. part end
    ids[#ids + 1] = n
  end
  if #ids == 0 then return nil, "no worker ids given" end
  return ids
end

net.onStray = function(id, msg)
  if not listening then M.handleStray(id, msg) end
end

--- For tests, which drive handleStray and launch without M.run.
function M.configure(c)
  cfg = c
  sb = newSwitchboard()
end

--------------------------------------------------------------- dispatch ---

function M.dispatch(id, text)
  local sess, err = sessionFor(id)
  if not sess then console.err(tostring(err)); return end
  local reusable = text:sub(1, 1) == "+"
  if reusable then text = util.trim(text:sub(2)) end
  poll(id)
  local r = sess:handle(text, { onEvent = events(), name = "w" .. id,
                                reusable = reusable })
  if not r then return end
  if r.ok then console.head(("[%d] done in %.1fs"):format(id, r.elapsed or 0))
  elseif r.aborted then console.warn(("[%d] stopped"):format(id))
  else console.err(("[%d] %s"):format(id, util.clip(tostring(r.error), 300))) end
end

---------------------------------------------------------------- commands --

local HELP = {
  "@<id> <request>   send a request to one worker",
  "all <request>     send the same request to every worker",
  "/use <id>         set the default worker",
  "/who              list workers",
  "/poll             refresh every worker's state",
  "/state [id]       show a worker's state",
  "@<id> +<request>  ask for a REUSABLE routine",
  "/dry <request>    write a program for the current worker, do not run it",
  "/code             last program for the current worker",
  "/again            re-run it (no API call)",
  "/save <name>      save it",
  "/run <name> [id]  send a saved program (no API call)",
  "/launch <name> all|id,id  start it on many at once",
  "/register <name>  make a saved program callable by Claude",
  "/expose <n> on|off   show or hide it in the prompt",
  "/unregister <n>   revoke it",
  "/check <name>     lint a saved program without registering",
  "/jobs [name]      list saved programs, or describe one",
  "/stop [id|all]    abort a running job",
  "/share [id]       save, then post, a worker's last run",
  "/forget [id|all] [x,y,z]  restart a worker's map here",
  "/fleet            board, claims and link per worker",
  "/fleet work       every piece of work and who has it",
  "/fleet tell <ids|all> <topic> [text]  message programs",
  "/fleet relay <id> on|off  make a worker repeat rednet",
  "/fleet reset      clear work and board",
  "/manifest         the API workers are given, and its token cost",
  "/notes <text>     house rules appended to the system prompt",
  "/model [id]       show or change the model",
  "/reset [id]       clear a worker's conversation",
  "/stats",
  "/exit",
}

-- Command words from HELP, so the two cannot drift apart.
local COMMAND_WORDS = {}
for _, entry in ipairs(HELP) do
  local name = entry:match("^/(%a[%w_]*)")
  if name then COMMAND_WORDS[name] = true end
end

local function command(input)
  local cmd, rest = input:match("^/(%S+)%s*(.*)$")
  if not cmd then return false end
  cmd = cmd:lower()

  if cmd == "help" or cmd == "?" then
    for _, l in ipairs(HELP) do console.dim(l) end

  elseif cmd == "who" then
    if not next(workers) then console.dim("no workers yet") end
    for _, id in ipairs(util.keys(workers)) do
      local w = workers[id]
      local what = w.busy
        and ("[" .. tostring(w.busy) .. "] " .. tostring(w.last or ""))
        or ((w.situation or ""):match("^[^\n]*") or "")
      console.dim(("%s%-4s %-14s %s"):format(
        tonumber(id) == target and "*" or " ", tostring(id),
        w.label or "?", what))
    end

  elseif cmd == "use" then
    local id = tonumber(rest)
    if not id then console.warn("usage: /use <id>")
    else target = id; workers[id] = workers[id] or {}; poll(id)
         console.head("addressing worker " .. id) end

  elseif cmd == "poll" then
    for id in pairs(workers) do poll(id, 2) end
    console.dim("polled " .. util.count(workers) .. " workers")

  elseif cmd == "state" then
    local id = tonumber(rest) or target
    local w = id and poll(id)
    console.info(w and (w.situation or "(no state)") or "no such worker")

  elseif cmd == "manifest" then
    local tokens, chars = registry.manifestCost()
    console.info(registry.manifest())
    console.head(("~%d tokens (%d chars), cached after the first request")
      :format(tokens, chars))

  elseif cmd == "code" or cmd == "again" or cmd == "save" or cmd == "reset" then
    local sess = target and sessionFor(target)
    if not sess then console.warn("no worker selected (/use <id>)")
    elseif cmd == "code" then
      if sess.lastCode then console.code(sess.lastCode, 200) else console.warn("nothing yet") end
    elseif cmd == "again" then
      local r = sess:rerun({ onEvent = events() })
      if r and not r.ok then console.err(tostring(r.error)) end
    elseif cmd == "save" then
      if rest == "" or not sess.lastCode then console.warn("usage: /save <name> (after a run)")
      else jobs.save(rest, sess.lastCode); console.head("saved as " .. rest) end
    elseif cmd == "reset" then
      sess:reset(); console.head("conversation cleared")
    end

  elseif cmd == "run" then
    local name, idStr = rest:match("^(%S+)%s*(%S*)$")
    local id = tonumber(idStr) or target
    local src = name and jobs.load(name)
    if not src then console.err("no saved job called " .. tostring(name))
    elseif not id then console.warn("no worker selected")
    else
      console.status(("sending %s to worker %d"):format(name, id))
      local r = remoteRun(id)(src, { onOutput = function(k, t) console.say(t) end })
      if r.ok then console.head("done") else console.err(tostring(r.error)) end
    end

  elseif cmd == "dry" then
    -- The way to get a program for /launch without first running it to
    -- completion on one worker: written against the current worker's
    -- state and capabilities, then /save and /launch it.
    local sess = target and sessionFor(target)
    if rest == "" then console.warn("usage: /dry <request>")
    elseif not sess then console.warn("no worker selected (/use <id>)")
    else
      local reusable = rest:sub(1, 1) == "+"
      if reusable then rest = util.trim(rest:sub(2)) end
      poll(target)
      local r = sess:handle(rest, { onEvent = events(), name = "w" .. target,
                                    reusable = reusable, dryRun = true })
      if r and r.ok then console.head("not run. /save <name>, then /launch <name> all")
      elseif r then console.err(util.clip(tostring(r.error), 300)) end
    end

  elseif cmd == "forget" then
    -- "/forget 2 1,0,0": worker 2 stands at 1,0,0 of a shared frame,
    -- facing "north". Probes placed in a row, all facing the same way and
    -- each told its offset, then agree on what a position means -- which
    -- is what makes the positions they post to the fleet comparable.
    local spec, at = rest:match("^(%S*)%s*(%S*)$")
    local origin
    if at and at ~= "" then
      local x, y, z = at:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
      if not x then console.warn("position is x,y,z, e.g. 2,0,0"); return true end
      origin = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    end
    local ids, err = M.parseIds(spec, target)
    if not ids then console.warn(err)
    elseif origin and #ids > 1 then
      console.warn("one worker per position: /forget <id> x,y,z")
    else
      for _, id in ipairs(ids) do
        net.send(id, { t = "forget", origin = origin }, cfg.protocol)
      end
      console.warn("forget sent to " .. table.concat(ids, ","))
      console.dim(origin and ("it now stands at " .. at .. ", facing north")
                         or "each now treats its spot as 0,0,0")
    end

  elseif cmd == "fleet" then
    local sub, args = rest:match("^(%S*)%s*(.-)%s*$")
    if sub == "reset" then
      M.fleetReset()
      for wid in pairs(workers) do net.send(wid, M.fleetSnapshot(), cfg.protocol) end
      console.head("fleet work and board cleared")

    elseif sub == "tell" then
      -- "/fleet tell all recall", "/fleet tell 3,7 come home now": a
      -- message from the operator into running programs, which read it
      -- with fleet.receive. Queued and re-sent until each worker has it.
      local spec, topic, text = args:match("^(%S+)%s+(%S+)%s*(.-)$")
      local ids = spec and M.parseIds(spec)
      if not (ids and topic) then
        console.warn("usage: /fleet tell <id|all|ids> <topic> [text]")
      else
        sb:deliver("operator", ids, topic, text ~= "" and text or nil)
        M.saveFleet()
        console.head(("'%s' sent to %s"):format(topic, table.concat(ids, ",")))
      end

    elseif sub == "relay" then
      local spec, onoff = args:match("^(%S+)%s*(%S*)$")
      local ids = spec and M.parseIds(spec)
      if not ids then console.warn("usage: /fleet relay <id> on|off")
      else
        local on = onoff ~= "off"
        for _, id in ipairs(ids) do
          net.send(id, { t = "relay", on = on }, cfg.protocol)
        end
        console.head(("relay %s sent to %s"):format(on and "on" or "off",
                                                     table.concat(ids, ",")))
      end

    elseif sub == "work" then
      local p = sb.pool
      local names = util.keys(p.items)
      for name in pairs(p.claims) do if not p.items[name] then names[#names + 1] = name end end
      table.sort(names)
      local c = sb:counts()
      console.info(("%d open, %d taken, %d done"):format(c.open, c.taken, c.done))
      for i, name in ipairs(names) do
        if i > 40 then console.dim(("... %d more"):format(#names - 40)); break end
        local holder = p.claims[name]
        local state = p.done[name] and ("done by " .. tostring(holder))
          or (holder and ("taken by " .. tostring(holder)) or "open")
        console.dim(("%-20s %s"):format(name, state))
      end

    elseif sub == "" then
      local any = false
      for _, id in ipairs(util.keys(sb.board)) do
        any = true
        local e = sb.board[id]
        local bits = {}
        for _, k in ipairs(util.keys(e.facts)) do
          local v = e.facts[k]
          if type(v) == "table" and v.x then
            v = ("%s,%s,%s"):format(tostring(v.x), tostring(v.y), tostring(v.z))
          elseif type(v) == "table" then v = "{...}" end
          bits[#bits + 1] = k .. "=" .. tostring(v)
        end
        console.dim(("%-4s %s"):format(tostring(id), table.concat(bits, " ")))
      end
      local per, fin = {}, {}
      for name, holder in pairs(sb.pool.claims) do
        if sb.pool.done[name] then fin[holder] = (fin[holder] or 0) + 1
        else per[holder] = (per[holder] or 0) + 1 end
      end
      local now = util.now()
      for _, id in ipairs(util.keys(workers)) do
        local w = workers[id]
        local heard = w.heardAt and math.floor((now - w.heardAt) / 1000)
        if per[id] or fin[id] or heard then
          any = true
          local q = sb:queued(id)
          console.dim(("%-4s %d active, %d done; heard %s%s%s%s"):format(
            tostring(id), per[id] or 0, fin[id] or 0,
            heard and (heard .. "s ago") or "never",
            w.distance and (", " .. math.floor(w.distance) .. " blocks") or "",
            w.relay and ", RELAY" or "",
            q > 0 and (", " .. q .. " msg queued") or ""))
        end
      end
      local c = sb:counts()
      if c.open + c.taken + c.done > 0 then
        any = true
        console.info(("work: %d open, %d taken, %d done (/fleet work)")
          :format(c.open, c.taken, c.done))
      end
      if not any then console.dim("nothing posted or claimed yet") end
    else
      console.warn("usage: /fleet [work|reset|tell|relay]")
    end

  elseif cmd == "share" then
    -- The worker holds the evidence (its program, output, log and the
    -- trail of where it went), so ask it; the host adds the request and
    -- model that produced the program. Saved to a file first, so a
    -- report exists even where nothing should be posted.
    local id = tonumber(rest) or target
    if not id then console.warn("usage: /share <id>"); return true end
    net.send(id, { t = "report" }, cfg.protocol)
    local msg = net.await(id, "report", 10, cfg.protocol)
    if not msg then console.err("worker " .. id .. " did not answer"); return true end
    local text = tostring(msg.text)
    local w = workers[id] or {}
    local head = { ("worker %d (%s)"):format(id, tostring(w.label or "?")),
                   "host: " .. agent.VERSION }
    local okO, origin = pcall(require, "ui.origin")
    if okO then head[#head + 1] = "host " .. tostring(origin.line({ always = true })) end
    if w.session and w.session.lastCode then
      local st = require("claude.client").settings(cfg)
      head[#head + 1] = ("model: %s effort %s"):format(st.model, st.effort)
    end
    text = table.concat(head, "\n") .. "\n" .. text

    local share = require("ui.share")
    if share.carriesSecret(text, cfg.apiKey) then
      console.err("report contains the api key; not sent")
      return true
    end
    local path = ("/ccagent/reports/w%d.txt"):format(id)
    if _G.fs then
      fs.makeDir("/ccagent/reports")
      local h = fs.open(path, "w")
      if h then h.write(text); h.close(); console.head("saved " .. path) end
    end
    if not cfg.share or not cfg.share.url or cfg.share.url == "" then
      console.dim("share.url not set; not posting")
    else
      console.info(("%d chars, incl. positions"):format(#text))
      if not (cfg.share.redact and #cfg.share.redact > 0) then
        console.dim("no redact rules set")
      end
      local yn = console.ask("post it publicly? [y/N] ")
      if yn and yn:lower():sub(1, 1) == "y" then
        console.status("posting...")
        local where, err = share.send(cfg.share, text)
        if where then console.say(where) else console.err(tostring(err)) end
      end
    end

  elseif cmd == "launch" then
    local name, spec = rest:match("^(%S+)%s*(.-)%s*$")
    local src = name and jobs.load(name)
    local ids, err = M.parseIds(spec, target)
    if not src then console.err("no saved job called " .. tostring(name))
    elseif not ids then console.warn(err .. "  (usage: /launch <name> all|id,id)")
    else
      local sent = M.launch(src, ids, name)
      local list = {}
      for i, id in ipairs(sent) do list[i] = tostring(id) end
      console.head(("%s -> %s"):format(name, table.concat(list, ",")))
      console.dim("/who for status, /stop all to recall the lot")
    end

  elseif cmd == "jobs" then
    if rest ~= "" then
      local doc = agent.lib.doc(rest)
      console.info(doc or (rest .. " has no contract (saved as a one-off)"))
    else
      local rows = jobs.table()
      if #rows == 0 then console.dim("no saved jobs")
      else for _, e in ipairs(rows) do console.dim(jobs.row(e)) end end
    end

  elseif cmd == "register" or cmd == "unregister" or cmd == "expose"
         or cmd == "check" then
    -- The library is shared by the whole fleet, so these are host-level,
    -- not per-worker. Every worker's cached prefix is rebuilt after a
    -- change; that costs one cache write each, then rides free again.
    local out = { head = console.head, warn = console.warn,
                  err = console.err, dim = console.dim }
    if cmd == "register" then
      local res = jobs.register(rest)
      jobs.report(rest, res, out)
      if res.needsRetrofit then
        local sess = target and sessionFor(target)
        if not sess then console.warn("select a worker first to retrofit (/use <id>)")
        else
          local yn = console.ask("promote it? one API call. [y/N] ")
          if yn and yn:lower():sub(1, 1) == "y" then
            local newSrc, err = sess:retrofit(rest, jobs.load(rest),
              agent.lint.report(res.findings or {}))
            if not newSrc then console.err(tostring(err))
            else
              console.code(newSrc)
              jobs.save(rest, newSrc)
              agent.lib.invalidate()
              jobs.report(rest, jobs.register(rest), out)
            end
          end
        end
      end
    elseif cmd == "unregister" then
      local ok, err = jobs.unregister(rest)
      console.info(ok and ("unregistered " .. rest) or tostring(err))
    elseif cmd == "expose" then
      local name, onoff = rest:match("^(%S+)%s*(%S*)$")
      local on = onoff == "" or onoff == "on" or onoff == "true"
      local ok, err = jobs.expose(name, on)
      console.info(ok and ((name or "?") .. " is now " ..
                   (on and "listed" or "unlisted")) or tostring(err))
    else
      local res, err = jobs.check(rest)
      if not res then console.err(tostring(err))
      else
        console.info(agent.lint.report(res.findings))
        for _, e in ipairs(res.errors or {}) do console.err(e) end
        for _, w in ipairs(res.warnings or {}) do console.warn(w) end
      end
    end
    for _, w in pairs(workers) do
      if w.session then w.session:buildSystem() end
    end

  elseif cmd == "stop" then
    local ids, err = M.parseIds(rest, target)
    if not ids then console.warn(err)
    else
      for _, id in ipairs(ids) do net.send(id, { t = "abort" }, cfg.protocol) end
      console.warn("abort sent to " .. table.concat(ids, ","))
    end

  elseif cmd == "notes" then
    if rest == "" then console.dim(cfg.operatorNotes or "(none)")
    else
      cfg.operatorNotes = rest
      for _, w in pairs(workers) do if w.session then w.session:buildSystem(true) end end
      console.head("notes updated")
    end

  elseif cmd == "model" then
    if rest == "" then console.dim(cfg.model) else cfg.model = rest; console.head("model: " .. rest) end

  elseif cmd == "stats" then
    for _, id in ipairs(util.keys(workers)) do
      local w = workers[id]
      if w.session then console.dim(("%s: %s"):format(tostring(id), w.session:statsLine())) end
    end

  elseif cmd == "exit" or cmd == "quit" then
    running = false

  else
    console.warn("unknown command: /" .. cmd .. "  (/help)")
  end
  return true
end

------------------------------------------------------------------- main ---

local function prompt()
  local history = {}
  while running do
    local input = console.ask(console.promptFor(target), history)
    if input == nil then running = false; break end
    input = util.trim(input)
    if input ~= "" then
      history[#history + 1] = input
      local slipped = console.forgottenSlash(input, COMMAND_WORDS)
      if slipped then
        console.warn(("'%s' is a command: /%s"):format(slipped, slipped))
        local yn = console.ask("ask Claude instead? [y/N] ")
        if not tostring(yn or ""):lower():match("^y") then input = "" end
      end
      if input == "" then
      elseif not command(input) then
        local id, rest = input:match("^@(%d+)%s+(.+)$")
        if id then
          target = tonumber(id)
          workers[target] = workers[target] or {}
          M.dispatch(target, rest)
        elseif input:match("^all%s+") then
          local text = input:match("^all%s+(.+)$")
          for wid in pairs(workers) do M.dispatch(wid, text) end
        elseif target then
          M.dispatch(target, input)
        else
          console.warn("no worker selected -- /who, then /use <id>")
        end
      end
    end
  end
end

--- Background listener so workers can join, and relay requests, while the
--- operator is typing.
local function listen()
  listening = true
  M.startedAt = util.now()
  local lastBeat, lastSave = -math.huge, util.now()
  while running do
    -- The heartbeat is what makes silence mean something: a worker that
    -- has heard nothing for three beats knows it is out of contact, and
    -- one that stops answering lets the host take its claims back.
    local now = util.now()
    if now - lastBeat >= (cfg.heartbeat or 10) * 1000 then
      lastBeat = now
      M.beat(now)
    end
    if sb.dirty and now - lastSave >= 10000 then
      lastSave = now
      M.saveFleet()
    end
    local id, msg = net.receive(math.min(5, cfg.heartbeat or 10), cfg.protocol)
    if id and msg then M.handleStray(id, msg) end
  end
  listening = false
end

function M.run()
  cfg = config.load()
  if not config.hasKey(cfg) then
    console.head("ccagent host needs an Anthropic API key.")
    local key = console.ask("key> ")
    if not key or util.trim(key) == "" then return end
    require("claude.config").saveKey(key)
    cfg = config.load()
  end

  console.head("ccagent host " .. agent.VERSION)
  agent.boot({ calibrate = false })
  net.protocol = cfg.protocol

  local ok, err = net.open()
  if not ok then console.err("no modem: " .. tostring(err)); return end
  if rednet.host then pcall(rednet.host, cfg.protocol, cfg.hostname) end

  sb = newSwitchboard()
  if M.loadFleet() then
    local c = sb:counts()
    console.dim(("fleet restored: %d open, %d taken, %d done; /fleet reset clears")
      :format(c.open, c.taken, c.done))
  end
  net.broadcast({ t = "hostup" }, cfg.protocol)
  console.dim("announced as '" .. cfg.hostname .. "'. waiting for workers... (/help)")

  if _G.parallel then parallel.waitForAny(listen, prompt) else prompt() end
  console.dim("bye.")
end

if not _TEST then M.run() end

return M
