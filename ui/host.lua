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

-- The fleet board (agent/fleet.lua): the latest facts each worker posted,
-- and who holds each claimed piece of work. The host is the only place
-- these are decided, which is what makes a claim safe: it handles one
-- message at a time, so two workers can never both be granted a name.
local fleetBoard  = {}   -- [id] = { label=, at=ms, facts = {key=value} }
local fleetClaims = {}   -- [name] = id
local fleetDone   = {}   -- [name] = true: finished, never handed out again

-- Kept on disk because the host is a computer in a chunk like any other:
-- an unload wipes memory, and a fleet that forgets its claims sends the
-- next probe into a wing that was already searched.
local FLEET_FILE = "/.ccagent/fleet.dat"

-- True while listen() runs. rednet delivers every message to every
-- coroutine waiting for one, so with the listener up, a second handler
-- in remoteRun or net.await handles the same message twice -- a claim
-- answered twice, a post relayed twice, a line printed twice.
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

--- Send a program to a worker and pump its output until it reports back.
-- While a job is in flight the background listener must not also consume
-- and re-print that worker's traffic: rednet events are delivered to every
-- coroutine, so without this you see every line twice.
local busyWith = {}

local function remoteRun(id)
  return function(code, opts)
    jobSeq = jobSeq + 1
    local jobId = ("j%d"):format(jobSeq)
    busyWith[id] = true
    net.send(id, { t = "run", job = jobId, src = code }, cfg.protocol)

    local deadline = os.clock() + (cfg.jobTimeout or 900)
    while os.clock() < deadline do
      local from, msg = net.receive(5, cfg.protocol)
      if from == id and msg then
        if msg.t == "output" then
          if opts and opts.onOutput then
            opts.onOutput(msg.kind or "say", msg.text, msg.extra)
          end
        elseif msg.t == "result" and msg.job == jobId then
          if msg.situation and workers[id] then workers[id].situation = msg.situation end
          busyWith[id] = nil
          M.jobEnded(id)
          return {
            ok = msg.ok, error = msg.error, output = msg.output,
            result = msg.result, aborted = msg.aborted, elapsed = msg.elapsed,
          }
        elseif msg.t ~= "result" and not listening then
          M.handleStray(from, msg)
        end
      elseif from and msg and not listening then
        M.handleStray(from, msg)
      end
    end
    busyWith[id] = nil
    return { ok = false, error = "worker did not report back in time" }
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

--- Send a fleet message to every worker but one.
local function relay(except, msg)
  for wid in pairs(workers) do
    if wid ~= except then net.send(wid, msg, cfg.protocol) end
  end
end

--- Everything a worker needs to join a fleet already in progress. Ages,
--- not timestamps: clocks differ between computers.
function M.fleetSnapshot()
  local board, now = {}, util.now()
  for id, e in pairs(fleetBoard) do
    board[id] = { label = e.label, facts = e.facts,
                  age = math.floor((now - (e.at or now)) / 1000) }
  end
  return { t = "fleet", kind = "snapshot", board = board, claims = fleetClaims,
           done = fleetDone }
end

function M.fleetState() return fleetBoard, fleetClaims, fleetDone end

--------------------------------------------------------- persistence ----

local fleetDirty = false

function M.saveFleet()
  fleetDirty = false
  if not (_G.fs and _G.textutils) then return end
  local h = fs.open(FLEET_FILE, "w")
  if not h then return end
  h.write(textutils.serialize({ board = fleetBoard, claims = fleetClaims,
                                done = fleetDone }))
  h.close()
end

function M.loadFleet()
  if not (_G.fs and _G.textutils and fs.exists(FLEET_FILE)) then return false end
  local h = fs.open(FLEET_FILE, "r")
  if not h then return false end
  local ok, data = pcall(textutils.unserialize, h.readAll() or "")
  h.close()
  if not ok or type(data) ~= "table" then return false end
  fleetBoard, fleetClaims, fleetDone =
    data.board or {}, data.claims or {}, data.done or {}
  -- Timestamps are this computer's clock from before the restart; the
  -- board's ages start over rather than pretend to know.
  for _, e in pairs(fleetBoard) do e.at = util.now() end
  return true
end

function M.fleetReset()
  fleetBoard, fleetClaims, fleetDone = {}, {}, {}
  M.saveFleet()
end

