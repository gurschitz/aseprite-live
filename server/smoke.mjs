// End-to-end check against the real, running Aseprite: node smoke.mjs
// Creates a scratch 16×16 sprite, draws on it, renders it to smoke.png, then closes it.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { writeFileSync } from "node:fs";

const c = new Client({ name: "smoke", version: "0" });
await c.connect(new StdioClientTransport({ command: "node", args: [new URL("dist/index.js", import.meta.url).pathname], stderr: "inherit" }));
const call = async (name, args = {}) => {
  const r = await c.callTool({ name, arguments: args });
  const t = r.content.find((x) => x.type === "text")?.text ?? "";
  console.log(`${r.isError ? "✗" : "✓"} ${name}: ${t.slice(0, 300).replace(/\n\s*/g, " ")}`);
  return r;
};
await call("aseprite_status");
await call("aseprite_run_lua", { undoable: false, code: `local s = Sprite(16, 16); s.filename = "aseprite-live-smoke"; return s.width` });
await call("aseprite_run_lua", { code: `
  app.useTool{ tool="filled_ellipse", color=Color{r=240,g=180,b=40}, points={Point(2,2), Point(13,13)} }
  app.useTool{ tool="pencil", color=Color{r=40,g=40,b=60}, points={Point(6,6)} }
  app.useTool{ tool="pencil", color=Color{r=40,g=40,b=60}, points={Point(9,6)} }
  app.useTool{ tool="line", color=Color{r=40,g=40,b=60}, points={Point(5,10), Point(10,10)} }
  print("drew a face") return true` });
console.log("  (next call should fail and roll back)");
await call("aseprite_run_lua", { code: `error("rollback test")` });
const r = await call("aseprite_render");
const img = r.content.find((x) => x.type === "image");
if (img) { writeFileSync("smoke.png", Buffer.from(img.data, "base64")); console.log("  wrote smoke.png"); }
await call("aseprite_run_lua", { undoable: false, code: `for _, s in ipairs(app.sprites) do if s.filename == "aseprite-live-smoke" then s:close() end end` });
await c.close();
