#!/usr/bin/env node
// Aseprite Live — MCP server half of the bridge.
//
// Claude Code starts this over stdio. We listen on ws://127.0.0.1:<port> (first free of
// 7317–7320, so several sessions can run side by side) and the Aseprite extension connects to
// us: its WebSocket can only be a client. Each tool call sends Lua to Aseprite, which runs it
// on the open sprite and replies with the result.
import { createServer } from "node:http";
import { readFileSync, rmSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer, WebSocket } from "ws";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const PORTS = [7317, 7318, 7319, 7320];
const TOKEN_DIR = join(homedir(), ".aseprite-live");
const LUA_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "lua");
const TIMEOUT_MS = 30_000;
const CONNECT_WAIT_MS = 5_000;

const log = (...a: unknown[]) => console.error("[aseprite-live]", ...a);

type Reply = { id: number; ok: boolean; result?: unknown; output?: string[]; error?: string };

let aseprite: WebSocket | null = null;
let asepriteVersion = "";
let nextId = 1;
const extensionLog: string[] = []; // recent {type:"log"} messages from the extension
const pending = new Map<number, { resolve: (r: Reply) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
const connectWaiters: (() => void)[] = [];

async function listen(): Promise<number> {
  for (const port of PORTS) {
    const http = createServer();
    const ok = await new Promise<boolean>((res) => {
      http.once("error", () => res(false));
      http.listen(port, "127.0.0.1", () => res(true));
    });
    if (!ok) continue;
    // Web pages always send an http(s):// (or "null") Origin; Aseprite's ixwebsocket sends
    // ws://127.0.0.1:<port> or none. Refusing the former keeps web pages out.
    const wss = new WebSocketServer({ server: http, verifyClient: (info: { origin?: string }) => !info.origin || info.origin.startsWith("ws://") });
    wss.on("connection", onConnection);
    return port;
  }
  throw new Error(`ports ${PORTS.join(", ")} are all in use (too many sessions running?)`);
}

function onConnection(ws: WebSocket) {
  ws.on("message", (data) => {
    let msg: any;
    try { msg = JSON.parse(data.toString()); } catch { return; }
    if (msg.type === "hello") {
      // Latest Aseprite to say hello wins (you normally only run one).
      aseprite = ws;
      asepriteVersion = msg.version ?? "";
      log("Aseprite connected", asepriteVersion);
      connectWaiters.splice(0).forEach((f) => f());
      return;
    }
    if (msg.type === "log") {
      log("extension:", msg.message);
      extensionLog.push(String(msg.message));
      extensionLog.splice(0, extensionLog.length - 5);
      return;
    }
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    clearTimeout(p.timer);
    p.resolve(msg as Reply);
  });
  ws.on("close", () => {
    if (aseprite !== ws) return;
    aseprite = null;
    log("Aseprite disconnected");
    for (const [id, p] of pending) {
      clearTimeout(p.timer);
      p.reject(new Error("Aseprite disconnected before replying (closed or crashed?)"));
      pending.delete(id);
    }
  });
}

async function connected(): Promise<WebSocket> {
  if (aseprite) return aseprite;
  // Right after startup the extension may still be in its reconnect wait (1–3 s).
  await new Promise<void>((res) => {
    const t = setTimeout(res, CONNECT_WAIT_MS);
    connectWaiters.push(() => { clearTimeout(t); res(); });
  });
  if (aseprite) return aseprite;
  throw new Error(
    "Aseprite isn't connected. Open Aseprite; if it is open, check Edit → Preferences → Extensions " +
      "has 'Aseprite Live' enabled (restart Aseprite after installing it).",
  );
}

function token(): string {
  try {
    chmodSync(TOKEN_DIR, 0o700);
    return readFileSync(join(TOKEN_DIR, "token"), "utf8").trim();
  } catch {
    throw new Error("No ~/.aseprite-live/token yet — the Aseprite extension creates it on start. Restart Aseprite.");
  }
}

async function runLua(code: string, undoable: boolean): Promise<Reply> {
  const ws = await connected();
  const tok = token();
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(
        `Aseprite didn't answer within ${TIMEOUT_MS / 1000}s. A modal dialog may be open in Aseprite ` +
          "(pass ui=false to app.command.*), or the script is stuck in a loop." +
          (extensionLog.length ? `\nRecent extension messages:\n${extensionLog.join("\n")}` : ""),
      ));
    }, TIMEOUT_MS);
    pending.set(id, { resolve, reject, timer });
    ws.send(JSON.stringify({ id, token: tok, code, undoable }));
  });
}

