#!/usr/bin/env bash
# Round 21 — the real-time channel doorbell: per-session auto-port + fan-out +
# the watcher's --on-message hook (channel/on-message.sh) end to end.
#
# The bug this guards against: every session's channel server used to bind the
# same fixed 8799 and exit on EADDRINUSE, so at most ONE session could ever be
# woken, and the watcher was never even wired to POST. Now the server binds an
# OS-assigned free port and publishes it to a per-session rendezvous file keyed
# by CLAUDE_CODE_SESSION_ID; the on-message hook reads that file to POST to the
# right server. Cases:
#   A. no BEAMS_CHANNEL_PORT  -> OS-assigned port + rendezvous file written
#   B. two sessions at once   -> two different ports, no collision (fan-out)
#   C. explicit port          -> honored, and still published to the file
#   D. on-message.sh          -> reads the file, POSTs, server emits a <channel>
#   E. wrong token            -> server rejects, NO channel event emitted
#   F. no session id          -> binds fine but writes NO rendezvous file
#   G. SIGTERM                -> the server removes its own rendezvous file

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
NODE="${NODE:-$(command -v node || echo /usr/bin/node)}"
TMP=$(mktemp -d /tmp/beams-test-r21.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"   # sandbox the rendezvous tree
export HOME="$TMP/home"
mkdir -p "$XDG_CONFIG_HOME" "$HOME"
unset CLAUDE_CODE_SESSION_ID        # never inherit the real session's id
CHANDIR="$XDG_CONFIG_HOME/beams/channels"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

SERVERS=(); KEEPERS=(); PIPES=()
cleanup() {
  local p
  for p in "${SERVERS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  for p in "${KEEPERS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  for p in "${PIPES[@]:-}";   do [ -n "$p" ] && rm -f "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# start_server <sid|""> <token|""> <explicit_port|""> <out_file> <err_file> -> echoes server pid
start_server() {
  local sid="$1" token="$2" port="$3" out="$4" err="$5"
  local pipe; pipe=$(mktemp -u "$TMP/pipe.XXXXXX"); mkfifo "$pipe"; PIPES+=("$pipe")
  ( sleep 120 ) > "$pipe" & KEEPERS+=("$!")        # hold stdin open so the server stays up
  local e=(env)
  if [ -n "$sid" ]; then e+=("CLAUDE_CODE_SESSION_ID=$sid"); else e+=(-u CLAUDE_CODE_SESSION_ID); fi
  [ -n "$token" ] && e+=("BEAMS_CHANNEL_TOKEN=$token")
  [ -n "$port" ]  && e+=("BEAMS_CHANNEL_PORT=$port")
  "${e[@]}" "$NODE" "$PLUGIN/channel/beams-channel.mjs" < "$pipe" > "$out" 2>"$err" &
  local pid=$!; SERVERS+=("$pid"); echo "$pid"
}

healthy() { [ "$(curl -s -m 2 "http://127.0.0.1:$1/health" 2>/dev/null || true)" = ok ]; }

wait_for_portfile() {  # <path> ; up to ~5s
  local f="$1" i=0
  while [ "$i" -lt 50 ]; do [ -r "$f" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}

port_of_stderr() {  # parse "HTTP listener ready on 127.0.0.1:<port>" from an err log
  sed -n 's/.*127\.0\.0\.1:\([0-9]\{1,5\}\).*/\1/p' "$1" 2>/dev/null | head -1
}

count_events() { grep -c 'notifications/claude/channel' "$1" 2>/dev/null || true; }

command -v curl >/dev/null 2>&1 || { echo "  (skipped — no curl on this host)"; exit 0; }
[ -x "$NODE" ] || NODE=$(command -v node || true)
[ -n "$NODE" ] || { echo "  (skipped — no node on this host)"; exit 0; }

# ---------------------------------------------------------------------------
banner "A. no BEAMS_CHANNEL_PORT -> OS-assigned port + rendezvous file"
TOKEN_A="tok-$$-A"
start_server sess-A "$TOKEN_A" "" "$TMP/A.out" "$TMP/A.err" >/dev/null
PF_A="$CHANDIR/sess-A.port"
wait_for_portfile "$PF_A" || fail "no rendezvous file for sess-A; err: $(cat "$TMP/A.err")"
PORT_A=$(cat "$PF_A")
case "$PORT_A" in ''|*[!0-9]*) fail "sess-A port file not an integer: '$PORT_A'";; esac
[ "$PORT_A" -gt 0 ] || fail "sess-A port not positive: $PORT_A"
healthy "$PORT_A" || fail "sess-A not healthy on $PORT_A"
# file perms: 0600 file under a 0700 dir
[ "$(stat -c '%a' "$PF_A" 2>/dev/null)" = 600 ] || fail "rendezvous file not mode 0600"
[ "$(stat -c '%a' "$CHANDIR" 2>/dev/null)" = 700 ] || fail "channels dir not mode 0700"
pass "sess-A bound OS-assigned port $PORT_A, published 0600 to $PF_A, /health ok"

# ---------------------------------------------------------------------------
banner "B. a second session at the same time -> different port, no collision"
TOKEN_B="tok-$$-B"
start_server sess-B "$TOKEN_B" "" "$TMP/B.out" "$TMP/B.err" >/dev/null
PF_B="$CHANDIR/sess-B.port"
wait_for_portfile "$PF_B" || fail "no rendezvous file for sess-B (collision/EADDRINUSE?); err: $(cat "$TMP/B.err")"
PORT_B=$(cat "$PF_B")
[ "$PORT_B" != "$PORT_A" ] || fail "sess-B got the SAME port as sess-A ($PORT_B) — no fan-out"
healthy "$PORT_B" || fail "sess-B not healthy on $PORT_B"
healthy "$PORT_A" || fail "sess-A stopped being healthy after sess-B started"
pass "two servers coexist on distinct ports ($PORT_A vs $PORT_B) — the fan-out fix"

# ---------------------------------------------------------------------------
banner "C. an explicit BEAMS_CHANNEL_PORT is honored and still published"
EXPLICIT=$(( 20000 + (RANDOM % 1500) ))
start_server sess-C "tok-C" "$EXPLICIT" "$TMP/C.out" "$TMP/C.err" >/dev/null
PF_C="$CHANDIR/sess-C.port"
wait_for_portfile "$PF_C" || fail "no rendezvous file for sess-C (port $EXPLICIT taken? rerun); err: $(cat "$TMP/C.err")"
[ "$(cat "$PF_C")" = "$EXPLICIT" ] || fail "sess-C published $(cat "$PF_C") but asked for $EXPLICIT"
healthy "$EXPLICIT" || fail "sess-C not healthy on explicit $EXPLICIT"
pass "explicit port $EXPLICIT honored and published to the rendezvous file"

# ---------------------------------------------------------------------------
banner "D. the real on-message.sh hook wakes the right session end to end"
PRE=$(count_events "$TMP/A.out")
CLAUDE_CODE_SESSION_ID=sess-A BEAMS_CHANNEL_TOKEN="$TOKEN_A" \
  BEAMS_BEAM=all BEAMS_FROM=jose BEAMS_PREVIEW="please wake up now" \
  bash "$PLUGIN/channel/on-message.sh"
sleep 0.3
POST=$(count_events "$TMP/A.out")
[ "$POST" -gt "$PRE" ] || fail "on-message.sh did not produce a channel event on sess-A (pre=$PRE post=$POST)"
grep -q '"please wake up now"' "$TMP/A.out" || fail "channel event missing the message content"
grep -q '"jose"' "$TMP/A.out" || fail "channel event missing from=jose meta"
# and it must have gone to A, not B
[ "$(count_events "$TMP/B.out")" = "0" ] || fail "leaked a channel event to the WRONG session (B)"
pass "on-message.sh read sess-A's port, POSTed, and only sess-A emitted the <channel> event"

# ---------------------------------------------------------------------------
banner "E. a wrong token is rejected (no channel event)"
PRE=$(count_events "$TMP/A.out")
CLAUDE_CODE_SESSION_ID=sess-A BEAMS_CHANNEL_TOKEN="definitely-wrong" \
  BEAMS_BEAM=all BEAMS_FROM=mallory BEAMS_PREVIEW="should be blocked" \
  bash "$PLUGIN/channel/on-message.sh"
sleep 0.3
POST=$(count_events "$TMP/A.out")
[ "$POST" = "$PRE" ] || fail "a wrong-token POST still emitted a channel event (pre=$PRE post=$POST)"
grep -q 'should be blocked' "$TMP/A.out" && fail "blocked content leaked into the channel" || true
pass "wrong-token POST via on-message.sh is refused — no <channel> event"

# ---------------------------------------------------------------------------
banner "F. no session id -> the server binds but writes NO rendezvous file"
before=$(find "$CHANDIR" -maxdepth 1 -name '*.port' 2>/dev/null | wc -l | tr -d ' ')
start_server "" "tok-F" "" "$TMP/F.out" "$TMP/F.err" >/dev/null
# wait until it logs readiness (no port file to wait on)
i=0; PORT_F=""
while [ "$i" -lt 50 ]; do PORT_F=$(port_of_stderr "$TMP/F.err"); [ -n "$PORT_F" ] && break; sleep 0.1; i=$((i+1)); done
[ -n "$PORT_F" ] || fail "no-sid server never reported a bound port; err: $(cat "$TMP/F.err")"
healthy "$PORT_F" || fail "no-sid server not healthy on $PORT_F"
after=$(find "$CHANDIR" -maxdepth 1 -name '*.port' 2>/dev/null | wc -l | tr -d ' ')
[ "$after" = "$before" ] || fail "a session-less server wrote a rendezvous file ($before -> $after) — smoke-test path would break"
pass "no session id: server healthy on $PORT_F, wrote no rendezvous file (smoke-test compatible)"

# ---------------------------------------------------------------------------
banner "G. SIGTERM -> the server removes its own rendezvous file"
# kill sess-C and confirm its file is gone (the server unlinks on exit)
CPID=$(cat "$TMP/C.err" >/dev/null 2>&1; pgrep -f "CLAUDE_CODE_SESSION_ID=sess-C" 2>/dev/null | head -1 || true)
# more robust: find the SERVERS pid we recorded for sess-C (3rd start = index 2)
CPID="${SERVERS[2]}"
kill -TERM "$CPID" 2>/dev/null || true
i=0; while [ "$i" -lt 30 ]; do [ -e "$PF_C" ] || break; sleep 0.1; i=$((i+1)); done
[ -e "$PF_C" ] && fail "sess-C rendezvous file survived SIGTERM (not cleaned up)" || true
pass "SIGTERM unlinked sess-C's rendezvous file"

green ""
green "round-21 PASS: per-session OS-assigned ports fan out with no collision; on-message.sh wakes the correct session; wrong tokens blocked; session-less runs write no file; servers clean up their rendezvous file on exit"
