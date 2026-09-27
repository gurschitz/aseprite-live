#!/bin/sh
# Installs Aseprite Live for this user: builds the MCP server, copies the extension into
# Aseprite (Aseprite ignores symlinked extension folders, so re-run this after editing it,
# then restart Aseprite) and registers the
# server with Claude Code at user scope.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
EXT_DIR="$HOME/Library/Application Support/Aseprite/extensions"

(cd "$DIR/server" && npm install --silent && npm run -s build && chmod +x dist/index.js)

mkdir -p "$EXT_DIR"
rm -rf "$EXT_DIR/aseprite-live"
cp -R "$DIR/extension" "$EXT_DIR/aseprite-live"
echo "Copied extension → $EXT_DIR/aseprite-live"

if command -v claude >/dev/null; then
  claude mcp remove --scope user aseprite-live >/dev/null 2>&1 || true
  claude mcp add --scope user aseprite-live -- node "$DIR/server/dist/index.js"
fi

echo "Done. Restart Aseprite, then restart Claude Code (or /mcp) to pick up the tools."
