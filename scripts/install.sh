#!/usr/bin/env bash
#
# Installs Baton so it keeps working: a stable app location, a login item, an MCP
# registration that does not point at build output, and a prompt that tells agents
# the tool exists.
#
# Usage:
#   scripts/install.sh              Install everything
#   scripts/install.sh --uninstall  Undo it
#
# Idempotent. Running it twice changes nothing the second time.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED_APP="/Applications/Baton.app"
MCP_BINARY="$INSTALLED_APP/Contents/MacOS/baton-mcp"
AGENT_PLIST="$HOME/Library/LaunchAgents/dev.baton.Baton.plist"
PI_MCP="$HOME/.pi/agent/mcp.json"
PI_AGENTS="$HOME/.pi/agent/AGENTS.md"
# Claude Code keeps user-scope MCP servers in ~/.claude.json, alongside unrelated
# state, so it gets read-modify-written rather than templated. Its always-on
# prompt is ~/.claude/CLAUDE.md.
CLAUDE_MCP="$HOME/.claude.json"
CLAUDE_AGENTS="$HOME/.claude/CLAUDE.md"
BEGIN_MARKER="<!-- baton:begin -->"
END_MARKER="<!-- baton:end -->"

# --- Helpers ------------------------------------------------------------------

# Add or refresh the baton entry under .mcpServers in a JSON config, leaving
# every other key in the file untouched. That matters most for ~/.claude.json,
# which also holds unrelated Claude Code state.
#
# $3 is "stdio" to write the explicit type and env that Claude Code's own `claude
# mcp add` produces, or "bare" for the minimal command/args pair pi uses. Writing
# the same shape the harness writes keeps the run idempotent.
register_mcp() {
	local path="$1" binary="$2" shape="${3:-bare}"
	mkdir -p "$(dirname "$path")"
	[ -f "$path" ] || printf '{\n  "mcpServers": {}\n}\n' >"$path"
	python3 - "$path" "$binary" "$shape" <<'PY'
import json
import sys

path, binary, shape = sys.argv[1:4]
with open(path) as handle:
    config = json.load(handle)
servers = config.setdefault("mcpServers", {})
before = servers.get("baton")
entry = {"command": binary, "args": ["serve"]}
if shape == "stdio":
    entry = {"type": "stdio", **entry, "env": {}}
if before == entry:
    print("    already registered")
else:
    servers["baton"] = entry
    with open(path, "w") as handle:
        json.dump(config, handle, indent=2)
    print(f"    baton -> {binary}")
PY
}

unregister_mcp() {
	local path="$1"
	[ -f "$path" ] || return 0
	python3 - "$path" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    config = json.load(handle)
if config.get("mcpServers", {}).pop("baton", None) is not None:
    with open(path, "w") as handle:
        json.dump(config, handle, indent=2)
    print(f"    removed from {path}")
PY
}

# Replace the block between the markers, or append it. Never touches anything
# the human wrote outside the markers.
write_prompt_block() {
	local path="$1" block="$2"
	mkdir -p "$(dirname "$path")"
	touch "$path"
	python3 - "$path" "$BEGIN_MARKER" "$END_MARKER" "$block" <<'PY'
import sys

path, begin, end, block = sys.argv[1:5]
with open(path) as handle:
    text = handle.read()

if begin in text and end in text:
    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    updated = head + block + tail
    action = "updated"
else:
    updated = (text.rstrip() + "\n\n" + block + "\n").lstrip()
    action = "added"

if updated != text:
    with open(path, "w") as handle:
        handle.write(updated)
    print(f"    {action} the Baton section")
else:
    print("    already up to date")
PY
}

remove_prompt_block() {
	local path="$1"
	[ -f "$path" ] || return 0
	python3 - "$path" "$BEGIN_MARKER" "$END_MARKER" <<'PY'
import sys

path, begin, end = sys.argv[1:4]
with open(path) as handle:
    text = handle.read()
if begin in text and end in text:
    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    with open(path, "w") as handle:
        handle.write((head.rstrip() + "\n" + tail.lstrip()).strip() + "\n")
    print(f"    removed from {path}")
PY
}

# --- Uninstall ----------------------------------------------------------------

if [ "${1:-}" = "--uninstall" ]; then
	echo "==> Removing the login item"
	launchctl bootout "gui/$(id -u)/dev.baton.Baton" 2>/dev/null || true
	rm -f "$AGENT_PLIST"

	echo "==> Quitting and removing the app"
	pkill -x BatonApp 2>/dev/null || true
	rm -rf "$INSTALLED_APP"

	echo "==> Unregistering from pi and Claude Code"
	unregister_mcp "$PI_MCP"
	unregister_mcp "$CLAUDE_MCP"

	echo "==> Removing the agent instructions"
	remove_prompt_block "$PI_AGENTS"
	remove_prompt_block "$CLAUDE_AGENTS"

	echo
	echo "Done. Your tasks database and settings were left alone:"
	echo "  ~/Library/Application Support/dev.baton"
	exit 0
