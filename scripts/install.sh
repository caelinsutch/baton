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
BEGIN_MARKER="<!-- baton:begin -->"
END_MARKER="<!-- baton:end -->"

# --- Uninstall ----------------------------------------------------------------

if [ "${1:-}" = "--uninstall" ]; then
	echo "==> Removing the login item"
	launchctl bootout "gui/$(id -u)/dev.baton.Baton" 2>/dev/null || true
	rm -f "$AGENT_PLIST"

	echo "==> Quitting and removing the app"
	pkill -x BatonApp 2>/dev/null || true
	rm -rf "$INSTALLED_APP"

	echo "==> Unregistering from pi"
	if [ -f "$PI_MCP" ]; then
		python3 - "$PI_MCP" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    config = json.load(handle)
if config.get("mcpServers", {}).pop("baton", None) is not None:
    with open(path, "w") as handle:
        json.dump(config, handle, indent=2)
    print("    removed from mcp.json")
PY
	fi

	echo "==> Removing the agent instructions"
	if [ -f "$PI_AGENTS" ]; then
		python3 - "$PI_AGENTS" "$BEGIN_MARKER" "$END_MARKER" <<'PY'
import sys

path, begin, end = sys.argv[1:4]
with open(path) as handle:
    text = handle.read()
if begin in text and end in text:
    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    with open(path, "w") as handle:
        handle.write((head.rstrip() + "\n" + tail.lstrip()).strip() + "\n")
    print("    removed from AGENTS.md")
PY
	fi

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

# --- Register with pi ---------------------------------------------------------

echo "==> Registering with pi"
# `~/.pi/agent/mcp.json` is the file pi-mcp-adapter reads. Not settings.json.
mkdir -p "$(dirname "$PI_MCP")"
[ -f "$PI_MCP" ] || printf '{\n  "mcpServers": {}\n}\n' >"$PI_MCP"
python3 - "$PI_MCP" "$MCP_BINARY" <<'PY'
import json
import sys

path, binary = sys.argv[1:3]
with open(path) as handle:
    config = json.load(handle)
servers = config.setdefault("mcpServers", {})
before = servers.get("baton")
servers["baton"] = {"command": binary, "args": ["serve"]}
if before == servers["baton"]:
    print("    already registered")
else:
    with open(path, "w") as handle:
        json.dump(config, handle, indent=2)
    print(f"    baton -> {binary}")
PY

# --- Tell agents the tool exists ----------------------------------------------

echo "==> Installing the agent instructions"
# Deliberately short. This goes into every prompt, so it states when to reach for
# the tool and leaves the detail to the file it points at.
read -r -d '' BLOCK <<BLOCK_EOF || true
$BEGIN_MARKER
## Asking the human (Baton)

You can reach the human who runs you through the \`baton\` MCP server. In pi, call
it with the \`mcp\` gateway: \`mcp({ server: "baton", tool: "ask_human", args: {...} })\`.

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

mkdir -p "$(dirname "$PI_AGENTS")"
touch "$PI_AGENTS"
python3 - "$PI_AGENTS" "$BEGIN_MARKER" "$END_MARKER" "$BLOCK" <<'PY'
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
    updated = text.rstrip() + "\n\n" + block + "\n"
    action = "added"

if updated != text:
    with open(path, "w") as handle:
        handle.write(updated)
    print(f"    {action} the Baton section")
else:
    print("    already up to date")
PY

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

  app        $INSTALLED_APP
  login item $AGENT_PLIST
  pi config  $PI_MCP
  prompt     $PI_AGENTS

Next, once: run scripts/check-notifications.sh and turn Baton on in
System Settings > Notifications if it reports denied.

Undo all of this with: scripts/install.sh --uninstall
EOF
