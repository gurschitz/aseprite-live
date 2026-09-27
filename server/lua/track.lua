-- How a layer (or the composite) moves across frames, relative to a reference frame.
-- P = { sprite?, layer? , show?, hide?, only?, ref?, frame?/frames?/tag?, rows? = {y0, y1}, maxShift? }
-- For each frame: best whole-pixel shift (dx, dy) that maps the reference onto it, how well it
-- matches (0–1), the content box, and the lowest opaque row in the left / right half of that box
-- (for a front/back view: which foot is lower on screen, i.e. forward).
local spr = L.sprite(P.sprite)
local frames = L.frames(spr, P)
local ref = math.tointeger(P.ref) or frames[1]
local maxShift = math.tointeger(P.maxShift) or 3

local layer, path
if P.layer then layer, path = L.layer(spr, P.layer) end
local function image(f)
  if layer and not layer.isGroup then return L.celCanvas(spr, layer, f) end
  if layer then return L.composite(spr, f, L.visOpts{ only = { path } }) end
  return L.composite(spr, f, L.visOpts{ show = P.show, hide = P.hide, only = P.only })
end

local y0, y1 = 0, spr.height - 1
if type(P.rows) == "table" then y0 = math.tointeger(P.rows[1]) or y0; y1 = math.tointeger(P.rows[2]) or y1 end

local refImg = image(ref)
local refPx = {}
for y = y0, y1 do for x = 0, spr.width - 1 do
  local p = refImg:getPixel(x, y)
  if pc.rgbaA(p) > 0 then refPx[#refPx + 1] = { x, y, p } end
end end
if #refPx == 0 then error("reference frame " .. ref .. " has no pixels in rows " .. y0 .. "–" .. y1) end

local out = {}
for _, f in ipairs(frames) do
  local cur = image(f)
  local best, bdx, bdy = -math.huge, 0, 0
  for dy = -maxShift, maxShift do
    for dx = -maxShift, maxShift do
      local hit = 0
      for _, e in ipairs(refPx) do
        local x, y = e[1] + dx, e[2] + dy
        if x >= 0 and y >= 0 and x < spr.width and y < spr.height and cur:getPixel(x, y) == e[3] then hit = hit + 1 end
      end
      -- prefer the smallest shift on ties
      if hit > best or (hit == best and math.abs(dx) + math.abs(dy) < math.abs(bdx) + math.abs(bdy)) then
        best, bdx, bdy = hit, dx, dy
      end
    end
  end
  local box = L.bbox(cur)
  local lowL, lowR
  if box then
    local mid = box.x + box.w / 2
    for it in cur:pixels() do
      if pc.rgbaA(it()) > 0 then
        if it.x < mid then lowL = math.max(lowL or -1, it.y) else lowR = math.max(lowR or -1, it.y) end
      end
    end
  end
  out[#out + 1] = { frame = f, dx = bdx, dy = bdy, match = math.floor(best / #refPx * 100 + 0.5) / 100,
                    box = box, lowestLeft = lowL, lowestRight = lowR }
end
return { sprite = L.basename(spr), source = path or "composite", ref = ref, rows = { y0, y1 }, frames = out }
