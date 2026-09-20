--[[ test/all.lua ------------------------------------------------------
  Runs both suites in separate processes, because each installs its own
  mock world and they must not share state.

      lua5.3 test/all.lua
--------------------------------------------------------------------------]]

local suites = { "test/run.lua", "test/run_lib.lua", "test/run_boot.lua" }
local failed = 0

for _, s in ipairs(suites) do
  print(("\n===== %s ====="):format(s))
  local ok, _, code = os.execute("lua5.3 " .. s)
  if not (ok == true or ok == 0) or (code and code ~= 0) then
    failed = failed + 1
  end
end

print(failed == 0 and "\nALL SUITES PASSED" or ("\n%d SUITE(S) FAILED"):format(failed))
os.exit(failed == 0 and 0 or 1)
