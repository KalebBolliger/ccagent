--[[ /ccagent/boot.lua ---------------------------------------------------
  One command to put ccagent on a CC:Tweaked computer or turtle.

  There is no source baked into this file. Where the library comes from is
  configuration, because it differs per deployment: a public repo, a private
  one behind a token, a fork, a file server, or a floppy disk. On a bare
  machine boot.lua asks; after that it remembers, in /.ccagent/source.

      wget run <your-url>/boot.lua      -- asks where to pull from, then pulls
      ccagent update                    -- re-pulls from the remembered source

  A source is either a url template or a directory this computer can see --
  a mounted floppy is a perfectly good source and needs no http at all:

      /disk/ccagent
      https://files.mylan:8080/ccagent/{path}
      https://raw.<forge>/{repo}/{ref}/{path}
      https://<api-host>/repos/{repo}/contents/{path}?ref={ref}

  In a url, {path} says where the file path goes, and {repo}/{ref} are
  filled from --repo/--ref. A source with no {path} in it -- every local
  one, and the first url above -- is a directory to append the path to.

  Options, any order, all optional:

      --from <dir>             a local directory: a floppy, or anywhere
      --url <template>         where to pull from; stored for next time
      --repo owner/name        fills {repo}
      --ref  branch|tag|sha    fills {ref}          (default: main)
      --header "Name: value"   sent with every request; repeatable, stored
      --token <secret>         adds an Authorization: Bearer header, kept in
                               /.ccagent/token, never written to the source
                               file and never printed
      --startup worker|host|solo   also write a /startup.lua (see install.lua)
      --force                  replace config.lua too, instead of keeping yours
      --no-setup               download only; do not run install.lua
      --no-prompt              fail rather than ask (for startup scripts)

  A bare argument is read as a url if it looks like one, a path if it starts
  with /, a repo if it looks like owner/name, otherwise a ref -- so
  `boot v1.1.1` re-points a stored template and `boot /disk/ccagent`
  installs off a floppy. A branch whose name contains a slash needs --ref.

  Arguments are for the saved-file form (`wget <url> boot.lua`, then
  `boot <args>`): `wget run` is not guaranteed to forward them.

  Nothing is written until every file has been fetched, so a mid-way network
  failure leaves the existing install alone rather than half-replaced.

  /ccagent is not configurable here: agent/lib.lua and claude/config.lua
  address it by absolute path.
--------------------------------------------------------------------------]]

local DIR         = "/ccagent"
local CONF        = "/.ccagent/source"
local TOKEN_FILE  = "/.ccagent/token"
local MANIFEST    = "manifest.txt"
local DEFAULT_REF = "main"

local unpack = table.unpack or unpack

local USAGE = [[
ccagent bootstrap -- pulls the library onto this machine.

  boot                          use the stored source, or ask for one
  boot --from /disk/ccagent     install from a floppy or any local directory
  boot --url <template>         a url containing {path}, or a directory
  boot --repo owner/name --ref r    fill {repo} and {ref} in the template
  boot <ref>                    just change the ref
  boot --token <secret>         for a source that needs Authorization
  boot --header "Name: value"   any other header, repeatable

  --startup worker|host|solo    write /startup.lua as well
  --force                       overwrite config.lua too
  --no-setup                    download only
  --no-prompt                   never ask; fail instead

The source is remembered in /.ccagent/source and any token in
/.ccagent/token. Both are plain text on this computer.
]]

------------------------------------------------------------------ args ---

local args = { ... }
local cli = { headers = {} }
local force, setup, mayPrompt = false, true, true

local i = 1
local function nextArg(what)
  i = i + 1
  if not args[i] then error(what .. " needs a value", 0) end
  return args[i]
end