// Params go in as a Lua table literal, not through json.decode: Aseprite's json.decode gives
// userdata (no ipairs/#) and turns every number into a float.
function toLua(v: unknown): string {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") {
    if (!Number.isFinite(v)) throw new Error(`can't pass ${v} to Lua`);
    return Number.isInteger(v) ? String(v) : v.toString();
  }
  if (typeof v === "string") {
    let s = '"';
    for (const ch of v) {
      const c = ch.codePointAt(0)!;
      if (ch === "\\" || ch === '"') s += "\\" + ch;
      else if (ch === "\n") s += "\\n";
      else if (c < 32 || c === 127) s += "\\" + String(c).padStart(3, "0");
      else s += ch; // UTF-8 goes through as bytes, which is what Lua strings are
    }
    return s + '"';
  }
  if (Array.isArray(v)) return `{${v.map(toLua).join(",")}}`;
  if (typeof v === "object") {
    return `{${Object.entries(v as Record<string, unknown>)
      .filter(([, x]) => x !== undefined)
      .map(([k, x]) => `[${toLua(k)}]=${toLua(x)}`)
      .join(",")}}`;
  }
  throw new Error(`can't pass a ${typeof v} to Lua`);
}

// Run one of the bundled lua/*.lua snippets: shared helpers (L), then its params in P.
function snippet(name: string, params: object): string {
  const lib = readFileSync(join(LUA_DIR, "lib.lua"), "utf8");
  const src = readFileSync(join(LUA_DIR, `${name}.lua`), "utf8");
  return `local P = ${toLua(params)}\n${lib}\n${src}`;
}

// Runs a snippet and hands back its result object, or throws the Lua error.
async function call<T>(name: string, params: object, undoable = false): Promise<T> {
  const r = await runLua(snippet(name, params), undoable);
  if (!r.ok) throw new Error(`Lua error: ${r.error}` + (undoable ? "\n(the call was rolled back; nothing changed)" : ""));
  return r.result as T;
}

function pngContent(path: string) {
  const png = readFileSync(path);
  rmSync(path, { force: true });
  return { type: "image" as const, data: png.toString("base64"), mimeType: "image/png" };
}

const text = (t: string) => ({ type: "text" as const, text: t });
const fail = (e: unknown) => ({ content: [text(e instanceof Error ? e.message : String(e))], isError: true });

function formatReply(r: Reply, undoable: boolean) {
  const parts: string[] = [];
  if (r.output?.length) parts.push(`output:\n${r.output.join("\n")}`);
  if (r.ok) {
    parts.push(r.result === undefined ? "ok (no return value)" : `result: ${JSON.stringify(r.result, null, 1)}`);
    return { content: [text(parts.join("\n\n"))] };
  }
  parts.push(`Lua error: ${r.error}` + (undoable ? "\n(the call was rolled back; nothing changed)" : ""));
  return { content: [text(parts.join("\n\n"))], isError: true };
}

const INSTRUCTIONS = `
Drives the Aseprite editor the user has open, live: edits land in their sprite and undo history.

Workflow: aseprite_status first → change things → LOOK at the result. Always look after drawing;
don't trust coordinates you haven't seen.
- Look: aseprite_render (one frame) or aseprite_sheet (many frames / before-after rows / red
  highlight of one layer / onion skin). Review a whole tag with aseprite_sheet before calling it done.
- Read pixels: aseprite_pixels (char grid + legend). Write pixels: aseprite_draw_grid (same format,
  one undo step, per-frame offsets, clipping to the silhouette or under layers like hands).
- Follow motion: aseprite_track gives per-frame dx/dy of a layer or band; pass them as
  draw_grid offsets so a detail moves with the body. lowest L/R tells which foot is forward.
- Anything else: aseprite_run_lua.
Safety: pass sprite= whenever several sprites are open. Use show/hide/only to look at layers instead of
toggling isVisible, which changes the user's file. Put new details on their own layer.

Lua cheat sheet (Aseprite scripting API, https://www.aseprite.org/api):
- Active: app.sprite, app.layer, app.frame, app.cel (nil when the cel is empty), app.fgColor
- New sprite: Sprite(w, h) or Sprite(w, h, ColorMode.INDEXED); open: app.open(path)
- Colours: Color{r=,g=,b=,a=} ; raw pixel values: app.pixelColor.rgba(r,g,b,a) (RGB sprites) or a
  palette index (indexed sprites). A new sprite's palette may be all black: set it before
  converting to indexed (spr.palettes[1]:resize(n); :setColor(i, Color{...})).
- Drawing with tools (sprite coords, grows the cel, one undo step per call is fine):
  app.useTool{tool="pencil", color=Color{...}, brush=Brush(1), points={Point(x,y), ...}}
  tools: pencil, line, rectangle, filled_rectangle, ellipse, filled_ellipse, paint_bucket, eraser
- Bulk pixels (fast): build a full-canvas image and set it as the cel:
    local img = Image(spr.spec); img:drawPixel(x, y, px) ...
    local cel = layer:cel(frame); if cel then cel.image = img; cel.position = Point(0,0)
    else spr:newCel(layer, frame, img, Point(0,0)) end
  cel.image coords are RELATIVE to cel.position — read pixels with image:getPixel(x - pos.x, y - pos.y).
- Layers: spr:newLayer() (.name, .isVisible, .opacity); spr:newGroup(); spr:deleteLayer(l)
- Frames: spr:newFrame() (copies the previous), spr:newEmptyFrame(), frame.duration (seconds);
  tags: spr:newTag(from, to).name = "walk"
- Commands: app.command.X{...} — ALWAYS pass ui=false where supported, a modal dialog blocks the
  bridge. e.g. app.command.ChangePixelFormat{format="indexed"}, app.command.ExportSpriteSheet{ui=false,
  type=SpriteSheetType.HORIZONTAL, textureFilename="out.png", dataFilename="out.json"}
- Save: spr:saveAs(path) / spr:saveCopyAs(path) (.png/.gif export by extension)
- print(...) output and returned values (as JSON) come back to you.
`.trim();

