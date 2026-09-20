--[[ ui/console.lua ------------------------------------------------------
  Terminal output helpers shared by the controller and the host. Degrades
  to plain print() on a non-colour terminal or a monitor.
--------------------------------------------------------------------------]]

local util = require("agent.util")

local console = {}

local function colour(c)
  if term and term.isColour and term.isColour() and _G.colors then
    term.setTextColour(c)
  end
end

local function reset()
  if term and _G.colors then
    if term.isColour and term.isColour() then term.setTextColour(colors.white) end
  end
end

local function line(c, prefix, text)
  colour(c)
  local w = (term and term.getSize) and select(1, term.getSize()) or 51
  local body = (prefix or "") .. tostring(text)
  for _, l in ipairs(util.wrap(body, math.max(w - 1, 20))) do
    print(l)
  end
  reset()
end

function console.info(t)  line(_G.colors and colors.white     or nil, "",    t) end
function console.dim(t)   line(_G.colors and colors.lightGray or nil, "",    t) end
function console.say(t)   line(_G.colors and colors.lime      or nil, "",   t) end
function console.warn(t)  line(_G.colors and colors.orange    or nil, "! ",  t) end
function console.err(t)   line(_G.colors and colors.red       or nil, "x ",  t) end
function console.status(t)line(_G.colors and colors.cyan      or nil, ".. ", t) end
function console.head(t)  line(_G.colors and colors.yellow    or nil, "",    t) end

function console.rule()
  local w = (term and term.getSize) and select(1, term.getSize()) or 51
  console.dim(string.rep("-", w - 1))
end

--- Print generated source with line numbers, clipped.
function console.code(src, maxLines)
  maxLines = maxLines or 14
  local n = 0
  console.dim("--- program ---")
  for l in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if n > maxLines then
      console.dim(("... (%d more lines; /code shows all)")
        :format(select(2, src:gsub("\n", "\n")) + 1 - maxLines))
      break
    end
    console.dim(("%2d %s"):format(n, l))
  end
  console.dim("---------------")
end

-- The shell prompts with "> ". So did this, which left the operator
-- guessing which one they were typing at -- and the answer matters: one
-- takes CC programs, the other takes English and spends money. Colour
-- alone does not settle it, because a plain turtle is not an advanced
-- computer and term.isColour() is false there.
--
-- Four characters, because the screen is 39 wide and every one of them
-- is a character the operator cannot type in.
console.PROMPT = "cc> "

--- The prompt for a front end, optionally aimed at one turtle.
function console.promptFor(target)
  if target then return ("cc@%s> "):format(target) end
  return console.PROMPT
end

--- Blocking prompt with history, falling back to io.read outside CC.
function console.ask(promptText, history)
  colour(_G.colors and colors.yellow or nil)
  write(promptText or console.PROMPT)
  reset()
  if _G.read then return read(nil, history) end
  return io.read()
end

return console
