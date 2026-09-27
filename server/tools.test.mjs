// End-to-end tests for sheet / pixels / draw_grid / track against the running Aseprite.
//   node tools.test.mjs      (builds nothing; run `npm run build` first)
// Works on a scratch sprite "aseprite-live-test" and closes it at the end.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { writeFileSync } from "node:fs";

const c = new Client({ name: "tools-test", version: "0" });
await c.connect(new StdioClientTransport({ command: "node", args: [new URL("dist/index.js", import.meta.url).pathname], stderr: "inherit" }));

let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "✓" : "✗"} ${name}${detail ? "  " + detail : ""}`);
  if (!ok) failures++;
};
const tool = async (name, args = {}) => {
  const r = await c.callTool({ name, arguments: args });
  const t = r.content.find((x) => x.type === "text")?.text ?? "";
  const img = r.content.find((x) => x.type === "image");
  return { err: !!r.isError, text: t, img };
};
const lua = (code, undoable = false) => tool("aseprite_run_lua", { code, undoable });
const S = "aseprite-live-test";

// Scratch sprite: group G with Body (a 4×4 block moving right 1px per frame) and Hand (fixed 2×2
// in front), plus a hidden layer. 3 frames.
let r = await lua(`
  local s = Sprite(16, 16); s.filename = "${S}"
  s:newFrame(); s:newFrame()
  local g = s:newGroup(); g.name = "G"
  local body = s.layers[1]; body.name = "Body"; body.parent = g
  local hand = s:newLayer(); hand.name = "Hand"; hand.parent = g
  local hidden = s:newLayer(); hidden.name = "Hidden"; hidden.isVisible = false
  local pc = app.pixelColor
  for f = 1, 3 do
    local im = Image(16, 16, ColorMode.RGB)
    for y = 6, 9 do for x = 2 + f, 5 + f do im:drawPixel(x, y, pc.rgba(40, 60, 120, 255)) end end
    local c = body:cel(f); if c then c.image = im; c.position = Point(0, 0) else s:newCel(body, s.frames[f], im, Point(0, 0)) end
    local h = Image(16, 16, ColorMode.RGB)
    h:drawPixel(6, 8, pc.rgba(230, 180, 150, 255)); h:drawPixel(7, 8, pc.rgba(230, 180, 150, 255))
    s:newCel(hand, s.frames[f], h, Point(0, 0))
    local z = Image(16, 16, ColorMode.RGB); z:drawPixel(0, 0, pc.rgba(255, 0, 0, 255))
    s:newCel(hidden, s.frames[f], z, Point(0, 0))
  end
  s:newTag(1, 3).name = "Move"
  return true`);
check("create scratch sprite", !r.err, r.err ? r.text : "");

// render: sprite targeting + show override leaves visibility alone
r = await tool("aseprite_render", { sprite: S, frame: 2, show: ["Hidden"] });
check("render with sprite + show", !r.err && !!r.img, r.text.slice(0, 120));
r = await lua(`for _, s in ipairs(app.sprites) do if s.filename == "${S}" then for _, l in ipairs(s.layers) do if l.name == "Hidden" then return l.isVisible end end end end`);
check("show override did not unhide the layer", r.text.includes("false"), r.text);

r = await tool("aseprite_render", { sprite: "definitely-not-open" });
check("unknown sprite is an error", r.err && r.text.includes("no open sprite matches"), r.text.slice(0, 120));

// pixels
r = await tool("aseprite_pixels", { sprite: S, frame: 1 });
check("pixels reads a grid", !r.err && /\n\s+6 \.+/.test(r.text) || r.text.includes("legend:"), r.text.split("\n").slice(0, 6).join(" / "));
const legendJson = JSON.parse(r.text.match(/legend json: (.*)$/m)[1]);
check("pixels legend has body + hand colours", Object.keys(legendJson).length === 2, JSON.stringify(legendJson));

r = await tool("aseprite_pixels", { sprite: S, frame: 1, layer: "Hidden", region: { x: 0, y: 0, w: 3, h: 2 } });
check("pixels of a hidden layer", !r.err && r.text.includes("#ff0000"), r.text.replace(/\n/g, " / ").slice(0, 160));

// track: Body moves +1 x per frame
r = await tool("aseprite_track", { sprite: S, layer: "G/Body", tag: "Move" });
const dxs = [...r.text.matchAll(/frame (\d+): dx (-?\d+) dy (-?\d+)/g)].map((m) => [+m[1], +m[2], +m[3]]);
check("track finds dx 0,1,2", JSON.stringify(dxs) === JSON.stringify([[1, 0, 0], [2, 1, 0], [3, 2, 0]]), JSON.stringify(dxs));
const offsets = JSON.parse(r.text.match(/offsets for aseprite_draw_grid: (.*)$/m)[1]);

// draw_grid: a 2px stripe on a new layer, following Body, clipped to the silhouette and under Hand
r = await tool("aseprite_draw_grid", {
  sprite: S, layer: "G/Stripe", create: true, tag: "Move", x: 3, y: 8, rows: ["abab"],
  legend: { a: "#ffcc00", b: "#aa6600" }, offsets, clip: { silhouette: true, under: ["G/Hand"] },
});
check("draw_grid creates layer and stamps 3 frames", !r.err && (r.text.match(/frame \d+: drew/g) ?? []).length === 3, r.text.replace(/\n/g, " / "));
// frame 1: stripe x3..6 at y8; hand covers x6,7 → one pixel clipped
check("draw_grid clips under Hand", /frame 1: drew 3, clipped 1/.test(r.text), (r.text.match(/frame 1:[^\n]*/) ?? [""])[0]);

// round trip: read Stripe frame 3, stamp it on another layer, read that back
r = await tool("aseprite_pixels", { sprite: S, frame: 3, layer: "G/Stripe", region: { x: 0, y: 0, w: 16, h: 16 } });
const grid3 = r.text.split("\n").slice(3, 19).map((l) => l.slice(4));
const leg3 = JSON.parse(r.text.match(/legend json: (.*)$/m)[1]);
await tool("aseprite_draw_grid", { sprite: S, layer: "Copy", create: true, frame: 3, x: 0, y: 0, rows: grid3, legend: leg3 });
r = await tool("aseprite_pixels", { sprite: S, frame: 3, layer: "Copy", region: { x: 0, y: 0, w: 16, h: 16 }, legend: leg3 });
const back = r.text.split("\n").slice(3, 19).map((l) => l.slice(4));
check("pixels → draw_grid → pixels round trip", JSON.stringify(back) === JSON.stringify(grid3));

// draw_grid error rolls back
r = await tool("aseprite_draw_grid", { sprite: S, layer: "G/Stripe", frame: 1, x: 0, y: 0, rows: ["az"], legend: { a: "#ffffff" } });
check("unknown legend char is an error and rolls back", r.err && r.text.includes("not in the legend") && r.text.includes("rolled back"), r.text.slice(0, 120));

// sheet: before/after rows + highlight + onion
r = await tool("aseprite_sheet", {
  sprite: S, tag: "Move", onion: true,
  rows: [{ label: "without stripe", hide: ["G/Stripe"] }, { label: "with stripe" }, { label: "stripe highlighted", highlight: "G/Stripe" }],
});
check("sheet returns one image with 3 rows × 3 columns", !r.err && !!r.img && r.text.includes("frames 1, 2, 3") && r.text.includes("stripe highlighted"), r.text);
if (r.img) writeFileSync("tools-test-sheet.png", Buffer.from(r.img.data, "base64"));

r = await lua(`for _, s in ipairs(app.sprites) do if s.filename == "${S}" then s:close() end end return true`);
check("close scratch sprite", !r.err);
await c.close();
console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
