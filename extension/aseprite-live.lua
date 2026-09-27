-- Aseprite Live: the Aseprite half of the bridge.
--
-- Aseprite's WebSocket can only be a client, so the MCP server listens and we connect to it.
-- We try a few ports so several Claude Code sessions (one MCP server each) can be connected
-- at once; each socket reconnects on its own when its server comes and goes.
--
-- Protocol (JSON text frames):
--   us → server   {type="hello", version}
--   server → us   {id, token, code, undoable}
--   us → server   {id, ok, result, output, error}
--
-- `code` is Lua run on the UI thread against the open sprite. With `undoable`, it runs in one
-- transaction: a single ⌘Z undoes it, and an error rolls the whole call back.
--
-- The request handling itself is in handler.lua, reloaded per request (no restart for fixes).
-- Anything that goes wrong is sent back as {type="log", message} so the server can show it.
--
-- The token lives in ~/.aseprite-live/token (created here on first start). A request without
-- it is refused, so only processes that can read your home directory can drive Aseprite.

local PORTS = { 7317, 7318, 7319, 7320 }

local sockets = {}
local token
local handlerPath

local function tokenPath()
  return app.fs.joinPath(os.getenv("HOME"), ".aseprite-live", "token")
end

local function loadOrCreateToken()
  local path = tokenPath()
  local f = io.open(path, "r")
  if f then
    local t = f:read("l")
    f:close()
    if t and #t >= 32 then return t end
  end
  app.fs.makeAllDirectories(app.fs.filePath(path))
  math.randomseed(os.time() + math.floor(os.clock() * 1e6))
  local hex = {}
  for i = 1, 48 do hex[i] = string.format("%x", math.random(0, 15)) end
  local t = table.concat(hex)
  f = assert(io.open(path, "w"))
  f:write(t, "\n")
  f:close()
  return t
end

function init(plugin)
  -- Command-line runs (aseprite -b) must not open sockets or take requests.
  if not app.isUIAvailable then return end
  token = loadOrCreateToken()
  handlerPath = app.fs.joinPath(plugin.path, "handler.lua")
  for _, port in ipairs(PORTS) do
    local ws
    ws = WebSocket{
      url = "ws://127.0.0.1:" .. port,
      deflate = false,
      minreconnectwait = 1,
      maxreconnectwait = 3,
      -- Other kinds (CLOSE, ERROR while no server listens on this port) are ignored: the socket
      -- reconnects by itself. Never let an error escape this callback; that stops reconnecting.
      onreceive = function(kind, data)
        if kind == WebSocketMessageType.OPEN then
          pcall(ws.sendText, ws, json.encode({ type = "hello", version = tostring(app.version) }))
        elseif kind == WebSocketMessageType.TEXT then
          local ok, err = pcall(function()
            local handle = assert(loadfile(handlerPath))()
            handle(ws, data, token)
          end)
          if not ok then
            pcall(ws.sendText, ws, json.encode({ type = "log", message = "handler failed: " .. tostring(err) }))
          end
        end
      end,
    }
    ws:connect()
    sockets[#sockets + 1] = ws
  end
end

function exit(plugin)
  for _, ws in ipairs(sockets) do ws:close() end
  sockets = {}
end
