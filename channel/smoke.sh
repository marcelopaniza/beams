#!/usr/bin/env bash
# smoke.sh — best-effort smoke test for buses-channel.mjs.
#
# Starts the channel server with stdin kept alive via a background writer
# process, drives it through a sequence of JSON-RPC and HTTP checks, and
# reports PASS/FAIL for each.
#
# Checks:
#   1. initialize JSON-RPC  → response contains "claude/channel" capability
#   2. ping JSON-RPC        → response echoes correct id
#   3. tools/list JSON-RPC  → empty tools array
#   4. unknown method       → error code -32601
#   5. GET /health          → "ok"
#   6. POST valid token     → notifications/claude/channel emitted on stdout
#   7. POST wrong token     → HTTP 403, no notification on stdout
#   8. Content sanitization → C0/DEL control chars stripped from body
#   9. Notification (no id) → no stdout response emitted
#
# Uses a random high port to avoid clashes with other runs.
# Temp files and the server process are cleaned up on exit.

set -euo pipefail

NODE="${NODE:-/usr/bin/node}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="$SCRIPT_DIR/buses-channel.mjs"

# Random port in range 20000-29999.
PORT=$(( 20000 + RANDOM % 10000 ))
TOKEN=$(openssl rand -hex 16 2>/dev/null || \
        dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')

SERVER_PID=
WRITER_PID=
RPC_PIPE=
TMP_OUT=

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null || true
  [ -n "$WRITER_PID" ] && kill "$WRITER_PID" 2>/dev/null && wait "$WRITER_PID" 2>/dev/null || true
  [ -n "$RPC_PIPE"   ] && rm -f "$RPC_PIPE"   2>/dev/null || true
  [ -n "$TMP_OUT"    ] && rm -f "$TMP_OUT"    2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

echo "=== buses-channel smoke test (port=$PORT) ==="

# ---------------------------------------------------------------------------
# Build the stdin feed for the server.
#
# We need a long-lived stdin: closing it causes the readline 'close' event
# which makes the server exit(0).  Strategy: create a named pipe, start a
# background "writer keeper" process that opens the write-end and sleeps
# until we're done (keeping stdin alive), then start the server reading
# from the read-end.
#
# The open() ordering rule for named pipes: the reader's open(O_RDONLY)
# blocks until at least one writer holds the write-end.  We therefore open
# the write-end in the background FIRST, then start the server.
# ---------------------------------------------------------------------------
RPC_PIPE=$(mktemp -u /tmp/buses-smoke-pipe.XXXXXX)
mkfifo "$RPC_PIPE"

TMP_OUT=$(mktemp /tmp/buses-smoke-out.XXXXXX)

# Open the write-end first to unblock the server's read-end open.
# This writer sleeps until we kill it; we kill it at the end to signal EOF.
( sleep 300 ) >"$RPC_PIPE" &
WRITER_PID=$!

export BUSES_CHANNEL_PORT="$PORT"
export BUSES_CHANNEL_TOKEN="$TOKEN"

# Now start the server — its stdin open() will succeed immediately.
"$NODE" "$SERVER" <"$RPC_PIPE" >"$TMP_OUT" 2>/dev/null &
SERVER_PID=$!

# Wait for HTTP listener (poll /health, hard 5s timeout).
MAX_TICKS=50   # 50 x 0.1s = 5s
ticks=0
while ! curl -s -o /dev/null -m 1 "http://127.0.0.1:${PORT}/health" 2>/dev/null; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "  FAIL: server exited before becoming ready"
    exit 1
  fi
  sleep 0.1
  ticks=$(( ticks + 1 ))
  if [ "$ticks" -ge "$MAX_TICKS" ]; then
    echo "  FAIL: server did not become ready within 5s on port $PORT"
    exit 1
  fi
done
echo "  server ready (pid=$SERVER_PID, port=$PORT)"

# ---------------------------------------------------------------------------
# RPC sender: writes one JSON-RPC line to the server's stdin.
# We write through a second fd opened on the pipe's write-end so we can
# send individual lines without killing the WRITER_PID keeper.
# ---------------------------------------------------------------------------
exec 4>"$RPC_PIPE"

send_rpc() {
  printf '%s\n' "$1" >&4
  sleep 0.2
}

# Count non-empty lines in TMP_OUT.
line_count() {
  grep -c . "$TMP_OUT" 2>/dev/null || echo 0
}

BASELINE=0

# ---------------------------------------------------------------------------
# 1. initialize
# ---------------------------------------------------------------------------
echo ""
echo "--- 1. initialize ---"
send_rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
LINE_AFTER=$(line_count)
if [ "$LINE_AFTER" -gt "$BASELINE" ]; then
  RESP=$(sed -n "$(( BASELINE + 1 ))p" "$TMP_OUT")
  echo "$RESP" | grep -q '"claude/channel"'       && ok 'initialize: claude/channel capability present'  || fail "initialize: missing claude/channel — $RESP"
  echo "$RESP" | grep -q '"buses"'                && ok 'initialize: serverInfo.name="buses"'           || fail "initialize: missing serverInfo.name — $RESP"
  echo "$RESP" | grep -q '"protocolVersion"'      && ok 'initialize: protocolVersion echoed'            || fail "initialize: missing protocolVersion — $RESP"
  BASELINE="$LINE_AFTER"
else
  fail 'initialize: no stdout line emitted'
fi

# ---------------------------------------------------------------------------
# 2. ping
# ---------------------------------------------------------------------------
echo ""
echo "--- 2. ping ---"
send_rpc '{"jsonrpc":"2.0","id":2,"method":"ping"}'
LINE_AFTER=$(line_count)
if [ "$LINE_AFTER" -gt "$BASELINE" ]; then
  RESP=$(sed -n "$(( BASELINE + 1 ))p" "$TMP_OUT")
  echo "$RESP" | grep -q '"id":2'  && ok 'ping: correct id echoed'  || fail "ping: bad response — $RESP"
  BASELINE="$LINE_AFTER"
else
  fail 'ping: no stdout line emitted'
fi

# ---------------------------------------------------------------------------
# 3. tools/list
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. tools/list ---"
send_rpc '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
LINE_AFTER=$(line_count)
if [ "$LINE_AFTER" -gt "$BASELINE" ]; then
  RESP=$(sed -n "$(( BASELINE + 1 ))p" "$TMP_OUT")
  echo "$RESP" | grep -q '"tools":\[\]'  && ok 'tools/list: empty tools array'  || fail "tools/list: bad response — $RESP"
  BASELINE="$LINE_AFTER"
else
  fail 'tools/list: no stdout line emitted'
fi

# ---------------------------------------------------------------------------
# 4. unknown method → -32601
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. unknown method ---"
send_rpc '{"jsonrpc":"2.0","id":4,"method":"no/such/method"}'
LINE_AFTER=$(line_count)
if [ "$LINE_AFTER" -gt "$BASELINE" ]; then
  RESP=$(sed -n "$(( BASELINE + 1 ))p" "$TMP_OUT")
  echo "$RESP" | grep -qE '"code":-32601|-32601'  && ok 'unknown method: error -32601'  || fail "unknown method: bad response — $RESP"
  BASELINE="$LINE_AFTER"
else
  fail 'unknown method: no stdout line emitted'
fi

# ---------------------------------------------------------------------------
# 5. GET /health
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. GET /health ---"
HEALTH=$(curl -s -m 5 "http://127.0.0.1:${PORT}/health")
[ "$HEALTH" = "ok" ]  && ok 'GET /health → "ok"'  || fail "GET /health returned: $HEALTH"

# ---------------------------------------------------------------------------
# 6. POST with valid token → notifications/claude/channel
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. POST with valid token ---"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST \
  -H "x-buses-token: $TOKEN" \
  -H "x-buses-bus: testbus" \
  -H "x-buses-from: smoketest" \
  --data-binary "hello from smoke test" \
  "http://127.0.0.1:${PORT}/")
sleep 0.2
LINE_AFTER=$(line_count)

[ "$HTTP_CODE" = "200" ]  && ok 'POST valid token → HTTP 200'  || fail "POST valid token → HTTP $HTTP_CODE"

if [ "$LINE_AFTER" -gt "$BASELINE" ]; then
  RESP=$(sed -n "$(( BASELINE + 1 ))p" "$TMP_OUT")
  echo "$RESP" | grep -q '"notifications/claude/channel"'  && ok 'POST: notifications/claude/channel emitted'  || fail "POST: wrong method on stdout — $RESP"
  echo "$RESP" | grep -q '"testbus"'                       && ok 'POST: meta.bus="testbus"'                   || fail "POST: missing bus in meta — $RESP"
  echo "$RESP" | grep -q '"smoketest"'                     && ok 'POST: meta.from="smoketest"'                || fail "POST: missing from in meta — $RESP"
  echo "$RESP" | grep -q '"hello from smoke test"'         && ok 'POST: content forwarded'                   || fail "POST: content missing — $RESP"
  BASELINE="$LINE_AFTER"
else
  fail 'POST valid token: no stdout notification emitted'
fi

# ---------------------------------------------------------------------------
# 7. POST with wrong token → 403, no notification
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. POST with wrong token ---"
PRE="$BASELINE"
BAD_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST \
  -H "x-buses-token: definitely_wrong_token" \
  --data-binary "injected" \
  "http://127.0.0.1:${PORT}/")