while i <= #args do
  local a = args[i]
  if a == "--url" then cli.source = nextArg("--url")
  elseif a == "--from" then cli.source = nextArg("--from")
  elseif a == "--repo" then cli.repo = nextArg("--repo")
  elseif a == "--ref" then cli.ref = nextArg("--ref")
  elseif a == "--token" then cli.token = nextArg("--token")
  elseif a == "--header" then
    local raw = nextArg("--header")
    local k, v = raw:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
    if not k then error('--header wants "Name: value", got: ' .. raw, 0) end
    cli.headers[k] = v
  elseif a == "--startup" then cli.startup = nextArg("--startup")
  elseif a == "--force" then force = true
  elseif a == "--no-setup" then setup = false
  elseif a == "--no-prompt" then mayPrompt = false
  elseif a == "-h" or a == "--help" then print(USAGE); return
  elseif a:match("^%a[%w+.%-]*://") then cli.source = a
  elseif a:sub(1, 1) == "/" then cli.source = a
  elseif a:match("^[%w][%w%._%-]*/[%w][%w%._%-]*$") then cli.repo = a
  elseif a:sub(1, 1) == "-" then error("unknown option " .. a, 0)
  else cli.ref = a
  end
  i = i + 1
end

---------------------------------------------------------------- source ---
-- /.ccagent/source is key=value, "#" comments, one header per "header.Name"
-- line. It is written after a successful pull and is yours to edit.

local function readConf()
  local conf = { headers = {} }
  if not fs.exists(CONF) then return conf end
  local h = fs.open(CONF, "r")
  if not h then return conf end
  local text = h.readAll() or ""
  h.close()
  for line in text:gmatch("[^\r\n]+") do
    if line:match("^%s*[^#]") then
      local k, v = line:match("^%s*([%w%.%-_]+)%s*=%s*(.-)%s*$")
      if k and v ~= "" then
        local name = k:match("^header%.(.+)$")
        if name then conf.headers[name] = v else conf[k] = v end
      end
    end
  end
  return conf
end

local function writeConf(conf)
  if not fs.exists("/.ccagent") then fs.makeDir("/.ccagent") end
  local h = fs.open(CONF, "w")
  if not h then return end
  h.write("# where ccagent came from, and where `ccagent update` goes back to.\n")
  h.write("# a directory (a floppy, say) or a url; a url may contain\n")
  h.write("# {path}, {repo} and {ref}. edit freely.\n")
  h.write("source=" .. conf.source .. "\n")
  if conf.repo then h.write("repo=" .. conf.repo .. "\n") end
  if conf.ref then h.write("ref=" .. conf.ref .. "\n") end
  local names = {}
  for name in pairs(conf.headers) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    h.write(("header.%s=%s\n"):format(name, conf.headers[name]))
  end
  h.write("# a token, if any, lives in " .. TOKEN_FILE .. " -- not here.\n")
  h.close()
end

local function readToken()
  if not fs.exists(TOKEN_FILE) then return nil end
  local h = fs.open(TOKEN_FILE, "r")
  if not h then return nil end
  local text = h.readAll() or ""
  h.close()
  local token = text:gsub("%s+$", ""):gsub("^%s+", "")
  return token ~= "" and token or nil
end

local function writeToken(token)
  if not fs.exists("/.ccagent") then fs.makeDir("/.ccagent") end
  local h = fs.open(TOKEN_FILE, "w")
  if not h then return end
  h.write(token .. "\n")
  h.close()
end

--- Ask, once, on a machine that has never been told where to pull from.
local function askForSource()
  print("ccagent does not know where to pull from yet.")
  print("")
  print("Give a directory this computer can see, or a url. In a url, put")
  print("{path} where the file path goes, or name the directory the tree")
  print("sits in and {path} is appended:")
  print("")
  print("  /disk/ccagent")
  print("  https://files.mylan:8080/ccagent")
  print("  https://raw.<forge-host>/OWNER/REPO/main/{path}")
  print("  https://<api-host>/repos/OWNER/REPO/contents/{path}?ref=main")
  print("")
  write("from> ")
  local answer = read()
  answer = answer and (answer:gsub("^%s+", ""):gsub("%s+$", "")) or ""
  if answer == "" then error("no source given; nothing to pull from", 0) end
  if not answer:match("^%a[%w+.%-]*://") then return answer, nil end
  print("")
  print("Access token, if this source needs one. Stored in " .. TOKEN_FILE)
  print("as plain text on this computer. Blank for none.")
  write("token> ")
  local token = read("*")
  token = token and (token:gsub("%s+", "")) or ""
  return answer, token ~= "" and token or nil
end

local conf = readConf()

local source = cli.source or conf.source
local token  = cli.token or readToken()

if not source then
  if not mayPrompt or not read then
    error("no source configured. Pass --from <dir> or --url <template>, " ..
          "or put one in " .. CONF .. ".\n\n" .. USAGE, 0)
  end
  local asked
  source, asked = askForSource()
  if asked then cli.token, token = asked, asked end
