-- Stamp a character grid onto one layer, on one or more frames.
-- P = { sprite?, layer, create?, frame?/frames?/tag?, x, y, rows = {"..ab..", ...},
--       legend = {char = "#hex" | "clear"}, mode? = "merge"|"replace",
--       offsets? = { ["<frame>"] = {dx, dy} }, clip? = { silhouette? = bool, under? = {paths} } }
-- '.' and ' ' leave pixels alone. "clear" makes a pixel transparent (never clipped).
-- Returns per-frame counts of drawn / clipped / cleared pixels.
local spr = L.sprite(P.sprite)
if spr.colorMode ~= ColorMode.RGB then error("draw_grid supports RGB sprites only (this one isn't)") end
if type(P.rows) ~= "table" or #P.rows == 0 then error("rows is empty") end
if type(P.legend) ~= "table" then error("legend is required, e.g. {a = '#1c3044'}") end

local layer, path
local okFind, a, b = pcall(L.layer, spr, P.layer)
if okFind then layer, path = a, b
elseif P.create then
  local parentPath, name = P.layer:match("^(.*)/([^/]+)$")
  local parent
  if parentPath then
    parent = L.layer(spr, parentPath)
    if not parent.isGroup then error("'" .. parentPath .. "' is not a group") end
  end
  layer = spr:newLayer()
  layer.name = name or P.layer
  if parent then layer.parent = parent; layer.stackIndex = #parent.layers end
  path = P.layer
else
  error(a .. " (pass create=true to make it)")
end
if layer.isGroup then error("'" .. path .. "' is a group; draw on a layer inside it") end

local colours = {}
for ch, v in pairs(P.legend) do
  colours[ch] = (v == "clear") and "clear" or L.parseHex(v)
end

local x0, y0 = math.tointeger(P.x) or 0, math.tointeger(P.y) or 0
local mode = P.mode or "merge"
local clip = P.clip or {}
local report = {}

for _, f in ipairs(L.frames(spr, P)) do
  local off = P.offsets and (P.offsets[tostring(f)] or P.offsets[f]) or nil
  local dx, dy = 0, 0
  if off then dx, dy = math.tointeger(off[1]) or 0, math.tointeger(off[2]) or 0 end

  local sil, blockers
  if clip.silhouette then sil = L.composite(spr, f, L.visOpts{ exclude = { path } }) end
  if type(clip.under) == "table" and #clip.under > 0 then
    for _, p in ipairs(clip.under) do L.layer(spr, p) end
    blockers = L.composite(spr, f, L.visOpts{ only = clip.under })
  end

  -- Work on an image that covers both the canvas and the existing cel, so off-canvas pixels survive.
  local frame = spr.frames[f]
  local cel = layer:cel(frame)
  local ox, oy, W, H = 0, 0, spr.width, spr.height
  if cel and mode ~= "replace" then
    local p, im = cel.position, cel.image
    ox, oy = math.min(0, p.x), math.min(0, p.y)
    W = math.max(spr.width, p.x + im.width) - ox
    H = math.max(spr.height, p.y + im.height) - oy
  end
  local work = Image(W, H, ColorMode.RGB)
  if cel and mode ~= "replace" then work:drawImage(cel.image, Point(cel.position.x - ox, cel.position.y - oy)) end

  local drawn, clipped, cleared = 0, 0, 0
  for r, rowStr in ipairs(P.rows) do
    for i = 1, #rowStr do
      local ch = rowStr:sub(i, i)
      if ch ~= "." and ch ~= " " then
        local col = colours[ch]
        if col == nil then error("character '" .. ch .. "' (row " .. r .. ") is not in the legend") end
        local x, y = x0 + i - 1 + dx, y0 + r - 1 + dy
        if col == "clear" then
          work:drawPixel(x - ox, y - oy, 0); cleared = cleared + 1
        elseif x < 0 or y < 0 or x >= spr.width or y >= spr.height
            or (sil and not L.opaque(sil, x, y))
            or (blockers and L.opaque(blockers, x, y)) then
          clipped = clipped + 1
        else
          work:drawPixel(x - ox, y - oy, col); drawn = drawn + 1
        end
      end
    end
  end

  if cel then cel.image = work; cel.position = Point(ox, oy)
  else spr:newCel(layer, frame, work, Point(ox, oy)) end
  report[#report + 1] = { frame = f, drawn = drawn, clipped = clipped, cleared = cleared, offset = { dx, dy } }
end
app.refresh()
return { sprite = L.basename(spr), layer = path, frames = report }
