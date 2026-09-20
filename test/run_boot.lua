--[[ test/run_boot.lua --------------------------------------------------
  The bootstrapper, against a mocked CC:Tweaked world and a fake http.

  Two things are checked here, and they fail differently in-game:

    * drift -- manifest.txt is the only list of what belongs on a turtle.
      If a module is added to the repo and not to the manifest, the turtle
      gets a tree that loads until it doesn't. That is a bug you find in
      Minecraft, which is the expensive place to find bugs.

    * the fetch itself -- url resolution, the remembered source, config.lua
      survival, and the all-or-nothing rule (a failed download must leave
      the existing install exactly as it was).

      lua5.3 test/run_boot.lua
--------------------------------------------------------------------------]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local mock = require("test.mock")
mock.install()

local pass, fail = 0, 0
local realPrint = print
local function ok(cond, label, detail)
  if cond then
    pass = pass + 1
    realPrint("  ok   " .. label)
  else
    fail = fail + 1
    realPrint("  FAIL " .. label .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end
local function group(name) realPrint("\n" .. name) end

--------------------------------------------------------------------------
-- reading the repo as it sits on disk

local function slurp(path)
  local h = io.open(path, "r")
  if not h then return nil end
  local s = h:read("*a")
  h:close()
  return s
end

local manifestText = slurp("manifest.txt")

local manifest, manifestSet = {}, {}
for line in (manifestText or ""):gmatch("[^\r\n]+") do
  local p = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if p ~= "" then
    manifest[#manifest + 1] = p
    manifestSet[p] = true
  end
end

--------------------------------------------------------------------------
group("manifest")

ok(manifestText ~= nil, "manifest.txt exists")
ok(#manifest > 20, "manifest lists the library", #manifest)

local missing = {}
for _, p in ipairs(manifest) do
  if not slurp(p) then missing[#missing + 1] = p end
end
ok(#missing == 0, "every listed file exists in the repo", table.concat(missing, ", "))

-- The other direction: nothing deployable may sit outside the manifest.
local found, scanned = {}, false
local pipe = io.popen and io.popen("find agent claude ui -name '*.lua' 2>/dev/null")
if pipe then
  for line in pipe:lines() do found[#found + 1] = (line:gsub("^%./", "")) end
  pipe:close()
  scanned = #found > 0
end
for _, p in ipairs({ "boot.lua", "install.lua", "config.lua" }) do
  if slurp(p) then found[#found + 1] = p end
end

if scanned then
  local unlisted = {}
  for _, p in ipairs(found) do
    if not manifestSet[p] then unlisted[#unlisted + 1] = p end
  end
  ok(#unlisted == 0, "no deployable file is missing from the manifest",
     table.concat(unlisted, ", "))
else
  realPrint("  skip no directory listing available; drift check not run")
end

ok(not manifestSet["test/run.lua"] and not manifestSet["README.md"],
   "the manifest stays out of tests and docs")

--------------------------------------------------------------------------
group("the generated launcher")

-- install.lua writes /ccagent.lua as a literal. It runs under CC's Lua, so
-- it may not lean on table.unpack, and it has to at least compile.
local installSrc = slurp("install.lua") or ""
local launcher = installSrc:match('h%.write%(%[%[(.-)%]%]%)')
ok(launcher ~= nil, "install.lua carries a launcher body")
ok(launcher and load(launcher) ~= nil, "the launcher compiles")
ok(launcher and launcher:find("table.unpack or unpack", 1, true) ~= nil,
   "the launcher shims unpack rather than assuming 5.2+")
ok(launcher and launcher:find("update", 1, true) ~= nil,
   "the launcher knows `ccagent update`")

--------------------------------------------------------------------------
group("boot.lua")

local BOOT = assert(loadfile("boot.lua"))

--- Run boot.lua against a fake http server.
--  served: url-prefix -> { path -> content }, content false to fail it.
--  answers: queued replies for read(), when the run is expected to prompt.
local function runBoot(args, served, existing, answers)
  mock.reset()
  for path, body in pairs(existing or {}) do mock.files[path] = body end

  local asked, sentHeaders = {}, {}
  _G.http = {
    get = function(url, headers)
      asked[#asked + 1] = url
      sentHeaders[#sentHeaders + 1] = headers
      for prefix, files in pairs(served) do
        local rest = url:sub(1, #prefix) == prefix and url:sub(#prefix + 2) or nil
        if rest and files[rest] ~= nil then
          local body = files[rest]
          if body == false then return nil, "404 Not Found" end
          return { readAll = function() return body end,
                   close = function() end,
                   getResponseCode = function() return 200 end }
        end
      end
      return nil, "404 Not Found"
    end,
  }

  local ran, prompts = nil, {}
  local queue = { unpack_n = 0 }
  for n, a in ipairs(answers or {}) do queue[n] = a end
  local nextAnswer = 0
  _G.read = function(...)
    nextAnswer = nextAnswer + 1
    prompts[#prompts + 1] = { ... }
    return queue[nextAnswer] or ""
  end
  _G.shell = { run = function(...) ran = { ... } end }
  local log = {}
  _G.write = function(s) log[#log + 1] = tostring(s) end
  _G.print = function(s) log[#log + 1] = tostring(s or "") .. "\n" end

  local okRun, err = pcall(BOOT, table.unpack(args))

  _G.print = realPrint
  _G.write, _G.http, _G.shell, _G.read = nil, nil, nil, nil
  return { ok = okRun, err = err, asked = asked, headers = sentHeaders,
           ran = ran, prompts = prompts, log = table.concat(log) }
end

--- A served tree: a three-file manifest, so the tests stay readable.
local function tree(manifestBody, extra)
  local t = { ["manifest.txt"] = manifestBody or
    "# comment\n\nboot.lua\nconfig.lua\nagent/util.lua\n" }
  t["boot.lua"] = "-- boot"
  t["config.lua"] = "-- fresh config"
  t["agent/util.lua"] = "-- util"
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local HOST = "https://files.example:8080/ccagent"
local conf = function(body) return { ["/.ccagent/source"] = body } end

--------------------------------------------------------------------------
-- nothing is baked in: with no source and no way to ask, it says so

local r = runBoot({ "--no-prompt" }, { [HOST] = tree() })
ok(not r.ok, "no configured source is an error, not a guess")
ok(tostring(r.err):find("--from", 1, true) ~= nil, "and it names the ways out", r.err)
ok(#r.asked == 0, "and it asks the network for nothing")

-- Nothing in boot.lua may assign a url-shaped literal to anything: the
-- source is configuration, not code. (The behaviour above is the real
-- guarantee; this catches a default sneaking back in as a constant.)
local constant
for line in (slurp("boot.lua") or ""):gmatch("[^\r\n]+") do
  local code = line:gsub("%-%-.*$", "")
  if code:match('=%s*[\'"][^\'"]*://') then constant = line end
end
ok(constant == nil, "no url-valued constant hides in boot.lua", constant)

--------------------------------------------------------------------------
-- a directory url, the plainest case

r = runBoot({ "--url", HOST .. "/" }, { [HOST] = tree() })
ok(r.ok, "a directory url works, trailing slash and all", r.err)
ok(r.asked[1] == HOST .. "/manifest.txt", "manifest is fetched first", r.asked[1])
ok(mock.files["/ccagent/agent/util.lua"] == "-- util", "files land under /ccagent")
ok(#r.asked == 4, "one request per manifest entry, plus the manifest", #r.asked)
ok(r.ran and r.ran[1] == "/ccagent/install.lua", "install.lua is handed the setup",
   r.ran and r.ran[1])

--------------------------------------------------------------------------
-- templates

local TPL = "https://raw.example/{repo}/{ref}/{path}"
r = runBoot({ "--url", TPL, "--repo", "someone/ccagent", "--ref", "v1.1.1" },
            { ["https://raw.example/someone/ccagent/v1.1.1"] = tree() })
ok(r.ok, "{repo} and {ref} are filled in", r.err)

r = runBoot({ "--url", "https://api.example/repos/{repo}/contents/{path}?ref={ref}",
              "--repo", "someone/ccagent" },
            { ["https://api.example/repos/someone/ccagent/contents"] = {
                ["manifest.txt?ref=main"] = "agent/util.lua\n",
                ["agent/util.lua?ref=main"] = "-- util" } })
ok(r.ok, "a template with a query string works too", r.err)
ok(r.asked[1]:find("?ref=main", 1, true) ~= nil, "ref defaults to main", r.asked[1])

r = runBoot({ "--url", TPL }, { ["https://raw.example"] = tree() })
ok(not r.ok and tostring(r.err):find("{repo}", 1, true) ~= nil,
   "an unsupplied placeholder is named, before any request", r.err)
ok(#r.asked == 0, "and nothing is fetched")

--------------------------------------------------------------------------
-- the remembered source, which is what `ccagent update` rides on

r = runBoot({}, { [HOST] = tree() }, conf("source=" .. HOST .. "\n"))
ok(r.ok and r.asked[1] == HOST .. "/manifest.txt",
   "a bare re-run uses the stored source", r.asked[1])
ok(#r.prompts == 0, "and does not ask")

r = runBoot({ "v2" }, { ["https://raw.example/someone/ccagent/v2"] = tree() },
            conf("source=" .. TPL .. "\nrepo=someone/ccagent\nref=v1.1.1\n"))
ok(r.ok, "a bare ref re-points a stored template", r.err)

r = runBoot({}, { [HOST] = tree() },
            conf("# a comment\n\nsource=" .. HOST .. "\nheader.X-Key=abc\n"))
ok(r.ok and r.headers[1] and r.headers[1]["X-Key"] == "abc",
   "stored headers are sent with every request")
ok(r.headers[4] and r.headers[4]["X-Key"] == "abc", "every request, not just the first")

r = runBoot({ "--url", "https://other.example/x" }, { ["https://other.example/x"] = tree() },
            conf("source=" .. HOST .. "\n"))
ok(r.ok and r.asked[1]:find("other.example", 1, true) ~= nil,
   "an explicit url beats the stored one", r.asked[1])
ok((mock.files["/.ccagent/source"] or ""):find("https://other.example/x", 1, true) ~= nil,
   "and replaces it for next time", mock.files["/.ccagent/source"])

--------------------------------------------------------------------------
-- asking, when it has never been told

r = runBoot({}, { [HOST] = tree() }, nil, { HOST })
ok(r.ok, "a bare run on a bare machine asks, then pulls", r.err)
ok(#r.prompts == 2, "it asks for a url and a token", #r.prompts)
ok(r.prompts[2][1] == "*", "the token prompt is masked", r.prompts[2][1])
ok((mock.files["/.ccagent/source"] or ""):find(HOST, 1, true) ~= nil,
   "and remembers the answer")

r = runBoot({}, { [HOST] = tree() }, nil, { "" })
ok(not r.ok and tostring(r.err):find("no source", 1, true) ~= nil,
   "an empty answer is an error, not a default", r.err)

--------------------------------------------------------------------------
-- a local source: a floppy, or anything else this computer can see

--- Lay a tree out under a directory in the mock filesystem.
local function onDisk(at, extra)
  local files = {}
  for path, body in pairs(tree(nil, extra)) do
    files[at .. "/" .. path] = body
  end
  return files
end

r = runBoot({ "--from", "/disk/ccagent" }, {}, onDisk("/disk/ccagent"))
ok(r.ok, "a floppy is a source", r.err)
ok(mock.files["/ccagent/agent/util.lua"] == "-- util", "its files land under /ccagent")
ok(#r.asked == 0, "and http is never touched", #r.asked)
ok(r.ran and r.ran[1] == "/ccagent/install.lua", "install.lua still gets the setup")
ok((mock.files["/.ccagent/source"] or ""):find("source=/disk/ccagent", 1, true) ~= nil,
   "the disk is remembered like any other source", mock.files["/.ccagent/source"])

r = runBoot({ "/disk/ccagent" }, {}, onDisk("/disk/ccagent"))
ok(r.ok, "a bare path is read as a source", r.err)

local disk = onDisk("/disk/ccagent")
disk["/.ccagent/source"] = "source=/disk/ccagent\n"
r = runBoot({}, {}, disk)
ok(r.ok and #r.asked == 0, "a stored local source needs no arguments", r.err)

disk = onDisk("/disk/ccagent")
disk["/disk/ccagent/agent/util.lua"] = nil
disk["/ccagent/agent/util.lua"] = "-- old but working"
r = runBoot({ "--from", "/disk/ccagent" }, {}, disk)
ok(not r.ok and tostring(r.err):find("not there", 1, true) ~= nil,
   "a file missing from the disk is a clear error", r.err)
ok(mock.files["/ccagent/agent/util.lua"] == "-- old but working",
   "and still all or nothing")

r = runBoot({ "--from", "/disk/nothing-here" }, {}, {})
ok(not r.ok and tostring(r.err):find("manifest", 1, true) ~= nil,
   "so is a directory with no manifest in it", r.err)
ok(tostring(r.err):find("is the disk in", 1, true) ~= nil,
   "and it suggests the usual cause", r.err)

disk = onDisk("/disk/ccagent")
disk["/ccagent/config.lua"] = "-- mine"
r = runBoot({ "--from", "/disk/ccagent" }, {}, disk)
ok(mock.files["/ccagent/config.lua"] == "-- mine",
   "config.lua survives a disk install too")

-- No http in this world at all: the floppy path must still work.
do
  mock.reset()
  for path, body in pairs(onDisk("/disk/ccagent")) do mock.files[path] = body end
  local savedPrint = _G.print
  _G.http, _G.write, _G.print = nil, function() end, function() end
  _G.shell = { run = function() end }
  local okRun, err = pcall(BOOT, "--from", "/disk/ccagent")
  _G.print, _G.write, _G.shell = savedPrint, nil, nil
  ok(okRun, "a disk install works in a world with http disabled", err)
  ok(mock.files["/ccagent/agent/util.lua"] == "-- util", "and really writes the files")
end

--------------------------------------------------------------------------
-- it has to fit a turtle

-- A turtle terminal is 39x13 and CC has no scrollback: a prompt taller
-- than the screen scrolls its own explanation away before anyone reads it,
-- which is how the first real in-game run went. Progress and url lines are
-- exempt -- a url is as long as it is -- but everything up to a prompt has
-- to fit.
local function fits(text, label)
  local widest, count, worst = 0, 0, ""
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    count = count + 1
    if #line > widest then widest, worst = #line, line end
  end
  ok(widest <= 39, label .. " stays inside 39 columns", widest .. ": " .. worst)
  ok(count <= 13, label .. " stays inside 13 rows", count)
end

-- install.lua cannot be run here (it needs the whole agent stack and a
-- real terminal), so its literals are measured in the source instead.
-- Weaker than measuring output -- a line built from a runtime value can
-- still overflow -- but it is what let a 66-column line ship.
local widestSay, worstSay = 0, ""
for literal in (slurp("install.lua") or ""):gmatch('say%("([^"]*)"') do
  if #literal > widestSay then widestSay, worstSay = #literal, literal end
end
ok(widestSay <= 39, "install.lua's lines stay inside 39 columns",
   widestSay .. ": " .. worstSay)

r = runBoot({}, { [HOST] = tree() }, nil, { HOST })
ok(r.ok, "the asking path still works", r.err)
fits((r.log:match("^(.-)from> ")), "the source prompt")
fits((r.log:match("from> (.-)token> ")), "the token prompt")

--------------------------------------------------------------------------
-- tokens

r = runBoot({ "--url", HOST, "--token", "s3cret" }, { [HOST] = tree() })
ok(r.ok, "a token is accepted", r.err)
ok(r.headers[1] and r.headers[1].Authorization == "Bearer s3cret",
   "and sent as a bearer header")
ok(r.headers[1].Accept and r.headers[1].Accept:find("raw", 1, true) ~= nil,
   "with an Accept that asks for raw content")
ok(mock.files["/.ccagent/token"]:find("s3cret", 1, true) ~= nil,
   "the token is kept in its own file")
ok((mock.files["/.ccagent/source"] or ""):find("s3cret", 1, true) == nil,
   "and never written into the source file", mock.files["/.ccagent/source"])
ok(r.log:find("s3cret", 1, true) == nil, "nor printed")
ok(r.log:find("with a token", 1, true) ~= nil, "though it says one is in use")

r = runBoot({ "--url", HOST }, { [HOST] = tree() },
            { ["/.ccagent/token"] = "stored-token\n" })
ok(r.headers[1] and r.headers[1].Authorization == "Bearer stored-token",
   "a stored token is picked up without passing it again")

r = runBoot({ "--url", HOST, "--token", "s3cret",
              "--header", "Accept: text/plain" }, { [HOST] = tree() })
ok(r.headers[1] and r.headers[1].Accept == "text/plain",
   "an explicit Accept wins over the default")

r = runBoot({ "--url", HOST, "--header", "X-Key: abc" }, { [HOST] = tree() })
ok((mock.files["/.ccagent/source"] or ""):find("header.X-Key=abc", 1, true) ~= nil,
   "a --header is remembered for next time", mock.files["/.ccagent/source"])

r = runBoot({ "--url", HOST, "--header", "nonsense" }, { [HOST] = tree() })
ok(not r.ok and tostring(r.err):find("Name: value", 1, true) ~= nil,
   "a malformed header is refused", r.err)

--------------------------------------------------------------------------
-- a source that answers with metadata instead of the file

r = runBoot({ "--url", HOST }, { [HOST] = tree(nil, {
  ["agent/util.lua"] = '{"name":"util.lua","encoding":"base64","content":"bG9s"}' }) })
ok(not r.ok, "base64 JSON is not silently written to disk")
ok(tostring(r.err):find("Accept", 1, true) ~= nil, "and the fix is named", r.err)

--------------------------------------------------------------------------
-- config.lua is the operator's file

r = runBoot({ "--url", HOST }, { [HOST] = tree() }, { ["/ccagent/config.lua"] = "-- mine" })
ok(mock.files["/ccagent/config.lua"] == "-- mine", "an edited config.lua survives")
ok(r.log:find("config.lua kept", 1, true) ~= nil, "and it says so")

r = runBoot({ "--url", HOST, "--force" }, { [HOST] = tree() },
            { ["/ccagent/config.lua"] = "-- mine" })
ok(mock.files["/ccagent/config.lua"] == "-- fresh config", "--force replaces it")

--------------------------------------------------------------------------
-- all or nothing

r = runBoot({ "--url", HOST }, { [HOST] = tree(nil, { ["agent/util.lua"] = false }) },
            { ["/ccagent/agent/util.lua"] = "-- old but working" })
ok(not r.ok, "a failed download fails the run")
ok(mock.files["/ccagent/agent/util.lua"] == "-- old but working",
   "and writes nothing, so the old install still runs")
ok(mock.files["/ccagent/boot.lua"] == nil, "not even the files that did arrive")
ok(tostring(r.err):find("untouched", 1, true) ~= nil, "the error says so", r.err)

--------------------------------------------------------------------------
-- bad inputs

r = runBoot({ "--url", HOST }, { [HOST] = { ["manifest.txt"] = false } })
ok(not r.ok and tostring(r.err):find("manifest", 1, true) ~= nil,
   "a missing manifest is a clear error", r.err)

r = runBoot({ "--url", HOST }, { [HOST] = { ["manifest.txt"] = "# only a comment\n" } })
ok(not r.ok and tostring(r.err):find("empty", 1, true) ~= nil,
   "an empty manifest is an error, not a silent no-op", r.err)

r = runBoot({ "--url", HOST }, { [HOST] = tree("../../startup.lua\n") })
ok(not r.ok and tostring(r.err):find("suspect", 1, true) ~= nil,
   "a manifest may not write outside /ccagent", r.err)

r = runBoot({ "--nope" }, { [HOST] = tree() })
ok(not r.ok and tostring(r.err):find("unknown option", 1, true) ~= nil,
   "an unknown option is refused rather than guessed at", r.err)

r = runBoot({ "--ref" }, { [HOST] = tree() })
ok(not r.ok, "a flag with no value is refused", r.err)

--------------------------------------------------------------------------
-- handoff

r = runBoot({ "--url", HOST, "--startup", "worker" }, { [HOST] = tree() })
ok(r.ran and r.ran[2] == "--startup" and r.ran[3] == "worker",
   "--startup is passed through to install.lua")

r = runBoot({ "--url", HOST, "--no-setup" }, { [HOST] = tree() })
ok(r.ok and r.ran == nil, "--no-setup downloads and stops")
ok(mock.files["/ccagent/agent/util.lua"] == "-- util", "but still downloads")

r = runBoot({ "--help" }, { [HOST] = tree() })
ok(r.ok and #r.asked == 0, "--help asks the network for nothing")

--------------------------------------------------------------------------
-- a world with http switched off

do
  mock.reset()
  mock.files["/.ccagent/source"] = "source=" .. HOST .. "\n"
  local savedPrint = _G.print
  _G.http, _G.write, _G.print = nil, function() end, function() end
  local okRun, err = pcall(BOOT)
  _G.print, _G.write = savedPrint, nil
  ok(not okRun and tostring(err):find("http", 1, true) ~= nil,
     "no http against a url is explained, not a nil index", err)
  ok(tostring(err):find("floppy", 1, true) ~= nil, "and it says what to do instead")
end

--------------------------------------------------------------------------
realPrint(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
