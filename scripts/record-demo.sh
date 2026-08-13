#!/usr/bin/env bash
#
# Records the Baton flow with the real pi interface: you type a request, the agent
# works, the notch asks you to review, you approve, the agent finishes.
#
# Usage:
#   scripts/record-demo.sh              Run in the foreground
#   scripts/record-demo.sh --detached   Run in the background, log to dist/demo/run.log
#
# Output in dist/demo:
#   baton-demo.mov   raw capture
#   baton-demo.mp4   1080 wide, for posting
#   baton-demo.gif   short loop
#
# Requirements: Screen Recording and Accessibility permission for the terminal
# that runs this, ffmpeg, and a pi with the baton MCP server in ~/.pi/agent/mcp.json.
#
# Notes on the shape of this script:
#   - The frame is exactly the card's width, so no other window can appear in
#     shot. Hiding windows was tried and proved unreliable, which put private code
#     on screen.
#   - The recording stops on SIGINT when the flow finishes, rather than running for
#     a guessed number of seconds. Model latency is not predictable.
#   - pi runs as its normal interactive interface, driven by keystrokes, because a
#     demo should show the tool as people actually use it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Baton.app"
MCP="$APP/Contents/MacOS/baton-mcp"
OUT="$ROOT/dist/demo"
DEMO_REPO="/tmp/notes-app"
ASK_TIMEOUT="${BATON_DEMO_ASK_TIMEOUT:-180}"

mkdir -p "$OUT"

if [ "${1:-}" = "--detached" ]; then
	# Re-exec detached. A take runs for minutes, and a caller that times out
	# should not kill the recording half way through.
	nohup "$0" >"$OUT/run.log" 2>&1 &
	echo "Recording in the background. Follow it with:"
	echo "  tail -f $OUT/run.log"
	exit 0
fi

# Short on purpose.
#
# A 500 character keystroke into a terminal interface drops characters, and one
# take was lost to it. The detail lives in a file the agent reads, which is both
# reliable and closer to how anyone actually briefs an agent.
REQUEST="read REVIEW.md and do exactly that"

# --- Geometry -----------------------------------------------------------------

SCREEN_WIDTH="$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)')"
CARD_WIDTH=620
CARD_LEFT=$(((SCREEN_WIDTH - CARD_WIDTH) / 2))
# The frame ends exactly at the terminal's bottom edge. Any slack below it shows
# whatever window happens to be behind, which in one take was a wall of JSON.
TERMINAL_TOP=310
TERMINAL_BOTTOM=770
FRAME_HEIGHT=$TERMINAL_BOTTOM
REGION="$CARD_LEFT,0,$CARD_WIDTH,$FRAME_HEIGHT"
CENTER=$((SCREEN_WIDTH / 2))

echo "==> Screen ${SCREEN_WIDTH}pt wide, capturing $REGION"

echo "==> Building the input helper"
swiftc -O -o "$OUT/demo-input" "$ROOT/scripts/demo-input.swift"
INPUT="$OUT/demo-input"

# --- The repository the agent is working in ------------------------------------

echo "==> Building the demo repository"
rm -rf "$DEMO_REPO"
mkdir -p "$DEMO_REPO/src"
cd "$DEMO_REPO"
git init -q
printf '%s\n' '# notes-app' >README.md
cat >src/session.ts <<'TS'
export function getSession(req: Request) {
  const cookie = req.headers.get("cookie") ?? "";
  return parse(cookie).sid ?? null;
}
TS
git add -A
git -c user.email=demo@example.com -c user.name=Demo commit -qm "initial"
git checkout -q -b refactor/session-handling
cat >src/session.ts <<'TS'
import { verify } from "./crypto";

export async function getSession(req: Request) {
  const cookie = req.headers.get("cookie") ?? "";
  const sid = parse(cookie).sid;
  if (!sid) return null;
  return (await verify(sid)) ? load(sid) : null;
}
TS
git add -A
git -c user.email=demo@example.com -c user.name=Demo commit -qm "verify session cookies"

# The brief. Naming the gateway call exactly keeps a failed tool lookup out of the
# shot, and a one-line question keeps the card a predictable height.
cat >REVIEW.md <<'MD'
Get my review of this branch before committing.

Call `mcp` with server `baton`, tool `ask_human`, and these arguments:

- question: Review the session refactor before I commit?
- kind: reviewChange
- worktree: /tmp/notes-app
- baseRef: main
- priority: high
- details: Cookies are now verified before the session loads. Tests pass.
- checklist: ["Logged-in users stay logged in", "An invalid cookie returns null"]
- waitSeconds: 150

