#!/usr/bin/env bash
#
# Diagnoses notification delivery, and posts a test notification.
#
# The failure this catches is specific and confusing: macOS returns
# "Notifications are not allowed for this application" from requestAuthorization
# when the app is switched off in System Settings. It does not prompt, and it does
# not fail when posting, so a task quietly produces no banner.
#
# Usage:
#   scripts/check-notifications.sh              Check, then turn tracing back off
#   scripts/check-notifications.sh --keep-trace Leave tracing on for more digging

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Baton.app"
MCP="$APP/Contents/MacOS/baton-mcp"
SUPPORT="$HOME/Library/Application Support/dev.baton"
LOG="$SUPPORT/app.log"
MARKER="$SUPPORT/DEBUG"
KEEP_TRACE=0
[ "${1:-}" = "--keep-trace" ] && KEEP_TRACE=1

# Tracing writes to a file that grows, so turn it off again on the way out unless
# the caller asked to keep it.
cleanup() {
	if [ "$KEEP_TRACE" = "0" ]; then
		rm -f "$MARKER"
	fi
}
trap cleanup EXIT

if [ ! -d "$APP" ]; then
	echo "Baton.app not found. Run scripts/build-app.sh first." >&2
	exit 1
fi

echo "==> Restarting Baton with tracing on"
mkdir -p "$SUPPORT"
# The marker file turns tracing on for a LaunchServices start, where there is no
# way to pass an environment variable.
touch "$MARKER"
rm -f "$LOG"
pkill -x BatonApp 2>/dev/null || true
sleep 1
open "$APP"
sleep 5

if [ ! -f "$LOG" ]; then
	echo "No log at $LOG. The app may not have started." >&2
	exit 1
fi

STATUS="$(grep -o 'authorization=[0-9]*' "$LOG" | head -1 | cut -d= -f2 || true)"
ALERT="$(grep -o 'alert=[0-9]*' "$LOG" | head -1 | cut -d= -f2 || true)"
STYLE="$(grep -o 'style=[0-9]*' "$LOG" | head -1 | cut -d= -f2 || true)"

echo
case "${STATUS:-}" in
0)
	echo "Status: not determined. macOS should prompt on the next launch."
	;;
2 | 3 | 4)
	echo "Status: authorized."
	;;
1)
	cat <<'EOF'
Status: DENIED. This is the common case, and it is not obvious.

Fix it:
  1. Open System Settings > Notifications
  2. Find Baton under Application Notifications
  3. Turn "Allow notifications" on

Then run this script again.

Opening that pane now...
EOF
	open "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
	exit 1
	;;
*)
	echo "Could not read the authorization status. Log follows:" >&2
	cat "$LOG" >&2
	exit 1
	;;
esac

[ "${ALERT:-2}" = "2" ] || echo "Note: alerts are switched off, so nothing will appear on screen."
if [ "${STYLE:-1}" = "1" ]; then
	echo "Note: style is Banners, so the action buttons only appear on hover."
	echo "      Choose Alerts in System Settings to keep them visible."
fi

echo
echo "==> Posting a test notification"
"$MCP" submit "Notification test" \
	--worktree "$ROOT" \
	--priority high \
	--body "If you can read this, delivery works. Approve or dismiss it." >/dev/null
sleep 2

POST="$(grep 'post ' "$LOG" | tail -1 || true)"
echo "    $POST"
case "$POST" in
*"error=none"*)
	echo
	echo "Posted with no error. A banner should be in the top right corner."
	echo "Clear the test task with: $MCP list"
	if [ "$KEEP_TRACE" = "1" ]; then
		echo "Tracing stays on. Turn it off with: rm '$MARKER'"
	fi
	;;
*)
	echo "The post failed. See $LOG" >&2
	exit 1
	;;
esac
