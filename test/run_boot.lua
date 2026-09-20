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
--  served: path -> content, or false to fail that one request.
local function runBoot(args, served, existing)
  mock.reset()
  for path, body in pairs(existing or {}) do mock.files[path] = body end

  local asked = {}
  _G.http = {
    get = function(url)
      asked[#asked + 1] = url
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

  local ran = nil
  _G.shell = { run = function(...) ran = { ... } end }
  local log = {}
  _G.write = function(s) log[#log + 1] = tostring(s) end
  _G.print = function(s) log[#log + 1] = tostring(s or "") .. "\n" end

  local okRun, err = pcall(BOOT, table.unpack(args))

  _G.print = realPrint
  _G.write = nil
  _G.http = nil
  _G.shell = nil
  return { ok = okRun, err = err, asked = asked, ran = ran,
           log = table.concat(log) }
end

local GH = "https://raw.githubusercontent.com/KalebBolliger/ccagent/main"

--- The repo as a served tree: a two-file manifest, so tests stay readable.
local function tree(manifestBody, extra)
  local t = { ["manifest.txt"] = manifestBody or
    "# comment\n\nboot.lua\nconfig.lua\nagent/util.lua\n" }
  t["boot.lua"] = "-- boot"
  t["config.lua"] = "-- fresh config"
  t["agent/util.lua"] = "-- util"
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

-- Default target, fresh machine.
local r = runBoot({}, { [GH] = tree() })
ok(r.ok, "a bare run succeeds", r.err)
ok(r.asked[1] == GH .. "/manifest.txt", "manifest is fetched first", r.asked[1])
ok(mock.files["/ccagent/agent/util.lua"] == "-- util", "files land under /ccagent")
ok(mock.files["/ccagent/boot.lua"] == "-- boot", "boot.lua installs itself too")
ok(#r.asked == 4, "one request per manifest entry, plus the manifest", #r.asked)
ok(r.ran and r.ran[1] == "/ccagent/install.lua", "install.lua is handed the setup",
   r.ran and r.ran[1])
ok((mock.files["/.ccagent/source"] or ""):find("url=" .. GH, 1, true) ~= nil,
   "the source it came from is remembered", mock.files["/.ccagent/source"])

-- Refs and repos.
local V = "https://raw.githubusercontent.com/KalebBolliger/ccagent/v1.1.1"
r = runBoot({ "--ref", "v1.1.1" }, { [V] = tree() })
ok(r.ok and r.asked[1] == V .. "/manifest.txt", "--ref picks the tag", r.asked[1])

r = runBoot({ "v1.1.1" }, { [V] = tree() })
ok(r.ok and r.asked[1] == V .. "/manifest.txt", "a bare ref works too", r.asked[1])

local FORK = "https://raw.githubusercontent.com/someone/ccagent/main"
r = runBoot({ "someone/ccagent" }, { [FORK] = tree() })
ok(r.ok and r.asked[1] == FORK .. "/manifest.txt", "a bare owner/name is a repo",
   r.asked[1])

r = runBoot({ "--url", "https://pi.local/ccagent/" }, { ["https://pi.local/ccagent"] = tree() })
ok(r.ok, "--url serves from anywhere, trailing slash and all", r.err)

r = runBoot({ "--repo", "someone/ccagent", "--ref", "dev" },
            { ["https://raw.githubusercontent.com/someone/ccagent/dev"] = tree() })
ok(r.ok, "--repo and --ref combine", r.err)

-- The remembered source, which is what `ccagent update` rides on.
r = runBoot({}, { ["https://pi.local/ccagent"] = tree() },
            { ["/.ccagent/source"] = "url=https://pi.local/ccagent\n" })
ok(r.ok and r.asked[1] == "https://pi.local/ccagent/manifest.txt",
   "a bare re-run goes back to the remembered source", r.asked[1])

r = runBoot({ "--ref", "v1.1.1" }, { [V] = tree() },
            { ["/.ccagent/source"] = "url=https://pi.local/ccagent\n" })
ok(r.ok and r.asked[1] == V .. "/manifest.txt",
   "an explicit target beats the remembered one", r.asked[1])

-- config.lua is the operator's file.
r = runBoot({}, { [GH] = tree() }, { ["/ccagent/config.lua"] = "-- mine" })
ok(mock.files["/ccagent/config.lua"] == "-- mine", "an edited config.lua survives")
ok(r.log:find("config.lua kept", 1, true) ~= nil, "and it says so")

r = runBoot({ "--force" }, { [GH] = tree() }, { ["/ccagent/config.lua"] = "-- mine" })
ok(mock.files["/ccagent/config.lua"] == "-- fresh config", "--force replaces it")

-- All or nothing.
r = runBoot({}, { [GH] = tree(nil, { ["agent/util.lua"] = false }) },
            { ["/ccagent/agent/util.lua"] = "-- old but working" })
ok(not r.ok, "a failed download fails the run")
ok(mock.files["/ccagent/agent/util.lua"] == "-- old but working",
   "and writes nothing, so the old install still runs")
ok(mock.files["/ccagent/boot.lua"] == nil, "not even the files that did arrive")
ok(tostring(r.err):find("untouched", 1, true) ~= nil, "the error says so", r.err)

-- Bad inputs.
r = runBoot({}, { [GH] = { ["manifest.txt"] = false } })
ok(not r.ok and tostring(r.err):find("manifest", 1, true) ~= nil,
   "a missing manifest is a clear error", r.err)

r = runBoot({}, { [GH] = { ["manifest.txt"] = "# nothing but a comment\n" } })
ok(not r.ok and tostring(r.err):find("empty", 1, true) ~= nil,
   "an empty manifest is an error, not a silent no-op", r.err)

r = runBoot({}, { [GH] = tree("../../startup.lua\n") })
ok(not r.ok and tostring(r.err):find("suspect", 1, true) ~= nil,
   "a manifest may not write outside /ccagent", r.err)

r = runBoot({ "--nope" }, { [GH] = tree() })
ok(not r.ok and tostring(r.err):find("unknown option", 1, true) ~= nil,
   "an unknown option is refused rather than guessed at", r.err)

r = runBoot({ "--ref" }, { [GH] = tree() })
ok(not r.ok, "a flag with no value is refused", r.err)

-- Handoff.
r = runBoot({ "--startup", "worker" }, { [GH] = tree() })
ok(r.ran and r.ran[2] == "--startup" and r.ran[3] == "worker",
   "--startup is passed through to install.lua")

r = runBoot({ "--no-setup" }, { [GH] = tree() })
ok(r.ok and r.ran == nil, "--no-setup downloads and stops")
ok(mock.files["/ccagent/agent/util.lua"] == "-- util", "but still downloads")

r = runBoot({ "--help" }, { [GH] = tree() })
ok(r.ok and #r.asked == 0, "--help asks the network for nothing")

-- A world with http switched off.
do
  mock.reset()
  local savedPrint = _G.print
  _G.http, _G.write, _G.print = nil, function() end, function() end
  local okRun, err = pcall(BOOT)
  _G.print, _G.write = savedPrint, nil
  ok(not okRun and tostring(err):find("http", 1, true) ~= nil,
     "no http is explained, not a nil index", err)
  ok(tostring(err):find("by hand", 1, true) ~= nil, "and it says what to do instead")
end

--------------------------------------------------------------------------
realPrint(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
