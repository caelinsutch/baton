#!/usr/bin/env bash
#
# End-to-end check of the MCP server: handshake, tool list, tool call, and a
# human response that reaches the waiting agent.
#
# This is the test that matters. A protocol regression here breaks every agent,
# and a unit test on the store would not catch it.
#
# Usage:
#   scripts/smoke-mcp.sh [path-to-baton-mcp]

set -euo pipefail

MCP="${1:-dist/Baton.app/Contents/MacOS/baton-mcp}"
if [ ! -x "$MCP" ]; then
	echo "baton-mcp not found at $MCP" >&2
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# An isolated database, so a smoke test never touches the real queue.
export BATON_DB="$WORK/smoke.db"
export BATON_NO_LAUNCH=1
export BATON_LOG=0

echo "==> doctor"
"$MCP" doctor

echo "==> handshake, tools/list, submit_task"
printf '%s\n' \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
	'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
	'{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
	'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"submit_task","arguments":{"title":"smoke test","sessionId":"smoke"}}}' \
	| "$MCP" serve >"$WORK/out.jsonl"

python3 - "$WORK/out.jsonl" <<'PY'
import json
import sys

replies = {}
with open(sys.argv[1]) as handle:
    for line in handle:
        message = json.loads(line)
        replies[message.get("id")] = message

assert 1 in replies, "no initialize reply"
assert replies[1]["result"]["serverInfo"]["name"] == "baton", replies[1]
tools = replies[2]["result"]["tools"]
assert tools, "no tools listed"
names = {tool["name"] for tool in tools}
for required in ("ask_human", "submit_task", "await_task", "get_task", "list_tasks", "cancel_task"):
    assert required in names, f"missing tool: {required}"
for tool in tools:
    assert tool["inputSchema"]["type"] == "object", tool["name"]
call = replies[3]["result"]
assert call["isError"] is False, call
assert call["structuredContent"]["status"] == "pending", call
print(f"ok: {len(tools)} tools, submit_task returned {call['structuredContent']['id']}")
PY

echo "==> blocking round trip"
# Answer from a second process while the first blocks. This is the real loop:
# the store on disk is what connects them.
(
	sleep 2
	ID="$("$MCP" list | awk '/blocking round trip/ {print $1}')"
	"$MCP" respond "$ID" answer "looks good" >/dev/null
) &
ANSWER_PID=$!

printf '%s\n' \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
	'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_human","arguments":{"question":"blocking round trip","waitSeconds":20,"sessionId":"smoke"}}}' \
	| "$MCP" serve >"$WORK/blocking.jsonl"
wait "$ANSWER_PID"

python3 - "$WORK/blocking.jsonl" <<'PY'
import json
import sys

result = None
with open(sys.argv[1]) as handle:
    for line in handle:
        message = json.loads(line)
        if message.get("id") == 2:
            result = message["result"]

assert result is not None, "ask_human never replied"
payload = result["structuredContent"]
assert payload["status"] == "done", payload
assert payload["response"]["decision"] == "answered", payload
assert payload["response"]["text"] == "looks good", payload
print("ok: the human answer reached the blocked agent")
PY

echo
echo "MCP smoke test passed."
