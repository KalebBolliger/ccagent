--[[ claude/extract.lua --------------------------------------------------
  Pull the program out of a model reply.

  This is a small file with a bad reputation, because every failure mode
  here looks like a model failure: a stray ``` inside a comment, a fence
  tagged ```luau or ```Lua, an unterminated fence when the response was cut
  off at max_tokens, or a reply that is prose with no fence at all. All four
  are handled explicitly rather than by one hopeful gsub.
--------------------------------------------------------------------------]]

local extract = {}

local LUA_TAGS = { lua = true, luau = true, ["lua5.2"] = true, cc = true,
                   computercraft = true, [""] = true, text = true }

--- Returns code, note. `note` explains any repair we had to do, so the
--- controller can surface it.
function extract.code(reply)
  if not reply or reply == "" then return nil, "empty reply" end

  local blocks = {}
  local pos = 1
  while true do
    local s, e, tag = reply:find("```([%w_%.%-]*)[ \t]*\r?\n", pos)
    if not s then break end
    local closeS, closeE = reply:find("\r?\n[ \t]*```", e)
    local body, closed
    if closeS then
      body = reply:sub(e + 1, closeS - 1)
      closed = true
      pos = closeE + 1
    else
      -- Unterminated fence: almost always a truncated response.
      body = reply:sub(e + 1)
      closed = false
      pos = #reply + 1
    end
    blocks[#blocks + 1] = { tag = (tag or ""):lower(), body = body, closed = closed }
  end

  if #blocks == 0 then
    -- No fence. If the whole reply parses as Lua, take it; otherwise the
    -- model answered in prose and that is a real failure worth reporting.
    local fn = load(reply, "@job", "t", {})
    if fn then return reply, "reply had no code fence; used the whole reply" end
    return nil, "no lua code block in the reply"
  end

  -- Prefer an explicitly lua-tagged, properly closed block; then any closed
  -- block; then whatever we have.
  local chosen
  for _, b in ipairs(blocks) do
    if LUA_TAGS[b.tag] and b.closed then chosen = b; break end
  end
  if not chosen then
    for _, b in ipairs(blocks) do if b.closed then chosen = b; break end end
  end
  chosen = chosen or blocks[1]

  local note = nil
  if not chosen.closed then
    note = "code block was not closed -- the response was probably truncated"
  elseif #blocks > 1 then
    note = ("reply contained %d code blocks; used the first usable one"):format(#blocks)
  end

  local code = chosen.body:gsub("^%s*\n", ""):gsub("%s+$", "")
  if code == "" then return nil, "code block was empty" end
  return code, note
end

--- Compile-check without running. Returns ok, err (with line numbers that
--- match the source we would execute).
function extract.check(code)
  local fn, err = load(code, "@job", "t", {})
  if fn then return true end
  return false, err
end

return extract