const server = new McpServer({ name: "aseprite-live", version: "0.1.0" }, { instructions: INSTRUCTIONS });

server.registerTool(
  "aseprite_status",
  {
    description:
      "What's open in Aseprite: sprites, and for the active one its size, colour mode, layers (top to bottom), " +
      "frames, tags, palette, selection, active layer/frame and fg/bg colours. Call before editing.",
    inputSchema: {},
  },
  async () => {
    try {
      const r = await runLua(snippet("status", {}), false);
      return formatReply(r, false);
    } catch (e) { return fail(e); }
  },
);

server.registerTool(
  "aseprite_run_lua",
  {
    description:
      "Run Lua in the user's open Aseprite (full scripting API; see the server instructions for a cheat sheet). " +
      "`return` a value to get it back as JSON; print() output is returned too. By default the whole call is " +
      "one undo step named 'Claude' and a Lua error rolls it back.",
    inputSchema: {
      code: z.string().describe("Lua source. Runs on Aseprite's UI thread with app.sprite etc. available."),
      undoable: z.boolean().optional().describe(
        "Wrap in one transaction (default true). Set false for code that opens/creates/closes sprites or only reads.",
      ),
    },
  },
  async ({ code, undoable = true }) => {
    try {
      return formatReply(await runLua(code, undoable), undoable);
    } catch (e) { return fail(e); }
  },
);

// ---------- shared parameter shapes ----------
const spriteP = z.string().optional().describe(
  "Which open sprite: full path, file name, or file name without extension. Default: the active one. " +
    "Pass it whenever more than one sprite is open, so you never act on the wrong file.");
const layerPath = z.string().describe('Layer path like "Right/Strap", or a bare name if it is unique');
const frameSel = {
  frame: z.number().int().min(1).optional().describe("one 1-based frame"),
  frames: z.union([z.array(z.number().int().min(1)), z.string()]).optional()
    .describe('frame list, or a string like "10-18" / "2,4,6-8"'),
  tag: z.string().optional().describe("all frames of this tag"),
};
const visSel = {
  show: z.array(z.string()).optional().describe("layer/group paths to treat as visible for this call only"),
  hide: z.array(z.string()).optional().describe("layer/group paths to treat as hidden for this call only"),
  only: z.array(z.string()).optional().describe("draw only these layers/groups (and their children)"),
};
const VIS_NOTE = " show/hide/only never change the user's layer visibility; they apply to this call only.";

server.registerTool(
  "aseprite_render",
  {
    description:
      "Render one frame (all visible layers, or just one layer's cel) to a crisp upscaled PNG and return it as an " +
      "image so you can see it. Use after every edit; for several frames or before/after use aseprite_sheet." + VIS_NOTE,
    inputSchema: {
      sprite: spriteP,
      frame: z.number().int().min(1).optional().describe("1-based frame; default the active frame"),
      layer: z.string().optional().describe("render only this layer's cel (path or unique name), even if hidden"),
      ...visSel,
      scale: z.number().int().min(1).max(32).optional().describe("pixel scale; default fits ~512px"),
    },
  },
  async (params) => {
    try {
      const info = await call<{ path: string; width: number; height: number; scale: number; frame: number; frames: number; sprite: string }>(
        "render", params);
      return {
        content: [
          pngContent(info.path),
          text(`${info.sprite}: ${info.width}×${info.height}px, frame ${info.frame}/${info.frames}` +
            `${params.layer ? `, layer "${params.layer}"` : ""}, shown at ${info.scale}× (1 sprite pixel = ${info.scale}×${info.scale} image pixels)`),
        ],
      };
    } catch (e) { return fail(e); }
  },
);

