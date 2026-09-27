# Aseprite Live

Lets Claude Code drive the Aseprite you have open. Edits land in your sprite and your undo
history; each tool call is one ⌘Z.

```
Claude Code ──stdio──► MCP server (server/, Node)  ◄──WebSocket── Aseprite extension (extension/, Lua)
                         listens on 127.0.0.1:7317–7320            connects to every port, runs the Lua it gets
```

Aseprite's scripting `WebSocket` is client-only, so the MCP server listens and the extension
connects. Each Claude Code session gets its own port (up to 4 at once).

## Install

```sh
./install.sh        # builds server, copies extension into Aseprite (re-run after editing it), `claude mcp add --scope user`
```

Then restart Aseprite and Claude Code.

## Tools

| Tool | Does |
|---|---|
| `aseprite_status` | open sprites; active sprite's size, mode, layers, frames, tags, palette, selection |
| `aseprite_run_lua` | run any Lua against the open sprite; returns the return value (JSON) + `print` output. One undo step, rolled back on error |
| `aseprite_render` | one frame or one layer's cel → crisp upscaled PNG, returned as an image |
| `aseprite_sheet` | frames × variant rows in one image (before/after, red highlight of one layer, onion skin), cropped to the content |
| `aseprite_pixels` | a region as a character grid + colour legend (composite, or one layer's cel even if hidden) |
| `aseprite_draw_grid` | stamp a character grid onto a layer across frames: per-frame offsets, clip to the silhouette or under layers (hands), one undo step |
| `aseprite_track` | per-frame dx/dy of a layer, group or band vs a reference frame, plus content box and lowest pixel per half (which foot is forward) |

All tools take `sprite` (path, file name, or name without extension) so they never act on the wrong
open file, and frame selection by `frame`, `frames` (`[1,2]` or `"10-18"`) or `tag`. `show` / `hide` /
`only` switch layers on or off for that call only; the user's layer visibility is never touched.

The server's MCP `instructions` carry a Lua cheat sheet and the workflow (look → read → draw →
track), so Claude knows the API patterns and pitfalls (cel-relative coordinates, `ui=false` on
commands).

## Security

Requests must carry the token from `~/.aseprite-live/token` (created by the extension, dir is
chmod 700). The server refuses WebSocket clients with a browser `Origin` (http, https, null), so web pages
can't pose as Aseprite. The extension does nothing in `aseprite -b` runs.

## Check it works

```sh
cd server && node smoke.mjs        # draws a face in a scratch sprite, writes smoke.png
cd server && node tools.test.mjs   # sheet / pixels / draw_grid / track on a scratch sprite
```

## Files

- `extension/aseprite-live.lua`: socket handling, token check, runs code in a transaction
- `server/src/index.ts`: MCP tools, WebSocket server, request/reply matching
- `server/lua/lib.lua`: shared helpers prepended to every snippet (sprite/layer/frame lookup, compositing with visibility overrides)
- `server/lua/*.lua`: one snippet per tool. Params arrive as a Lua table literal in `P` (not `json.decode`, which gives userdata and floats)