Then tell me in two short lines what I decided. Do not run any other tool first.
MD

# --- A clean stage ------------------------------------------------------------

cd "$ROOT"
echo "==> Clearing the queue and restarting Baton"
for id in $("$MCP" list 2>/dev/null | awk '{print $1}'); do
	"$MCP" respond "$id" cancel "demo reset" >/dev/null 2>&1 || true
done
# Auto-expand off, so the notch peeks and expands exactly as it does for a user.
# Tracing on, because the card's height depends on its content and the log is how
# this script finds the buttons instead of guessing at fixed offsets.
APP_LOG="$HOME/Library/Application Support/dev.baton/app.log"
mkdir -p "$HOME/Library/Application Support/dev.baton"
touch "$HOME/Library/Application Support/dev.baton/DEBUG"
rm -f "$HOME/Library/Application Support/dev.baton/DEBUG_EXPAND"
rm -f "$APP_LOG"
pkill -x BatonApp 2>/dev/null || true
sleep 1
open "$APP"
sleep 4

echo "==> Starting pi"
# A window left busy by an earlier run silently swallows `do script`, which
# records nothing. Start from a closed state.
osascript -e 'tell application "Terminal" to close every window' >/dev/null 2>&1 || true
pkill -f 'bin/pi' 2>/dev/null || true
sleep 1

TERMINAL_WINDOW="$(
	osascript <<AS
tell application "Terminal"
	activate
	set theTab to do script "cd $DEMO_REPO && clear && pi"
	set theWindow to first window whose tabs contains theTab
	set bounds of theWindow to {$CARD_LEFT, $TERMINAL_TOP, $((CARD_LEFT + CARD_WIDTH)), $TERMINAL_BOTTOM}
	set the font size of theWindow to 12
	return id of theWindow
end tell
AS
)"
[ -n "$TERMINAL_WINDOW" ] || {
	echo "Could not open a Terminal window." >&2
	exit 1
}
echo "    window $TERMINAL_WINDOW, waiting for the interface"
# The interface takes a while to draw, and typing into it early loses the text.
sleep 15

# --- Roll ---------------------------------------------------------------------

echo "==> Recording"
rm -f "$OUT/baton-demo.mov"
screencapture -v -R "$REGION" "$OUT/baton-demo.mov" &
RECORDER=$!
RECORD_START="$(date +%s)"

stop_recording() {
	if kill -0 "$RECORDER" 2>/dev/null; then
		kill -INT "$RECORDER" 2>/dev/null || true
		wait "$RECORDER" 2>/dev/null || true
	fi
}

sleep 2

echo "==> Typing the request"
# Keystrokes go to pi's own interface, which is the point: this is the tool as
# people actually use it, rather than a scripted one-shot invocation.
#
# `keystroke` silently goes nowhere if Terminal is not frontmost, and that race
# cost several takes: the interface sat with an empty input box while the script
# waited for a task that was never requested. So type, then confirm the text is on
# screen before pressing Return.
TYPED=0
for attempt in 1 2 3; do
	osascript <<AS >/dev/null 2>&1 || true
tell application "Terminal" to activate
delay 0.8
tell application "System Events"
	repeat until frontmost of process "Terminal" is true
		delay 0.2
	end repeat
	keystroke "$REQUEST"
end tell
AS
	sleep 1.2
	if osascript -e "tell application \"Terminal\" to get contents of front window" 2>/dev/null |
		grep -q "REVIEW.md"; then
		TYPED=1
		break
	fi
	echo "    attempt $attempt did not land, retrying"
done

if [ "$TYPED" != "1" ]; then
	echo "Could not type into the pi interface. Is Accessibility permission granted?" >&2
	stop_recording
	exit 1
fi

# Submit.
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1

echo "==> Waiting for the agent to ask"
TASK_ID=""
for _ in $(seq 1 "$ASK_TIMEOUT"); do
	TASK_ID="$("$MCP" list 2>/dev/null | awk '{print $1}' | head -1)"
	[ -n "$TASK_ID" ] && break
	sleep 1
done

if [ -z "$TASK_ID" ]; then
	echo "The agent never asked within ${ASK_TIMEOUT}s." >&2
	echo "The request was probably not typed. Check the Terminal window." >&2
	stop_recording
	exit 1
fi
ASK_OFFSET=$(($(date +%s) - RECORD_START))
[ "$ASK_OFFSET" -lt 4 ] && ASK_OFFSET=4
echo "    task $TASK_ID, asked at ${ASK_OFFSET}s"

# Click the shell to open the card. A synthetic hover does not reliably generate
# the mouse-moved events a tracking area needs, so a click is deterministic.
sleep 1.5
"$INPUT" click "$CENTER" 14
sleep 2.5