server.registerTool(
  "aseprite_sheet",
  {
    description:
      "Contact sheet in one image: frames as columns, variant rows (e.g. before/after with a layer hidden/shown), " +
      "cropped to the content, zoomed, on a neutral background. Options: highlight (tint what one layer " +
      "contributes red), onion (faint previous + next frame behind each cell). Use it to review an animation or a " +
      "change across frames instead of many single renders." + VIS_NOTE,
    inputSchema: {
      sprite: spriteP,
      ...frameSel,
      ...visSel,
      highlight: z.string().optional().describe("layer/group path whose visible pixels are tinted red"),
      rows: z.array(z.object({
        label: z.string().optional(),
        show: z.array(z.string()).optional(),
        hide: z.array(z.string()).optional(),
        only: z.array(z.string()).optional(),
        highlight: z.string().optional(),
      })).optional().describe('one row per variant, e.g. [{label:"before",hide:["Down/Strap"]},{label:"after"}]; ' +
        "a row's show/hide/only/highlight replace the top-level ones"),
      crop: z.union([z.object({ x: z.number().int(), y: z.number().int(), w: z.number().int().min(1), h: z.number().int().min(1) }),
        z.literal("full")]).optional().describe('region in sprite pixels; default the tight box around all cells; "full" = whole canvas'),
      onion: z.boolean().optional().describe("draw the previous and next frame faintly behind each cell"),
      scale: z.number().int().min(1).max(32).optional().describe("default: fits ~1400×900"),
      bg: z.string().optional().describe("cell background #rrggbb (default #d6e2e6)"),
      gap: z.number().int().min(0).max(16).optional().describe("sprite pixels between cells (default 2)"),
    },
  },
  async (params) => {
    try {
      const info = await call<{ path: string; sprite: string; columns: number[]; rows: string[]; scale: number;
        crop: { x: number; y: number; w: number; h: number }; width: number; height: number }>("sheet", params);
      return {
        content: [
          pngContent(info.path),
          text(`${info.sprite}: columns = frames ${info.columns.join(", ")}; rows = ${info.rows.join(" | ")}; ` +
            `crop x${info.crop.x} y${info.crop.y} ${info.crop.w}×${info.crop.h} at ${info.scale}× (${info.width}×${info.height}px)`),
        ],
      };
    } catch (e) { return fail(e); }
  },
);

server.registerTool(
  "aseprite_pixels",
  {
    description:
      "Read pixels as a character grid with a colour legend (one char per colour, '.' = transparent), with x/y " +
      "coordinates. Reads the composite by default, or one layer's cel (even if hidden). Pass the legend from an " +
      "earlier read to keep the same characters. Pair with aseprite_draw_grid, which takes the same format." + VIS_NOTE,
    inputSchema: {
      sprite: spriteP,
      frame: z.number().int().min(1).optional().describe("1-based frame; default the active frame"),
      layer: z.string().optional().describe("read only this layer's cel (path or unique name)"),
      ...visSel,
      region: z.object({ x: z.number().int(), y: z.number().int(), w: z.number().int().min(1), h: z.number().int().min(1) })
        .optional().describe("default: the content box plus 1px"),
      legend: z.record(z.string(), z.string()).optional().describe('reuse chars, e.g. {"a":"#142638"}'),
    },
  },
  async (params) => {
    try {
      const r = await call<{ grid: string; legend: Record<string, string>; region: { x: number; y: number; w: number; h: number };
        frame: number; source: string; sprite: string }>("pixels", params);
      const legend = Object.entries(r.legend).sort(([a], [b]) => a.localeCompare(b)).map(([c, h]) => `${c}=${h}`).join(" ");
      return {
        content: [text(`${r.sprite} frame ${r.frame}, ${r.source}, region x${r.region.x} y${r.region.y} ${r.region.w}×${r.region.h}\n` +
          `${r.grid}\nlegend: ${legend}\nlegend json: ${JSON.stringify(r.legend)}`)],
      };
    } catch (e) { return fail(e); }
  },
);

