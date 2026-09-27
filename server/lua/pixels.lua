-- Read a region as a character grid + colour legend.
-- P = { sprite?, frame?, layer? (only that layer's cel, whatever its visibility), show?, hide?, only?,
--       region? = {x,y,w,h} (default: content box + 1px), legend? = {char = "#hex"} to reuse chars }
-- Returns { grid, legend, region, frame, source }.
local spr = L.sprite(P.sprite)
local f = L.frames(spr, P)[1]
local img, source
if P.layer then
  local layer, path = L.layer(spr, P.layer)
  if layer.isGroup then
    img = L.composite(spr, f, L.visOpts{ only = { path } }); source = "group " .. path
  else
    img = L.celCanvas(spr, layer, f); source = "layer " .. path
  end
else
  img = L.composite(spr, f, L.visOpts{ show = P.show, hide = P.hide, only = P.only }); source = "composite"
end

local rg
if type(P.region) == "table" then
  rg = { x = math.tointeger(P.region.x) or 0, y = math.tointeger(P.region.y) or 0,
         w = math.tointeger(P.region.w) or spr.width, h = math.tointeger(P.region.h) or spr.height }
else
  local b = L.bbox(img)
  if b then
    local x0, y0 = math.max(0, b.x - 1), math.max(0, b.y - 1)
    local x1, y1 = math.min(spr.width - 1, b.x + b.w), math.min(spr.height - 1, b.y + b.h)
    rg = { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
  else
    rg = { x = 0, y = 0, w = spr.width, h = spr.height }
  end
end

local POOL = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@$%&*+=?<>~^:;"
local byHex, used = {}, {}
if type(P.legend) == "table" then
  for ch, h in pairs(P.legend) do
    local hx = tostring(h):gsub("^#", ""):lower()
    byHex[hx] = ch; used[ch] = true
  end
end
local nextI = 1
local function charFor(hx)
  local ch = byHex[hx]
  if ch then return ch end
  while nextI <= #POOL and used[POOL:sub(nextI, nextI)] do nextI = nextI + 1 end
  if nextI > #POOL then error("more than " .. #POOL .. " colours in the region; read a smaller region") end
  ch = POOL:sub(nextI, nextI)
  byHex[hx] = ch; used[ch] = true
  return ch
end

local lines = {}
-- column header: tens and ones of x
local tens, ones = {}, {}
for x = rg.x, rg.x + rg.w - 1 do
  tens[#tens + 1] = (x % 10 == 0 or x == rg.x) and tostring(x // 10 % 10) or " "
  ones[#ones + 1] = tostring(x % 10)
end
lines[#lines + 1] = "    " .. table.concat(tens)
lines[#lines + 1] = "    " .. table.concat(ones)
local seen = {}
for y = rg.y, rg.y + rg.h - 1 do
  local row = {}
  for x = rg.x, rg.x + rg.w - 1 do
    local p = (x >= 0 and y >= 0 and x < spr.width and y < spr.height) and img:getPixel(x, y) or 0
    if pc.rgbaA(p) == 0 then row[#row + 1] = "."
    else
      local hx = L.hex(p)
      local ch = charFor(hx)
      seen[ch] = hx
      row[#row + 1] = ch
    end
  end
  lines[#lines + 1] = string.format("%3d ", y) .. table.concat(row)
end
local legend = {}
for ch, hx in pairs(seen) do legend[ch] = "#" .. hx end
return { grid = table.concat(lines, "\n"), legend = legend, region = rg, frame = f, source = source, sprite = L.basename(spr) }
