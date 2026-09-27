-- Aseprite Live request handler. The extension loads this file fresh for every request, so
-- changes here only need ./install.sh, not an Aseprite restart.
--
-- Returns handle(ws, text, token).

-- json.encode turns userdata into null; show those as their tostring() instead.
local function encodable(v, depth)
  depth = depth or 0
  local tv = type(v)
  if tv == "userdata" or tv == "function" then return tostring(v) end
  if tv ~= "table" or depth > 8 then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = encodable(x, depth + 1) end
  return out
end

local function run(msg)
  local output = {}
  local env = setmetatable({
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
      output[#output + 1] = table.concat(parts, "\t")
    end,
  }, { __index = _G })

  local fn, err = load(msg.code or "", "=claude", "t", env)
  if not fn then return { ok = false, error = err, output = output } end

  local results
  local function call() results = table.pack(fn()) end
  local ok, runErr
  if msg.undoable ~= false and app.sprite then
    ok, runErr = pcall(app.transaction, "Claude", call)
  else
    ok, runErr = pcall(call)
  end
  app.refresh()
  if not ok then return { ok = false, error = tostring(runErr), output = output } end

  local result
  if results.n == 1 then result = results[1]
  elseif results.n > 1 then result = { table.unpack(results, 1, results.n) } end
  return { ok = true, result = encodable(result), output = output }
end

return function(ws, text, token)
  -- Aseprite's json.decode returns a userdata (not a table) and numbers as floats.
  local ok, msg = pcall(json.decode, text)
  if not ok or msg == nil or msg.id == nil then
    ws:sendText(json.encode({ type = "log", message = "unreadable request: " .. text:sub(1, 200) }))
    return
  end
  local reply
  if msg.token ~= token then
    reply = { ok = false, error = "bad token (does ~/.aseprite-live/token match?)" }
  else
    reply = run(msg)
  end
  reply.id = math.tointeger(msg.id) or msg.id
  local encOk, s = pcall(json.encode, reply)
  if not encOk then
    s = json.encode({ id = reply.id, ok = false, error = "could not encode result: " .. tostring(s) })
  end
  ws:sendText(s)
end