--- Hand back every claim a worker holds and has not finished. Returns
--- the names. Called when its job ends, and when it goes silent.
function M.releaseUnfinished(id)
  local freed = {}
  for name, holder in pairs(fleetClaims) do
    if holder == id and not fleetDone[name] then freed[#freed + 1] = name end
  end
  table.sort(freed)
  for _, name in ipairs(freed) do
    fleetClaims[name] = nil
    relay(id, { t = "fleet", kind = "release", name = name, holder = id })
  end
  if #freed > 0 then M.saveFleet() end
  return freed
end

--- A job ending leaves nothing in progress: whatever it claimed and did
--- not finish goes back to the pool, so the next probe can take it.
function M.jobEnded(id)
  local freed = M.releaseUnfinished(id)
  if #freed > 0 then
    console.dim(("[%d] %d unfinished claim(s) returned"):format(id, #freed))
  end
end

--- Take back the unfinished claims of workers not heard from within the
--- lease: stuck, out of range, or unloaded. Their work is presumed not
--- happening. Returns { [id] = {names} }.
function M.expireLeases(now, lease)
  now, lease = now or util.now(), (lease or cfg.claimLease or 300) * 1000
  local out = {}
  local holders = {}
  for name, holder in pairs(fleetClaims) do
    if not fleetDone[name] then holders[holder] = true end
  end
  for id in pairs(holders) do
    local w = workers[id]
    -- Silence is counted from when this host could first have heard: a
    -- host back from a restart has heard nobody yet, and taking every
    -- claim from probes still at work would be the opposite of the point.
    local heard = (w and w.heardAt) or M.startedAt or now
    if now - heard > lease then
      out[id] = M.releaseUnfinished(id)
    end
  end
  return out
end

local function handleFleet(id, msg)
  local label = workers[id] and workers[id].label
  if msg.t == "post" then
    local e = fleetBoard[id] or { facts = {} }
    fleetBoard[id] = e
    e.label = label
    e.at = util.now()
    e.facts[tostring(msg.key)] = msg.value
    fleetDirty = true
    relay(id, { t = "fleet", kind = "post", from = id, label = label,
                key = msg.key, value = msg.value })
  elseif msg.t == "claim" then
    local name = tostring(msg.name)
    local holder = fleetClaims[name]
    local ok = (holder == nil or holder == id) and not (fleetDone[name] and holder ~= id)
    if ok then fleetClaims[name] = id; holder = id end
    net.send(id, { t = "claimed", req = msg.req, name = name, ok = ok,
                   holder = holder, done = fleetDone[name] }, cfg.protocol)
    if ok then
      relay(id, { t = "fleet", kind = "claim", name = name, holder = id })
      M.saveFleet()
    end
  elseif msg.t == "finish" then
    local name = tostring(msg.name)
    if fleetClaims[name] == nil or fleetClaims[name] == id then
      fleetClaims[name], fleetDone[name] = id, true
      relay(id, { t = "fleet", kind = "finish", name = name, holder = id })
      M.saveFleet()
    end
  elseif msg.t == "release" then
    local name = tostring(msg.name)
    if fleetClaims[name] == id and not fleetDone[name] then
      fleetClaims[name] = nil
      relay(id, { t = "fleet", kind = "release", name = name, holder = id })
      M.saveFleet()
    end
  elseif msg.t == "alive" then
    if workers[id] then workers[id].distance = msg.distance end
  end
end

function M.handleStray(id, msg)
  -- Anything from a worker is proof of life; the claim lease runs on this.
  if workers[id] then workers[id].heardAt = util.now() end
  if msg.t == "post" or msg.t == "claim" or msg.t == "release"
     or msg.t == "finish" or msg.t == "alive" then
    return handleFleet(id, msg)
  end
  if busyWith[id] and (msg.t == "output" or msg.t == "result") then
    return   -- remoteRun owns this worker's stream right now
  end
  if msg.t == "hello" or msg.t == "state" then
    local isNew = workers[id] == nil
    workers[id] = workers[id] or {}
    workers[id].caps      = msg.caps or workers[id].caps
    workers[id].situation = msg.situation or workers[id].situation
    workers[id].label     = msg.label or workers[id].label
    workers[id].lastSeen  = os.clock()
    workers[id].heardAt   = util.now()
    if isNew then
      console.head(("worker %d (%s) joined"):format(id, workers[id].label or "?"))
      target = target or id
      net.send(id, { t = "ack", text = "host " .. os.getComputerID() .. " here" },
               cfg.protocol)
      net.send(id, M.fleetSnapshot(), cfg.protocol)
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
    net.send(id, M.fleetSnapshot(), cfg.protocol)
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
function M.configure(c) cfg = c end

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
  "/fleet [reset]    what workers posted and claimed",
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
    if rest == "reset" then
      M.fleetReset()
      for wid in pairs(workers) do net.send(wid, M.fleetSnapshot(), cfg.protocol) end
      console.head("fleet board and claims cleared")
    else
      local any = false
      for _, id in ipairs(util.keys(fleetBoard)) do
        any = true
        local e = fleetBoard[id]
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
      for name, holder in pairs(fleetClaims) do
        if fleetDone[name] then fin[holder] = (fin[holder] or 0) + 1
        else per[holder] = (per[holder] or 0) + 1 end
      end
      local now = util.now()
      for _, id in ipairs(util.keys(workers)) do
        local w = workers[id]
        local heard = w.heardAt and math.floor((now - w.heardAt) / 1000)
        if per[id] or fin[id] or heard then
          any = true
          console.dim(("%-4s %d active, %d done; heard %s%s"):format(
            tostring(id), per[id] or 0, fin[id] or 0,
            heard and (heard .. "s ago") or "never",
            w.distance and (", " .. math.floor(w.distance) .. " blocks") or ""))
        end
      end
      if not any then console.dim("nothing posted or claimed yet") end
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
      net.broadcast({ t = "beat", modem = cfg.hostModem }, cfg.protocol)
      for id, names in pairs(M.expireLeases(now)) do
        if #names > 0 then
          console.warn(("[%d] silent too long; %d claim(s) returned")
            :format(id, #names))
        end
      end
    end
    if fleetDirty and now - lastSave >= 10000 then
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

  if M.loadFleet() then
    local n = 0
    for _ in pairs(fleetClaims) do n = n + 1 end
    console.dim(("fleet state restored: %d claim(s); /fleet reset to clear"):format(n))
  end
  net.broadcast({ t = "hostup" }, cfg.protocol)
  console.dim("announced as '" .. cfg.hostname .. "'. waiting for workers... (/help)")

  if _G.parallel then parallel.waitForAny(listen, prompt) else prompt() end
  console.dim("bye.")
end

if not _TEST then M.run() end

return M