# Read the card's real height instead of assuming one.
#
# The height depends on the agent's wording, and a fixed offset silently misses:
# an earlier take ticked one checkbox and lost the Approve click entirely. These
# offsets are measured from the bottom of the card, where the layout is stable
# because the checklist is the last block above the action row.
CARD_HEIGHT="$(grep 'shell frame' "$APP_LOG" | grep 'phase=expanded' | tail -1 |
	sed -nE 's/.*620\.0, ([0-9]+)(\.[0-9]+)?\).*/\1/p')"
if [ -z "$CARD_HEIGHT" ]; then
	echo "Could not read the card height from $APP_LOG." >&2
	stop_recording
	exit 1
fi
echo "    card is ${CARD_HEIGHT}pt tall"

CHECK_ONE_Y=$((CARD_HEIGHT - 90))
CHECK_TWO_Y=$((CARD_HEIGHT - 68))
APPROVE_Y=$((CARD_HEIGHT - 23))

"$INPUT" click $((CARD_LEFT + 130)) "$CHECK_ONE_Y"
sleep 1.1
"$INPUT" click $((CARD_LEFT + 130)) "$CHECK_TWO_Y"
sleep 1.4
"$INPUT" click $((CARD_LEFT + 568)) "$APPROVE_Y"

# Verify, rather than assume. A missed click produced a take that looked fine
# until the frames were inspected.
sleep 2
STATE="$("$MCP" list --all 2>/dev/null | grep "$TASK_ID" | awk '{print $2}')"
if [ "$STATE" != "done" ]; then
	echo "Approve did not register: task is '$STATE'." >&2
	stop_recording
	exit 1
fi
echo "==> Approved"
APPROVE_OFFSET=$(($(date +%s) - RECORD_START))

# Wait for the agent to actually finish, rather than guessing. An earlier take cut
# while pi was still working, so the video ended without the payoff.
echo "==> Waiting for the agent to finish"
for _ in $(seq 1 90); do
	BUSY="$(osascript -e "tell application \"Terminal\" to get busy of window id $TERMINAL_WINDOW" 2>/dev/null || echo true)"
	[ "$BUSY" = "false" ] && break
	sleep 1
done
FINISH_OFFSET=$(($(date +%s) - RECORD_START))
# Let the last lines land and stay readable.
sleep 5
stop_recording
TOTAL_OFFSET=$(($(date +%s) - RECORD_START))

[ -s "$OUT/baton-demo.mov" ] || {
	echo "The capture did not save. Check Screen Recording permission." >&2
	exit 1
}

# --- Encode -------------------------------------------------------------------

echo "==> Encoding"
# Four segments: the agent thinking, the interaction, the agent working, the
# answer. Only the two stretches of waiting are compressed, so the parts a viewer
# came for play at real speed and nothing is misrepresented as instant.
FILTER="$(python3 - "$ASK_OFFSET" "$APPROVE_OFFSET" "$FINISH_OFFSET" "$TOTAL_OFFSET" <<'PY'
import sys

ask, approve, finish, total = (float(value) for value in sys.argv[1:5])
# Boundaries, clamped so the segments stay in order even on a fast run.
first = max(0.6, ask - 2.0)
second = max(first + 1.0, approve + 5.0)
third = max(second + 0.5, min(finish, total - 5.0))
parts = [
    f"[0:v]trim=0:{first:.2f},setpts=(PTS-STARTPTS)/5[s1]",
    f"[0:v]trim={first:.2f}:{second:.2f},setpts=PTS-STARTPTS[s2]",
    f"[0:v]trim={second:.2f}:{third:.2f},setpts=(PTS-STARTPTS)/8[s3]",
    f"[0:v]trim={third:.2f},setpts=PTS-STARTPTS[s4]",
    "[s1][s2][s3][s4]concat=n=4:v=1,scale=1080:-2:flags=lanczos[v]",
]
print(";".join(parts))
PY
)"
ffmpeg -y -loglevel error -i "$OUT/baton-demo.mov" -filter_complex "$FILTER" \
	-map "[v]" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart \
	"$OUT/baton-demo.mp4"

ffmpeg -y -loglevel error -i "$OUT/baton-demo.mp4" \
	-vf "fps=15,scale=620:-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
	"$OUT/baton-demo.gif"

echo
for file in "$OUT"/baton-demo.*; do
	printf '    %s  %s\n' "$(basename "$file")" "$(du -h "$file" | cut -f1)"
done
echo
echo "Done: $OUT/baton-demo.mp4"
