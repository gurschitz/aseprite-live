-- Contact sheet: frames as columns, variants as rows, one PNG.
-- P = { sprite?, frame?/frames?/tag?, show?, hide?, only?, highlight?,
--       rows? = { {label?, show?, hide?, only?, highlight?}, ... },
--       crop? = {x,y,w,h} | "full" (default: tight box around everything + 1px), onion?, scale?, bg?, gap? }
-- Returns { path, columns, rows, scale, crop, width, height }.
local spr = L.sprite(P.sprite)
local frames = L.frames(spr, P)
local pc = app.pixelColor

local rows = P.rows
if type(rows) ~= "table" or #rows == 0 then rows = { {} } end
local function pick(row, key) if row[key] ~= nil then return row[key] end return P[key] end

-- Render every cell first so the crop can hug the content.
local cells = {}
for r, row in ipairs(rows) do
  cells[r] = {}
  local vis = L.visOpts{ show = pick(row, "show"), hide = pick(row, "hide"), only = pick(row, "only") }
  local hl = pick(row, "highlight")
  local hlVis
  if hl then
    L.layer(spr, hl) -- validates the path
    hlVis = L.visOpts{ show = pick(row, "show"), hide = pick(row, "hide"), only = pick(row, "only"), exclude = { hl } }
  end
  for c, f in ipairs(frames) do
    local img = L.composite(spr, f, vis)
    if hl then
      -- tint what the highlighted layer contributes to the picture
      local without = L.composite(spr, f, hlVis)
      for it in img:pixels() do
        if it() ~= without:getPixel(it.x, it.y) then it(pc.rgba(235, 40, 40, 255)) end
      end
    end
    local under
    if P.onion and #frames > 1 then
      under = Image(spr.width, spr.height, ColorMode.RGB)
      local prev = frames[(c - 2) % #frames + 1]
      local nxt = frames[c % #frames + 1]
      under:drawImage(L.composite(spr, prev, vis), Point(0, 0), 70, BlendMode.NORMAL)
      under:drawImage(L.composite(spr, nxt, vis), Point(0, 0), 70, BlendMode.NORMAL)
    end
    cells[r][c] = { img = img, under = under }
  end
end

local crop
if type(P.crop) == "table" then
  crop = { x = math.tointeger(P.crop.x) or 0, y = math.tointeger(P.crop.y) or 0,
           w = math.tointeger(P.crop.w) or spr.width, h = math.tointeger(P.crop.h) or spr.height }
elseif P.crop == "full" then
  crop = { x = 0, y = 0, w = spr.width, h = spr.height }
else
  local x0, y0, x1, y1
  for r = 1, #cells do for c = 1, #cells[r] do
    for _, im in ipairs({ cells[r][c].img, cells[r][c].under }) do
      local b = L.bbox(im)
      if b then
        x0 = math.min(x0 or b.x, b.x); y0 = math.min(y0 or b.y, b.y)
        x1 = math.max(x1 or b.x + b.w - 1, b.x + b.w - 1); y1 = math.max(y1 or b.y + b.h - 1, b.y + b.h - 1)
      end
    end
  end end
  if not x0 then crop = { x = 0, y = 0, w = spr.width, h = spr.height }
  else
    x0 = math.max(0, x0 - 1); y0 = math.max(0, y0 - 1)
    x1 = math.min(spr.width - 1, x1 + 1); y1 = math.min(spr.height - 1, y1 + 1)
    crop = { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
  end
end

local gap = math.tointeger(P.gap) or 2
local bg = L.parseHex(P.bg or "d6e2e6")
local gapColor = pc.rgba(math.floor(pc.rgbaR(bg) * 0.8), math.floor(pc.rgbaG(bg) * 0.8), math.floor(pc.rgbaB(bg) * 0.8), 255)
local W = #frames * crop.w + (#frames + 1) * gap
local H = #rows * crop.h + (#rows + 1) * gap
local sheet = Image(W, H, ColorMode.RGB)
sheet:clear(gapColor)
for r = 1, #rows do
  for c = 1, #frames do
    local ox, oy = gap + (c - 1) * (crop.w + gap), gap + (r - 1) * (crop.h + gap)
    local cell = Image(crop.w, crop.h, ColorMode.RGB)
    cell:clear(bg)
    if cells[r][c].under then cell:drawImage(cells[r][c].under, Point(-crop.x, -crop.y)) end
    cell:drawImage(cells[r][c].img, Point(-crop.x, -crop.y))
    sheet:drawImage(cell, Point(ox, oy))
  end
end

local scale = math.tointeger(P.scale)
if not scale then
  scale = math.max(1, math.min(24, math.floor(1400 / W), math.floor(900 / H)))
end
if scale > 1 then sheet:resize(W * scale, H * scale) end
local path = L.tempPng("sheet")
sheet:saveAs(path)

local labels = {}
for r, row in ipairs(rows) do labels[r] = row.label or ("row " .. r) end
return { path = path, sprite = L.basename(spr), columns = frames, rows = labels, scale = scale, crop = crop,
         width = W * scale, height = H * scale }
