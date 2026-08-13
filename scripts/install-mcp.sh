#!/usr/bin/env bash
#
# Prints the MCP config for Baton and checks the install.
#
# Usage:
#   scripts/install-mcp.sh            Print config snippets
#   scripts/install-mcp.sh --check    Verify the app and the CLI

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Baton.app"
MCP="$APP/Contents/MacOS/baton-mcp"

if [ ! -x "$MCP" ]; then
	echo "baton-mcp not found at $MCP" >&2
	echo "Run scripts/build-app.sh first." >&2
	exit 1
fi

if [ "${1:-}" = "--check" ]; then
	echo "==> Store"
	"$MCP" doctor
	echo
	echo "==> Handshake"
	printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
		'{"jsonrpc":"2.0","id":2,"method":"tools/list"}' |
		"$MCP" serve >/dev/null && echo "protocol ok"
	echo
	echo "==> App"
	if pgrep -x BatonApp >/dev/null; then
		echo "BatonApp is running"
	else
		echo "BatonApp is not running. Start it with: open $APP"
	fi
	exit 0
fi

cat <<EOF
Baton MCP server
================

Binary: $MCP

pi  (~/.pi/agent/settings.json, or a project .pi/settings.json)
---------------------------------------------------------------
{
  "mcpServers": {
    "baton": {
      "command": "$MCP",
      "args": ["serve"],
      "env": {
        "BATON_AGENT_NAME": "pi",
        "BATON_HARNESS": "pi"
      }
    }
  }
}

Claude Code  (~/.claude.json or .mcp.json)
------------------------------------------
{
  "mcpServers": {
    "baton": {
      "command": "$MCP",
      "args": ["serve"]
    }
  }
}

Codex / generic stdio client
---------------------------
command = "$MCP"
args    = ["serve"]

Environment
-----------
BATON_AGENT_NAME   Name on the card. Set one per agent so you can tell them apart.
BATON_SESSION_ID   Session id, when your harness does not pass one.
BATON_DB           Alternate database path. Useful for a test run.
BATON_NO_LAUNCH=1  Stop the CLI from launching the app.

Then add agents/AGENTS-snippet.md to your project AGENTS.md. Without that
instruction the agent will not use the tool.
EOF
