--[[ /ccagent/boot.lua ---------------------------------------------------
  One command to put ccagent on a CC:Tweaked computer or turtle.

  On a bare machine, in-game:

      wget run https://raw.githubusercontent.com/KalebBolliger/ccagent/main/boot.lua

  That is the whole bootstrap. It fetches manifest.txt, pulls every file
  the manifest lists into /ccagent, then hands off to install.lua for the
  local half of the job (directories, API key, launcher, self-check).

  Afterwards the same thing is one word, from anywhere:

      ccagent update

  because the source it came from is remembered in /.ccagent/source.

  Options, any order, all optional:

      --repo owner/name        default KalebBolliger/ccagent
      --ref  branch|tag|sha    default main
      --url  https://host/dir  any static mirror of the tree; wins over repo/ref
      --startup worker|host|solo   also write a /startup.lua (see install.lua)
      --force                  replace config.lua too, instead of keeping yours
      --no-setup               download only; do not run install.lua

  A bare argument is read as a url if it looks like one, a repo if it looks
  like owner/name, otherwise a ref -- so `boot v1.1.1` works. A branch whose
  name contains a slash needs the explicit --ref.

  Arguments are for the saved-file form (`wget <url> boot.lua`, then
  `boot <args>`): `wget run` is not guaranteed to forward them. And note
  that this file always defaults to main no matter which ref you fetched it
  from -- it cannot see its own url -- so pass the ref if you want a
  particular one. It prints the base it settled on before fetching anything.

  Nothing is written until every file has been fetched, so a mid-way network
  failure leaves the existing install alone rather than half-replaced.

  /ccagent is not configurable here: agent/lib.lua and claude/config.lua
  address it by absolute path.
--------------------------------------------------------------------------]]

local DIR          = "/ccagent"
local SOURCE       = "/.ccagent/source"
local MANIFEST     = "manifest.txt"
local DEFAULT_REPO = "KalebBolliger/ccagent"
local DEFAULT_REF  = "main"

local unpack = table.unpack or unpack

local USAGE = [[
ccagent bootstrap

  boot                       re-pull from the remembered source
  boot <ref>                 a branch, tag or commit of the default repo
  boot --repo owner/name [--ref r]
  boot --url https://host/ccagent

  --startup worker|host|solo   write /startup.lua as well
  --force                      overwrite config.lua too
  --no-setup                   download only
]]

------------------------------------------------------------------ args ---

local args = { ... }
local repo, ref, url, startup
local force, setup = false, true
local given = false

local i = 1
local function nextArg(what)
  i = i + 1
  if not args[i] then error(what .. " needs a value", 0) end
  return args[i]
end

while i <= #args do
  local a = args[i]
  if a == "--repo" then repo = nextArg("--repo"); given = true
  elseif a == "--ref" then ref = nextArg("--ref"); given = true
  elseif a == "--url" then url = nextArg("--url"); given = true
  elseif a == "--startup" then startup = nextArg("--startup")
  elseif a == "--force" then force = true
  elseif a == "--no-setup" then setup = false
  elseif a == "-h" or a == "--help" then print(USAGE); return
  elseif a:match("^https?://") then url = a; given = true
  elseif a:match("^[%w][%w%._%-]*/[%w][%w%._%-]*$") then repo = a; given = true
  elseif a:sub(1, 1) == "-" then error("unknown option " .. a, 0)
  else ref = a; given = true
  end
  i = i + 1
end

---------------------------------------------------------------- source ---

--- The base url of the last successful pull, if there was one.
local function remembered()
  if not fs.exists(SOURCE) then return nil end
  local h = fs.open(SOURCE, "r")
  if not h then return nil end
  local text = h.readAll()
  h.close()
  return text and text:match("url=([^\r\n]+)")
end

local base
if url then
  base = url:gsub("/+$", "")
elseif not given then
  base = remembered()
end
if not base then
  base = ("https://raw.githubusercontent.com/%s/%s")
    :format(repo or DEFAULT_REPO, ref or DEFAULT_REF)
end

----------------------------------------------------------------- fetch ---

if not http then
  error("the http API is disabled in this world -- copy the tree to " ..
        DIR .. " by hand, then run: " .. DIR .. "/install", 0)
end

local function fetch(path)
  local u = base .. "/" .. path
  local res, err = http.get(u)
  if not res then return nil, (err or "no response") .. "  <- " .. u end
  local code = res.getResponseCode and res.getResponseCode() or 200
  local data = res.readAll()
  res.close()
  if code >= 400 then return nil, ("HTTP %d  <- %s"):format(code, u) end
  if not data or data == "" then return nil, "empty file  <- " .. u end
  return data
end

--- A path is only allowed to name something under DIR, not climb out of it.
local function safePath(p)
  return p:match("^[%w][%w%._%-/]*$") ~= nil and not p:find("%.%.", 1, true)
end

local function parseManifest(text)
  local list = {}
  for line in text:gmatch("[^\r\n]+") do
    local p = line:gsub("#.*$", "")
    p = p:gsub("^%s+", ""):gsub("%s+$", "")
    if p ~= "" then
      if not safePath(p) then error("manifest has a suspect path: " .. p, 0) end
      list[#list + 1] = p
    end
  end
  if #list == 0 then error("manifest is empty: " .. base .. "/" .. MANIFEST, 0) end
  return list
end

print("ccagent bootstrap")
print("  from " .. base)

local text, err = fetch(MANIFEST)
if not text then
  error("could not read the manifest.\n" .. err ..
        "\ncheck the ref exists, and that this world allows http.", 0)
end
local list = parseManifest(text)

-- Fetch everything first, write nothing yet: a failure half way through
-- should not leave a turtle with a mixed-version library.
local blobs = {}
for n, path in ipairs(list) do
  write(("  [%d/%d] %s "):format(n, #list, path))
  local data, e = fetch(path)
  if not data then
    print("FAILED")
    error(e .. "\nnothing was written; the existing install is untouched.", 0)
  end
  blobs[path] = data
  print("ok")
end

----------------------------------------------------------------- write ---

local wrote, kept = 0, 0
for _, path in ipairs(list) do
  local target = DIR .. "/" .. path
  if path == "config.lua" and fs.exists(target) and not force then
    kept = kept + 1
  else
    local dir = fs.getDir(target)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local h = fs.open(target, "w")
    if not h then error("cannot write " .. target, 0) end
    h.write(blobs[path])
    h.close()
    wrote = wrote + 1
  end
end

if not fs.exists("/.ccagent") then fs.makeDir("/.ccagent") end
local h = fs.open(SOURCE, "w")
if h then
  h.write("# written by ccagent/boot.lua; `ccagent update` re-reads this\n")
  h.write("url=" .. base .. "\n")
  h.close()
end

print(("  %d file%s written%s")
  :format(wrote, wrote == 1 and "" or "s",
          kept > 0 and ", config.lua kept" or ""))

----------------------------------------------------------------- setup ---

if not setup then return end

if not shell then
  print("  now run: " .. DIR .. "/install")
  return
end

print("")
local rest = {}
if startup then rest[#rest + 1] = "--startup"; rest[#rest + 1] = startup end
shell.run(DIR .. "/install.lua", unpack(rest))