end

-- Anything without a scheme is a directory on this computer: a mounted
-- floppy, or a tree someone dropped into the save by hand.
local isLocal = source:match("^%a[%w+.%-]*://") == nil

if cli.token then writeToken(cli.token) end

local repo = cli.repo or conf.repo
local ref  = cli.ref or conf.ref or DEFAULT_REF

-- A source that does not say where the path goes is a directory to append
-- to. Local sources are always directories.
local template = source
if isLocal or not template:find("{path}", 1, true) then
  template = template:gsub("/+$", "") .. "/{path}"
end

-- Two sets: what the operator configured (persisted) and what actually goes
-- out (adds the token). The token lives in its own file and must never end
-- up in the source file, which is meant to be readable and copyable.
local stored = {}
for name, value in pairs(conf.headers) do stored[name] = value end
for name, value in pairs(cli.headers) do stored[name] = value end

local headers = {}
for name, value in pairs(stored) do headers[name] = value end
if token then
  headers.Authorization = headers.Authorization or ("Bearer " .. token)
  -- A forge that serves file contents as JSON metadata needs telling
  -- otherwise, or every file arrives base64-wrapped. Harmless to a plain
  -- file server, and overridable with --header "Accept: ...".
  headers.Accept = headers.Accept or "application/vnd.github.raw, */*"
end

local function locate(path)
  local vars = { path = path, repo = repo, ref = ref }
  local missing
  local out = template:gsub("{(%w+)}", function(key)
    local v = vars[key]
    if v == nil or v == "" then missing = missing or key end
    return v or ""
  end)
  if missing then
    error(("the url wants {%s} and nothing supplies it -- pass --%s")
      :format(missing, missing), 0)
  end
  return out
end

------------------------------------------------------------------ read ---

if not isLocal and not http then
  error("the http API is disabled in this world. Either copy the tree to " ..
        DIR .. " by hand and run " .. DIR .. "/install, or put it on a " ..
        "floppy and use: boot --from /disk/<dir>", 0)
end

--- A file from a directory this computer can already see.
local function readLocal(path)
  local at = locate(path)
  if not fs.exists(at) then return nil, "not there  <- " .. at end
  local h = fs.open(at, "r")
  if not h then return nil, "cannot read  <- " .. at end
  local data = h.readAll()
  h.close()
  if not data or data == "" then return nil, "empty file  <- " .. at end
  return data
end

--- A file over http.
local function readRemote(path)
  local u = locate(path)
  local res, err = http.get(u, next(headers) and headers or nil)
  if not res then return nil, (err or "no response") .. "  <- " .. u end
  local code = res.getResponseCode and res.getResponseCode() or 200
  local data = res.readAll()
  res.close()
  if code >= 400 then return nil, ("HTTP %d  <- %s"):format(code, u) end
  if not data or data == "" then return nil, "empty file  <- " .. u end
  -- Some forges answer a file request with JSON metadata carrying base64
  -- content. Writing that to disk would produce a tree that installs
  -- cleanly and fails later as a syntax error, so say what happened.
  if data:find('^%s*{') and data:find('"encoding"%s*:%s*"base64"') then
    return nil, "the source returned JSON metadata, not file contents.\n" ..
      'add --header "Accept: <the raw content type your forge wants>"  <- ' .. u
  end
  return data
end

local fetch = isLocal and readLocal or readRemote

--- A path may only name something under DIR, never climb out of it.
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
  if #list == 0 then error("manifest is empty: " .. locate(MANIFEST), 0) end
  return list
end

print("ccagent bootstrap")
print("  from " .. locate("{path}") ..
      ((not isLocal and token) and "  (with a token)" or ""))

local text, err = fetch(MANIFEST)
if not text then
  error("could not read the manifest.\n" .. err .. "\n" ..
        (isLocal and "is the disk in the drive, and is that the right directory?"
                 or "check the url, the ref, any token, and that this world " ..
                    "allows http."), 0)
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

writeConf({ source = source, repo = repo, ref = ref, headers = stored })

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
if cli.startup then rest[#rest + 1] = "--startup"; rest[#rest + 1] = cli.startup end
shell.run(DIR .. "/install.lua", unpack(rest))
