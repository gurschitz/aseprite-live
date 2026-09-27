-- Shared helpers, prepended to every snippet (before the snippet's own code, after P).
-- Everything lives in the local table L.
local L = {}
local pc = app.pixelColor

-- ---------- sprites ----------

-- P.sprite: nil/"" → the active sprite; else a full path, a file name, or a file name without
-- extension. Several matches is an error, so a tool never edits a sprite you didn't mean.
function L.sprite(name)
  if name == nil or name == "" then
    if not app.sprite then error("no sprite is open in Aseprite") end
    return app.sprite
  end
  local hits, open = {}, {}
  for _, s in ipairs(app.sprites) do
    local fn = s.filename
    local base = fn:match("[^/\\]+$") or fn
    local noext = base:gsub("%.[^.]+$", "")
    open[#open + 1] = base
    if fn == name or base == name or noext == name then hits[#hits + 1] = s end
  end
  if #hits == 0 then error("no open sprite matches '" .. name .. "' (open: " .. table.concat(open, ", ") .. ")") end
  if #hits > 1 then error("'" .. name .. "' matches " .. #hits .. " open sprites; pass the full path") end
  return hits[1]
end

function L.basename(spr) return spr.filename:match("[^/\\]+$") or spr.filename end

-- ---------- layers ----------

-- All layers bottom → top, depth first, with their paths.
function L.allLayers(spr)
  local out = {}
  local function walk(list, prefix)
    for _, l in ipairs(list) do
      local path = prefix and (prefix .. "/" .. l.name) or l.name
      out[#out + 1] = { layer = l, path = path }
      if l.isGroup then walk(l.layers, path) end
    end
  end
  walk(spr.layers, nil)
  return out
end

-- "Group/Layer" path, or a bare name that is unique in the sprite.
function L.layer(spr, path)
  local all = L.allLayers(spr)
  for _, e in ipairs(all) do if e.path == path then return e.layer, e.path end end
  local hits = {}
  for _, e in ipairs(all) do if e.layer.name == path then hits[#hits + 1] = e end end
  if #hits == 1 then return hits[1].layer, hits[1].path end
  if #hits > 1 then
    local ps = {}
    for _, e in ipairs(hits) do ps[#ps + 1] = e.path end
    error("layer name '" .. path .. "' is ambiguous; use one of: " .. table.concat(ps, ", "))
  end
  error("no layer '" .. path .. "' in " .. L.basename(spr))
end

-- ---------- frames ----------

-- sel = { frame?, frames?, tag? } → list of frame numbers.
-- frames may be a list of numbers or a string like "10-18" or "2,4,6-8".
function L.frames(spr, sel)
  sel = sel or {}
  local n = #spr.frames
  local out = {}
  local function add(i)
    i = math.tointeger(i)
    if not i or i < 1 or i > n then error("frame " .. tostring(i) .. " out of range (1–" .. n .. ")") end
    out[#out + 1] = i
  end
  if sel.tag then
    local found
    for _, t in ipairs(spr.tags) do if t.name == sel.tag then found = t end end
    if not found then
      local names = {}
      for _, t in ipairs(spr.tags) do names[#names + 1] = t.name end
      error("no tag '" .. sel.tag .. "' (tags: " .. table.concat(names, ", ") .. ")")
    end
    for i = found.fromFrame.frameNumber, found.toFrame.frameNumber do add(i) end
  elseif type(sel.frames) == "table" then
    for _, i in ipairs(sel.frames) do add(i) end
  elseif type(sel.frames) == "string" then
    for part in sel.frames:gmatch("[^,%s]+") do
      local a, b = part:match("^(%d+)%-(%d+)$")
      if a then for i = tonumber(a), tonumber(b) do add(i) end
      else add(tonumber(part)) end
    end
  elseif sel.frame then
    add(sel.frame)
  else
    add(app.frame and app.sprite == spr and app.frame.frameNumber or 1)
  end
  return out
end

-- ---------- compositing without touching the user's visibility ----------

-- Draw a cel onto an RGB canvas image, converting indexed/grayscale on the way.
local function drawCel(dst, spr, cel, opacity, blend)
  local src, pos = cel.image, cel.position
  if src.colorMode ~= ColorMode.RGB then
    local conv = Image(src.width, src.height, ColorMode.RGB)
    local pal = spr.palettes[1]
    for it in src:pixels() do
      local v, rgba = it(), 0
      if src.colorMode == ColorMode.INDEXED then
        if v ~= spr.transparentColor and v < #pal then rgba = pal:getColor(v).rgbaPixel end
      elseif src.colorMode == ColorMode.GRAYSCALE then
        local g = pc.grayaV(v)
        rgba = pc.rgba(g, g, g, pc.grayaA(v))
      end
      if rgba ~= 0 then conv:drawPixel(it.x, it.y, rgba) end
    end
    src = conv
  end
  dst:drawImage(src, pos, opacity, blend)
end

-- vis = { show = {path=true}, hide = {path=true}, only = {path=true} | nil, exclude = {path=true} }
-- show/hide override the stored visibility of that layer or group for this render only.
-- only: draw just these layers/groups (and their children), everything else is skipped.
-- exclude: skip these even if visible (used internally, e.g. "everything but the target layer").
function L.visOpts(t)
  t = t or {}
  local function set(list)
    local s = {}
    if type(list) == "table" then for _, p in ipairs(list) do s[p] = true end end
    return s
  end
  local only = nil
  if type(t.only) == "table" and #t.only > 0 then only = set(t.only) end
  return { show = set(t.show), hide = set(t.hide), only = only, exclude = set(t.exclude) }
end

function L.composite(spr, frameNo, vis)
  vis = vis or L.visOpts()
  local img = Image(spr.width, spr.height, ColorMode.RGB)
  local frame = spr.frames[frameNo]
  -- selected: this layer (or an ancestor) is in `only`, or there is no `only`.
  local function walk(list, prefix, selectedParent, groupOpacity)
    for _, l in ipairs(list) do
      local path = prefix and (prefix .. "/" .. l.name) or l.name
      local named = vis.only ~= nil and vis.only[path] == true
      local selected = selectedParent or vis.only == nil or named
      local visible = l.isVisible
      if vis.show[path] or named then visible = true end
      if vis.hide[path] or vis.exclude[path] or l.isReference then visible = false end
      local opacity = groupOpacity * ((l.opacity or 255) / 255)
      if l.isGroup then
        -- With `only`, look inside unselected groups even if hidden: a named layer may be in there.
        local searchOnly = vis.only ~= nil and not selected and not vis.hide[path] and not vis.exclude[path]
        if visible or searchOnly then walk(l.layers, path, selected, opacity) end
      elseif selected and visible and not l.isTilemap then
        local cel = l:cel(frame)
        if cel then
          local op = math.floor(255 * opacity * cel.opacity / 255 + 0.5)
          if op > 0 then drawCel(img, spr, cel, op, l.blendMode) end
        end
      end
    end
  end
  walk(spr.layers, nil, false, 1)
  return img
end

-- Only one layer's own cel, on a canvas-sized image (off-canvas pixels are cut off).
function L.celCanvas(spr, layer, frameNo)
  local img = Image(spr.width, spr.height, ColorMode.RGB)
  local cel = layer:cel(frameNo)
  if cel then drawCel(img, spr, cel, 255, BlendMode.NORMAL) end
  return img
end

-- ---------- colours ----------

function L.hex(p)
  local a = pc.rgbaA(p)
  if a == 255 then return string.format("%02x%02x%02x", pc.rgbaR(p), pc.rgbaG(p), pc.rgbaB(p)) end
  return string.format("%02x%02x%02x%02x", pc.rgbaR(p), pc.rgbaG(p), pc.rgbaB(p), a)
end

function L.parseHex(h)
  h = tostring(h):gsub("^#", "")
  if not (#h == 6 or #h == 8) or h:find("[^%x]") then error("bad colour '" .. tostring(h) .. "' (want #rrggbb or #rrggbbaa)") end
  local a = #h == 8 and tonumber(h:sub(7, 8), 16) or 255
  return pc.rgba(tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16), a)
end

function L.opaque(img, x, y)
  if x < 0 or y < 0 or x >= img.width or y >= img.height then return false end
  return pc.rgbaA(img:getPixel(x, y)) > 0
end

-- Bounding box of non-transparent pixels, or nil.
function L.bbox(img)
  local x0, y0, x1, y1
  for it in img:pixels() do
    if pc.rgbaA(it()) > 0 then
      local x, y = it.x, it.y
      if not x0 or x < x0 then x0 = x end
      if not x1 or x > x1 then x1 = x end
      if not y0 or y < y0 then y0 = y end
      if not y1 or y > y1 then y1 = y end
    end
  end
  if not x0 then return nil end
  return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

function L.tempPng(tag)
  return app.fs.joinPath(app.fs.tempPath,
    string.format("aseprite-live-%s-%d-%d.png", tag or "img", os.time(), math.random(1, 1e9)))
end