fi

# --- Build and install --------------------------------------------------------

echo "==> Building"
"$ROOT/scripts/build-app.sh" release >/dev/null

echo "==> Installing to $INSTALLED_APP"
# Quit first, or the copy lands under a running binary.
pkill -x BatonApp 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED_APP"
cp -R "$ROOT/dist/Baton.app" "$INSTALLED_APP"

# Register the bundle, so `open -b dev.baton.Baton` resolves to this copy. The MCP
# server uses that to start the app when a task arrives and nothing is running.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
	-f "$INSTALLED_APP" 2>/dev/null || true

echo "==> Adding a login item"
cat >"$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.baton.Baton</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INSTALLED_APP/Contents/MacOS/BatonApp</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<!-- Do not restart it if you quit deliberately. -->
	<key>KeepAlive</key>
	<false/>
	<!-- A menu bar app only makes sense in a graphical session. -->
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/dev.baton.Baton" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
# RunAtLoad covers login, but it does not fire on a manual bootstrap, so start it
# now as well. Otherwise installing appears to do nothing until you reboot.
launchctl kickstart "gui/$(id -u)/dev.baton.Baton" 2>/dev/null || true

# --- Register with the agents -------------------------------------------------

echo "==> Registering with pi"
# `~/.pi/agent/mcp.json` is the file pi-mcp-adapter reads. Not settings.json.
register_mcp "$PI_MCP" "$MCP_BINARY"

echo "==> Registering with Claude Code"
# User scope, so every project and every Conductor worktree sees it. Claude Code
# reads MCP servers once at session start: existing sessions need a restart.
register_mcp "$CLAUDE_MCP" "$MCP_BINARY" stdio

# --- Tell agents the tool exists ----------------------------------------------

# Deliberately short. This goes into every prompt, so it states when to reach for
# the tool and leaves the detail to the file it points at. $1 is the harness's
# own line about how to call the tools, which differs between them.
make_block() {
	read -r -d '' BLOCK <<BLOCK_EOF || true
$BEGIN_MARKER
## Asking the human (Baton)

You can reach the human who runs you through the \`baton\` MCP server. $1

Ask when a person is genuinely needed:

- A change is destructive or hard to undo.
- Two paths are equally valid and the choice is taste, policy, or product.
- A result needs human eyes, such as a rendered page or an animation.
- You finished work in a worktree and want a review before you commit.

Do not ask for anything you can settle by reading the code or running the tests.

**Use the tool rather than asking in your reply.** If you were about to stop and
put a question in your output, submit a Baton task instead. Nobody is necessarily
watching the terminal you are writing to, and an unseen question stalls the work.
A Baton task notifies the human wherever they are and comes back to you as a
structured answer. Only ask in plain text when you already know they are reading,
such as an interactive back-and-forth you are already having.

Use \`ask_human\` when you can wait, and \`submit_task\` when you are about to end
your turn. Always pass \`worktree\`, because several agents run at once and the
human cannot otherwise tell whose task it is. Pass a \`checklist\` for anything
visual: a failed item comes back to you by name.

\`status: "pending"\` after a wait is not a failure. The task is still open, so call
\`await_task\` again or check later with \`get_task\`. Never submit it twice.

Full guidance: $ROOT/agents/AGENTS-snippet.md
$END_MARKER
BLOCK_EOF
}

echo "==> Installing the agent instructions for pi"
# Single-quoted, and with plain backticks: this is substituted into the heredoc
# verbatim, so backslash escapes would survive as backslashes. The backticks are
# literal markdown, so no expansion is wanted here.
# shellcheck disable=SC2016
make_block 'In pi, call it with the
`mcp` gateway: `mcp({ server: "baton", tool: "ask_human", args: {...} })`.'
write_prompt_block "$PI_AGENTS" "$BLOCK"

echo "==> Installing the agent instructions for Claude Code"
# shellcheck disable=SC2016
make_block 'Claude Code exposes the tools
directly, prefixed: `mcp__baton__ask_human`, `mcp__baton__submit_task`, and so on.'
write_prompt_block "$CLAUDE_AGENTS" "$BLOCK"

# --- Report -------------------------------------------------------------------

sleep 3
echo
echo "==> Checking"
"$MCP_BINARY" doctor | sed 's/^/    /'
if pgrep -x BatonApp >/dev/null; then
	echo "    app         running"
else
	echo "    app         NOT running" >&2
fi

cat <<EOF

Installed.

  app           $INSTALLED_APP
  login item    $AGENT_PLIST
  pi config     $PI_MCP
  pi prompt     $PI_AGENTS
  claude config $CLAUDE_MCP
  claude prompt $CLAUDE_AGENTS

Claude Code reads its MCP servers at session start, so restart any session that
is already open before the tools show up.

Next, once: run scripts/check-notifications.sh and turn Baton on in
System Settings > Notifications if it reports denied.

Undo all of this with: scripts/install.sh --uninstall
EOF
