--[[ ui/origin.lua ---------------------------------------------------------
  Which copy of the library is this machine running?

  install.lua remembers where it pulled from in /.ccagent/source --
  including the ref, so a turtle switched to a branch stays on that branch
  for every later bare `install`. That is the useful behaviour and also
  the hazard: nothing on the screen said so, and two turtles could be on
  different code with no way to tell them apart.

  So this reads that file back. It is deliberately read-only: install.lua
  owns the format and the writing, and a second writer would be a second
  thing to keep in step. Parsing it twice is the cheaper duplication.

  WHERE THIS IS SHOWN, AND WHERE IT IS NOT.

  /doctor, because the question it already answers is "is this turtle
  running the code you think it is", and the ref is now half that answer.
  The share bundle, because a report from a feature branch is otherwise
  indistinguishable from one off main.

  NOT agent.situation(). That string is written for Claude, not for the
  operator -- it rides in every request, and which branch the library
  came from is not something a generated program should reason about. The
  state line already gets read as a verdict on what is possible; adding
  provenance to it would be one more thing to misread.
--------------------------------------------------------------------------]]

local origin = {}

origin.path       = "/.ccagent/source"
origin.DEFAULT_REF = "main"      -- install.lua's default, kept in step by hand

--- Read the stored source. Returns { source, repo, ref, headers } -- any
--- field may be absent, including on a machine installed from a floppy,
--- which has a source and no repo or ref at all.
function origin.read()
  local conf = { headers = {} }
  if not fs or not fs.exists(origin.path) then return conf end
  local h = fs.open(origin.path, "r")
  if not h then return conf end
  local text = h.readAll() or ""
  h.close()
  -- Same shape install.lua writes: key=value, "#" comments, header.Name.
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

--- The ref this machine pulls, or nil when the source does not have one
--- (a local directory install never does).
function origin.ref(conf)
  conf = conf or origin.read()
  if not conf.source then return nil end
  if conf.source:find("{ref}", 1, true) == nil then return nil end
  return conf.ref or origin.DEFAULT_REF
end

--- True when this machine is pulling something other than the default
--- ref -- the state worth saying out loud, because it is the one you
--- forget you are in.
function origin.offDefault(conf)
  local ref = origin.ref(conf)
  return ref ~= nil and ref ~= origin.DEFAULT_REF, ref
end

--- One line for a 39-column screen. nil when there is nothing to say,
--- so a plain install off main prints nothing extra.
---   opts.always  report the ref even when it is the default
function origin.line(opts)
  local conf = origin.read()
  local off, ref = origin.offDefault(conf)
  if not ref then
    if not (opts and opts.always) then return nil end
    return conf.source and ("from " .. conf.source) or "no source stored"
  end
  if not off and not (opts and opts.always) then return nil end
  return ("ref %s%s"):format(ref, conf.repo and ("  " .. conf.repo) or "")
end

return origin
