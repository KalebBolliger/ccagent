--[[ agent/pool.lua -------------------------------------------------------
  The rules for shared work, with no I/O in them.

  An item of work has a name, optionally some data (a position, a note),
  and one of three states:

      open    offered, nobody has it
      taken   one worker holds it            (claims[name] = holder)
      done    finished; stays taken for good (done[name] = true)

  Anything can become taken without having been offered -- fleet.claim on
  a name nobody mentioned is how the simplest programs divide work -- and
  releasing an offered item puts it back to open, data intact, so another
  worker can take it.

  The host runs one of these as the single source of truth; every worker
  keeps one as a cache of what it has heard; a worker with no host uses
  its own as the truth. Same rules in all three places, so a program
  behaves the same with one probe or twenty.
--------------------------------------------------------------------------]]

local pool = {}

function pool.new()
  return { items = {}, order = {}, claims = {}, done = {}, nextOrder = 1 }
end

local function known(p, name)
  return p.items[name] ~= nil or p.claims[name] ~= nil or p.done[name] ~= nil
end

--- Add a piece of work. Offering a name that is already known (offered,
--- taken or done) changes nothing, so every worker in a fleet can offer
--- the same list on start-up and the first one to arrive wins.
--- Returns true if it was new.
function pool.offer(p, name, data)
  name = tostring(name)
  if known(p, name) then return false end
  p.items[name] = { data = data, order = p.nextOrder }
  p.nextOrder = p.nextOrder + 1
  return true
end

--- Take a specific name. ok, holder. Already yours counts.
function pool.claim(p, name, id)
  name = tostring(name)
  local holder = p.claims[name]
  if holder == nil and not p.done[name] then
    p.claims[name] = id
    return true, id
  end
  return holder == id, holder
end

local function dist(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return nil end
  if not (a.x and b.x) then return nil end
  return math.abs(a.x - b.x) + math.abs((a.y or 0) - (b.y or 0))
       + math.abs(a.z - b.z)
end

--- Take the best open item for this worker: highest data.priority first,
--- then nearest to `near` when items carry data.pos, then oldest. Returns
--- name, data -- or nil when nothing is open.
function pool.take(p, id, near)
  local best, bestKey
  for name, it in pairs(p.items) do
    if p.claims[name] == nil and not p.done[name] then
      local d = it.data
      local pri = type(d) == "table" and tonumber(d.priority) or 0
      local far = near and type(d) == "table" and dist(d.pos, near) or nil
      -- Lower key wins: priority (negated), then distance, then age.
      local key = { -pri, far or math.huge, it.order }
      local better = not bestKey
      if not better then
        for i = 1, 3 do
          if key[i] ~= bestKey[i] then better = key[i] < bestKey[i]; break end
        end
      end
      if better then best, bestKey = name, key end
    end
  end
  if not best then return nil end
  p.claims[best] = id
  return best, p.items[best].data
end

--- Finish a name. Only its holder, or anyone if nobody holds it.
function pool.finish(p, name, id)
  name = tostring(name)
  local holder = p.claims[name]
  if holder ~= nil and holder ~= id then return false end
  p.claims[name], p.done[name] = id, true
  return true
end

--- Give a name back. Only its holder, and never once done.
function pool.release(p, name, id)
  name = tostring(name)
  if p.claims[name] ~= id or p.done[name] then return false end
  p.claims[name] = nil
  return true
end

--- Every unfinished name a worker holds, released. Returns the names.
function pool.releaseAll(p, id)
  local freed = {}
  for name, holder in pairs(p.claims) do
    if holder == id and not p.done[name] then freed[#freed + 1] = name end
  end
  table.sort(freed)
  for _, name in ipairs(freed) do p.claims[name] = nil end
  return freed
end

--- { open=, taken=, done= }. Counts are never nil, and a caller wanting
--- "is there work left" should read open + taken: taken work comes back
--- to the pool if its holder fails.
function pool.counts(p)
  local c = { open = 0, taken = 0, done = 0 }
  for name in pairs(p.items) do
    if p.done[name] then
    elseif p.claims[name] ~= nil then
    else c.open = c.open + 1 end
  end
  for name in pairs(p.claims) do
    if p.done[name] then c.done = c.done + 1 else c.taken = c.taken + 1 end
  end
  -- done without a recorded holder (finished by a worker that never
  -- claimed it) still counts as done
  for name in pairs(p.done) do
    if p.claims[name] == nil then c.done = c.done + 1 end
  end
  return c
end

--- Plain tables for the wire and for disk.
function pool.export(p)
  return { items = p.items, claims = p.claims, done = p.done,
           nextOrder = p.nextOrder }
end

function pool.import(t)
  local p = pool.new()
  if type(t) ~= "table" then return p end
  p.items, p.claims, p.done = t.items or {}, t.claims or {}, t.done or {}
  p.nextOrder = t.nextOrder or 1
  for _, it in pairs(p.items) do
    if (it.order or 0) >= p.nextOrder then p.nextOrder = it.order + 1 end
  end
  return p
end

return pool