sleep 0.2
LINE_AFTER=$(line_count)

[ "$BAD_CODE" = "403" ]  && ok 'POST wrong token → HTTP 403'  || fail "POST wrong token → HTTP $BAD_CODE"

if [ "$LINE_AFTER" -gt "$PRE" ]; then
  SPURIOUS=$(sed -n "$(( PRE + 1 ))p" "$TMP_OUT")
  if echo "$SPURIOUS" | grep -q '"notifications/claude/channel"'; then
    fail 'POST wrong token: channel notification was emitted (should be suppressed)'
  else
    ok 'POST wrong token: no channel notification emitted'
  fi
else
  ok 'POST wrong token: no new stdout lines'
fi
BASELINE=$(line_count)

# ---------------------------------------------------------------------------
# 8. Content sanitization — C0 + DEL chars stripped
# ---------------------------------------------------------------------------
echo ""
echo "--- 8. Content sanitization ---"
curl -s -o /dev/null -m 5 -X POST \
  -H "x-buses-token: $TOKEN" \
  -H "x-buses-bus: sanitest" \
  --data-binary $'hello\x01\x1fworld\x7f' \
  "http://127.0.0.1:${PORT}/"
sleep 0.2
LINE_AFTER=$(line_count)
if [ "$LINE_AFTER" -gt "$BASELINE" ]; then
  RESP=$(sed -n "$(( BASELINE + 1 ))p" "$TMP_OUT")
  echo "$RESP" | grep -q '"helloworld"'  && ok 'sanitize: C0+DEL stripped from body'  || fail "sanitize: unexpected content — $RESP"
  BASELINE="$LINE_AFTER"
else
  fail 'sanitize: no stdout line emitted'
fi

# ---------------------------------------------------------------------------
# 9. Incoming notification (no id) → silent
# ---------------------------------------------------------------------------
echo ""
echo "--- 9. Incoming notification (no id) ---"
PRE="$BASELINE"
send_rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}'
LINE_AFTER=$(line_count)
if [ "$LINE_AFTER" -gt "$PRE" ]; then
  fail 'incoming notification (no id): unexpected stdout output'
else
  ok 'incoming notification (no id): handled silently'
fi

# ---------------------------------------------------------------------------
# Tear down: close our send fd, kill the keeper to signal EOF to the server.
# ---------------------------------------------------------------------------
exec 4>&-
kill "$WRITER_PID" 2>/dev/null; wait "$WRITER_PID" 2>/dev/null || true
WRITER_PID=

# Summary
echo ""
echo "============================================"
if [ "$FAIL" -eq 0 ]; then
  echo "PASS  ($PASS checks passed, $FAIL failed)"
else
  echo "FAIL  ($PASS checks passed, $FAIL failed)"
fi
echo "============================================"

[ "$FAIL" -eq 0 ]
