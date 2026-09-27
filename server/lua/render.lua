-- Flatten one frame (or one layer's cel) to a scaled-up PNG in the temp dir.
-- P = { sprite?, frame?, layer?, show?, hide?, only?, scale? }.
-- Returns { path, width, height, scale, frame, frames, sprite }.
local spr = L.sprite(P.sprite)
local fi = L.frames(spr, P)[1]

local img
if P.layer then
  local layer, path = L.layer(spr, P.layer)
  if layer.isGroup then img = L.composite(spr, fi, L.visOpts{ only = { path } })
  else img = L.celCanvas(spr, layer, fi) end
else
  img = L.composite(spr, fi, L.visOpts{ show = P.show, hide = P.hide, only = P.only })
end

-- Nearest-neighbour upscale so the pixels stay crisp; ~512px on the long side by default.
local scale = math.tointeger(P.scale) or math.max(1, math.min(16, math.floor(512 / math.max(spr.width, spr.height))))
if scale > 1 then img:resize(spr.width * scale, spr.height * scale) end

local path = L.tempPng("render")
img:saveAs(path)
return { path = path, width = spr.width, height = spr.height, scale = scale, frame = fi, frames = #spr.frames,
         sprite = L.basename(spr) }
