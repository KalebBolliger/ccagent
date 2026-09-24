--[[ /ccagent/config.lua -------------------------------------------------
  Edit this file. Anything you leave out keeps its default.

  The API key is better kept in /.ccagent/key (one line, nothing else) so
  this file stays safe to copy between turtles or paste into a pastebin.
  `ccagent/install.lua` will prompt for it on first run.
--------------------------------------------------------------------------]]

return {
  -- apiKey = "sk-ant-...",          -- prefer /.ccagent/key instead

  model      = "claude-sonnet-5",    -- claude-opus-5 for hard jobs

  -- Current models think before they write, and that thinking is spent
  -- out of maxTokens. Too small a budget fails as "max_tokens with no
  -- text": all of it went to thinking and the program never started.
  maxTokens  = 32000,
  effort     = "medium",             -- low | medium | high | xhigh | max
                                     -- low is faster and cheaper; raise it
                                     -- for jobs that need real planning
  maxRepairs = 2,                    -- auto-fix attempts after a runtime error
  cache      = true,                 -- keep true: this is most of the savings

  -- Big jobs take a while to write. CC kills a silent connection after 30s
  -- by default, so responses are streamed to keep bytes moving; turning
  -- this off puts that ceiling back and long jobs fail with "Timed out".
  -- stream      = true,
  -- timeout     = 180,              -- seconds we will wait for one attempt
  -- readTimeout = 60,               -- seconds of silence CC tolerates (max 60)

  -- Thinking is ON by default on current models -- leaving this unset is
  -- not the same as turning it off. Prefer a lower `effort` over
  -- disabling it; the programs are better with it.
  -- thinking = "off",

  -- Appended verbatim to the system prompt. Good place for house rules:
  -- operatorNotes = [[
  --   The base is at 120,64,-300. Storage chests are on its north wall.
  --   Never dig above y=70 near the base.
  -- ]],

  protocol = "ccagent",              -- rednet protocol for host/worker mode
  hostname = "ccagent-host",

  logLevel = "info",                 -- debug | info | warn | error
}
