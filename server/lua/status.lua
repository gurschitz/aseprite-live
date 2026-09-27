-- What's open in Aseprite and what the active sprite looks like. P = {} (no params).
local function hex(c)
  return string.format("#%02x%02x%02x%02x", c.red, c.green, c.blue, c.alpha)
end

local open = {}
for _, s in ipairs(app.sprites) do open[#open + 1] = s.filename end

local spr = app.sprite
local status = {
  aseprite = tostring(app.version),
  openSprites = open,
  tool = app.tool and app.tool.id,
  fgColor = hex(app.fgColor),
  bgColor = hex(app.bgColor),
}
if not spr then return status end

local modes = { [ColorMode.RGB] = "rgb", [ColorMode.GRAYSCALE] = "grayscale",
                [ColorMode.INDEXED] = "indexed", [ColorMode.TILEMAP] = "tilemap" }

-- Top to bottom, as the timeline shows them.
local function layers(list)
  local out = {}
  for i = #list, 1, -1 do
    local l = list[i]
    local e = { name = l.name }
    if not l.isVisible then e.hidden = true end
    if l.opacity ~= 255 then e.opacity = l.opacity end
    if l.isGroup then e.group = true; e.layers = layers(l.layers) end
    if l.isTilemap then e.tilemap = true end
    if l.isReference then e.reference = true end
    if l == app.layer then e.active = true end
    out[#out + 1] = e
  end
  return out
end

local durations, same = {}, true
for i, f in ipairs(spr.frames) do
  durations[i] = math.floor(f.duration * 1000 + 0.5)
  if durations[i] ~= durations[1] then same = false end
end

local tags = {}
for _, t in ipairs(spr.tags) do
  tags[#tags + 1] = { name = t.name, from = t.fromFrame.frameNumber, to = t.toFrame.frameNumber }
end

local pal = spr.palettes[1]
local palette = { size = #pal }
if #pal <= 64 then
  palette.colors = {}
  for i = 0, #pal - 1 do palette.colors[i + 1] = hex(pal:getColor(i)) end
end

status.sprite = {
  filename = spr.filename,
  width = spr.width,
  height = spr.height,
  colorMode = modes[spr.colorMode] or tostring(spr.colorMode),
  frames = #spr.frames,
  frameDurationsMs = same and durations[1] or durations,
  activeFrame = app.frame and app.frame.frameNumber,
  layers = layers(spr.layers),
  tags = tags,
  palette = palette,
  selection = (not spr.selection.isEmpty) and {
    x = spr.selection.bounds.x, y = spr.selection.bounds.y,
    width = spr.selection.bounds.width, height = spr.selection.bounds.height,
  } or nil,
  modified = spr.isModified,
}
return status