server.registerTool(
  "aseprite_draw_grid",
  {
    description:
      "Stamp a character grid onto one layer, on one or more frames, as one undo step. rows[0] lands at (x, y). " +
      "'.' and ' ' leave pixels alone; a legend value of \"clear\" erases. offsets shift the stamp per frame (feed " +
      "them from aseprite_track to make a detail follow a moving part). clip.silhouette only draws where the rest " +
      "of the sprite is opaque; clip.under skips pixels covered by those layers (e.g. hands in front). Off-canvas " +
      "pixels already in the cel are kept. Render or sheet afterwards to check.",
    inputSchema: {
      sprite: spriteP,
      layer: layerPath,
      create: z.boolean().optional().describe('create the layer if missing ("Group/Name" puts it at the top of that group)'),
      ...frameSel,
      x: z.number().int(),
      y: z.number().int(),
      rows: z.array(z.string()).min(1),
      legend: z.record(z.string(), z.string()).describe('char → "#rrggbb", "#rrggbbaa" or "clear"'),
      mode: z.enum(["merge", "replace"]).optional().describe("replace clears the layer's cel on those frames first (default merge)"),
      offsets: z.record(z.string(), z.tuple([z.number().int(), z.number().int()])).optional()
        .describe('per-frame shift, e.g. {"11":[1,1],"12":[1,2]}'),
      clip: z.object({
        silhouette: z.boolean().optional(),
        under: z.array(z.string()).optional(),
      }).optional(),
    },
  },
  async (params) => {
    try {
      const r = await call<{ sprite: string; layer: string; frames: { frame: number; drawn: number; clipped: number; cleared: number; offset: number[] }[] }>(
        "draw_grid", params, true);
      const lines = r.frames.map((f) =>
        `frame ${f.frame}: drew ${f.drawn}` + (f.clipped ? `, clipped ${f.clipped}` : "") + (f.cleared ? `, cleared ${f.cleared}` : "") +
        (f.offset[0] || f.offset[1] ? ` (offset ${f.offset[0]},${f.offset[1]})` : ""));
      return { content: [text(`${r.sprite} → ${r.layer} (one undo step)\n${lines.join("\n")}`)] };
    } catch (e) { return fail(e); }
  },
);

server.registerTool(
  "aseprite_track",
  {
    description:
      "Measure motion: for each frame, the whole-pixel shift (dx, dy) that best maps a reference frame's pixels " +
      "(of one layer, a group, or the composite) onto that frame, with a 0–1 match score, the content box, and " +
      "the lowest opaque row in the left/right half of the box (front/back views: the lower foot is the forward " +
      "one). Use rows to track just a band (e.g. the head). Feed dx/dy into aseprite_draw_grid offsets." + VIS_NOTE,
    inputSchema: {
      sprite: spriteP,
      layer: z.string().optional().describe("track this layer or group; default the composite"),
      ...visSel,
      ref: z.number().int().min(1).optional().describe("reference frame (default: first of the selection)"),
      ...frameSel,
      rows: z.tuple([z.number().int(), z.number().int()]).optional().describe("only match rows y0..y1 of the reference"),
      maxShift: z.number().int().min(0).max(16).optional().describe("search radius in pixels (default 3)"),
    },
  },
  async (params) => {
    try {
      const r = await call<{ sprite: string; source: string; ref: number; rows: number[];
        frames: { frame: number; dx: number; dy: number; match: number; box?: { x: number; y: number; w: number; h: number };
          lowestLeft?: number; lowestRight?: number }[] }>("track", params);
      const lines = r.frames.map((f) =>
        `frame ${f.frame}: dx ${f.dx} dy ${f.dy} match ${f.match}` +
        (f.box ? ` | box x${f.box.x} y${f.box.y} ${f.box.w}×${f.box.h}` : " | empty") +
        (f.lowestLeft !== undefined || f.lowestRight !== undefined ? ` | lowest L ${f.lowestLeft ?? "-"} R ${f.lowestRight ?? "-"}` : ""));
      const offsets = Object.fromEntries(r.frames.map((f) => [String(f.frame), [f.dx, f.dy]]));
      return {
        content: [text(`${r.sprite}, ${r.source}, ref frame ${r.ref}, rows ${r.rows[0]}–${r.rows[1]}\n${lines.join("\n")}\n` +
          `offsets for aseprite_draw_grid: ${JSON.stringify(offsets)}`)],
      };
    } catch (e) { return fail(e); }
  },
);

const port = await listen();
log(`listening on ws://127.0.0.1:${port}`);
await server.connect(new StdioServerTransport());
