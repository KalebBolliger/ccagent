--[[ test/all.lua ------------------------------------------------------
  Runs both suites in separate processes, because each installs its own
  mock world and they must not share state.

      lua5.3 test/all.lua
--------------------------------------------------------------------------]]

local suites = { "test/run.lua", "test/run_lib.lua", "test/run_boot.lua" }
local failed = 0
local total = 0

for _, s in ipairs(suites) do
  print(("\n===== %s ====="):format(s))
  -- Read the child's output as well as its status: the per-suite counts
  -- are the only place the real total exists, and the docs quote it.
  local pipe = io.popen("lua5.3 " .. s .. " 2>&1")
  local out = pipe:read("*a")
  local ok, _, code = pipe:close()
  io.write(out)
  for n in out:gmatch("(%d+) passed,") do total = total + tonumber(n) end
  if not (ok == true or ok == 0) or (code and code ~= 0) then
    failed = failed + 1
  end
end

-- Documentation rots the moment it quotes a number nothing checks. CLAUDE.md
-- and README.md both cite the assertion count as evidence for how much the
-- suite covers, and a stale figure there is a small lie that makes the
-- larger claims around it look equally unmaintained.
if failed == 0 then
  for _, doc in ipairs({ "CLAUDE.md", "README.md" }) do
    local h = io.open(doc, "r")
    if h then
      local text = h:read("*a")
      h:close()
      local claimed = text:match("(%d+)%s+assertions")
      if claimed and tonumber(claimed) ~= total then
        print(("\n%s says %s assertions; there are %d")
          :format(doc, claimed, total))
        failed = failed + 1
      end
    end
  end
end

print(("\n%d assertions in total"):format(total))

print(failed == 0 and "\nALL SUITES PASSED" or ("\n%d SUITE(S) FAILED"):format(failed))
os.exit(failed == 0 and 0 or 1)
