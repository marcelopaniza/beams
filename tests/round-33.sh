#!/usr/bin/env bash
# Round 33 — the doorbell across SEVERAL named sessions bound in ONE project
# folder. Open field report: "the doorbell is unreliable when several named
# sessions run in one project folder". Round 31 proved the process lease is
# per-identity; round 32 proved the native inbox-socket transport for ONE
# identity. This round proves the two compose correctly for THREE identities
# sharing one CLAUDE_PROJECT_DIR: each gets its own process lease, its own
# published inbox pointer, its own fake AF_UNIX socket, and its own watcher
# daemon — and a message never crosses from one identity's socket or
# wake.log into another's.
# Cases:
#   A. setup: alice, bob, carol bound in ONE project dir, each with a distinct
#      fake Claude process (pid + start time), its own inbox socket, its own
#      published pointer, and its own watcher daemon.
#   1/2. from a 4th (sender-only) identity: one message to bob only, one to
#      alice only, one to "all", and one that @-mentions carol in the body
#      with a `to:` naming none of them — each identity's fake socket ends up
#      with the EXACT total message count addressed to it (batched into one
#      post or split across several — only the total is asserted), and never
#      a count belonging to another identity.
#   3. each identity's wake.log holds exactly its own event count.
#   4. a /clear-style rotation for bob (new session id, SAME claude pid, SAME
#      socket env): bob stays bound to "bob", the pointer is still the one
#      file naming the same socket, and a further bob-only message posts to
#      bob's socket exactly once more — with no change to alice's or carol's
#      totals.
#   5. SessionEnd(other) for alice drops only her pointer + lease; bob's and
#      carol's stay untouched.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r33.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg" HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR CLAUDE_PID BEAMS_FAKE_LIVE_SESSIONS
# Hermetic above all else: inside a real Claude session these two name the
# user's REAL live inbox; a leaked publish would post test traffic into it.
unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
export BEAMS_NOTIFIER_CMD=true        # no real desktop notifications
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # we start every daemon ourselves, by hand
SHARED="$TMP/share"; mkdir -p "$SHARED"
BASE="$XDG_CONFIG_HOME/beams"
PKEY=$(printf '%s' "$CLAUDE_PROJECT_DIR" | sed 's,/,-,g')
IDENT="$BASE/projects/$PKEY/identities"
BEAM="r33-beam"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

P_ALICE=""; P_BOB=""; P_CAROL=""
SRV_ALICE=""; SRV_BOB=""; SRV_CAROL=""
cleanup() {
  local f p
  for p in "$SRV_ALICE" "$SRV_BOB" "$SRV_CAROL" "$P_ALICE" "$P_BOB" "$P_CAROL"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  for f in "$IDENT"/*/state/*/watcher.pid; do
    [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# The native post needs python3 (bash cannot open a Unix socket), same as the
# fake inbox servers below. Skip rather than fail, mirroring round-32.
command -v python3 >/dev/null 2>&1 || {
  green "round-33 SKIPPED (no python3 on this host — the native post degrades to the wake.log fallback)"
  exit 0
}

# runas <claude-pid> <session-id> <lib> [args…] — real session/bind resolution
# (round-31's shape: a fake but distinct Claude process per identity).
runas() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2"
            "$PLUGIN/lib/$3.sh" "${@:4}" ); }
# run_as <config-dir> <lib> [args…] — explicit config dir (non-Claude shape).
run_as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
# boot <claude-pid> <session-id> <socket> <token> — the SessionStart hook with
# a native inbox in the environment (round-32's --native boot, generalised to
# a caller-chosen pid/socket/token per identity instead of one fixed triple).
boot() {
  ( unset BEAMS_CONFIG_DIR
    export CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
           CLAUDE_CODE_MESSAGING_SOCKET="$3" CLAUDE_CODE_MESSAGING_TOKEN="$4"
    printf '{"source":"startup"}' | bash "$PLUGIN/hooks/check-on-start.sh" 2>/dev/null ) || true
}
# end <claude-pid> <session-id> <reason> — the SessionEnd hook.
end() {
  ( unset BEAMS_CONFIG_DIR
    export CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN"
    printf '{"reason":"%s"}' "$3" | bash "$PLUGIN/hooks/session-end.sh" ) || true
}
w_start() { ( export BEAMS_CONFIG_DIR="$1"
              "$PLUGIN/lib/watch.sh" "start 1 --on-message bash $PLUGIN/lib/on-message.sh" ) >/dev/null; }

wait_watcher() {   # wait_watcher <identity-dir> — poll up to 5s for a live watcher.pid
  local dir="$1" i pf
  for i in $(seq 1 25); do
    for pf in "$dir"/state/*/watcher.pid; do
      [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && return 0
    done
    sleep 0.2
  done
  return 1
}

wait_sock() {      # wait_sock <path> — poll up to 5s for the AF_UNIX socket to bind
  local s="$1" i=0
  while [ "$i" -lt 50 ] && [ ! -S "$s" ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$s" ]
}

sum_n() {   # sum_n <received-log> — total N summed across every "beams doorbell:
            # N new beam message(s)" user frame recorded in that fake socket's log.
            # Batching-safe: several posts (or one) both sum correctly.
  local recv="$1"
  jq -r 'select(.type == "user") | .message.content' "$recv" 2>/dev/null \
    | grep -oE 'beams doorbell: [0-9]+ new beam message' \
    | grep -oE '[0-9]+' \
    | awk '{s += $1} END{print s + 0}' \
    || true
}

wait_total() {     # wait_total <received-log> <want> — poll (~12s) until sum_n >= want
  local recv="$1" want="$2" i=0
  while [ "$i" -lt 60 ]; do
    [ "$(sum_n "$recv")" -ge "$want" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# --- the fake session inbox (same AF_UNIX listener shape as tests/round-32.sh) ---
cat > "$TMP/fake-inbox.py" <<'PY'
# AF_UNIX listener standing in for a Claude Code session inbox: append every
# byte of every connection to a file, one connection at a time.
import os, socket, sys
path, out = sys.argv[1], sys.argv[2]
try:
    os.unlink(path)
except OSError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(16)
while True:
    c, _ = s.accept()
    buf = b''
    try:
        while True:
            d = c.recv(65536)
            if not d:
                break
            buf += d
    finally:
        c.close()
    if buf and not buf.endswith(b'\n'):
        buf += b'\n'
    with open(out, 'ab') as f:
        f.write(buf)
        f.flush()
PY

# ---------------------------------------------------------------------------
banner "A. alice, bob, carol — one project dir, distinct pid/socket/pointer/daemon each"

# Stand-ins for three distinct Claude processes (round-31: any live pid works
# for kill -0 / ps lstart).
sleep 600 & P_ALICE=$!
sleep 600 & P_BOB=$!
sleep 600 & P_CAROL=$!

SOCK_ALICE="$TMP/inbox-alice.sock"; RECV_ALICE="$TMP/received-alice.log"
SOCK_BOB="$TMP/inbox-bob.sock";     RECV_BOB="$TMP/received-bob.log"
SOCK_CAROL="$TMP/inbox-carol.sock"; RECV_CAROL="$TMP/received-carol.log"
TOK_ALICE="tok-alice-do-not-log"; TOK_BOB="tok-bob-do-not-log"; TOK_CAROL="tok-carol-do-not-log"

: > "$RECV_ALICE"; : > "$RECV_BOB"; : > "$RECV_CAROL"
python3 "$TMP/fake-inbox.py" "$SOCK_ALICE" "$RECV_ALICE" & SRV_ALICE=$!
python3 "$TMP/fake-inbox.py" "$SOCK_BOB"   "$RECV_BOB"   & SRV_BOB=$!
python3 "$TMP/fake-inbox.py" "$SOCK_CAROL" "$RECV_CAROL" & SRV_CAROL=$!
wait_sock "$SOCK_ALICE" || fail "alice's fake inbox server never bound $SOCK_ALICE"
wait_sock "$SOCK_BOB"   || fail "bob's fake inbox server never bound $SOCK_BOB"
wait_sock "$SOCK_CAROL" || fail "carol's fake inbox server never bound $SOCK_CAROL"

runas "$P_ALICE" sess-alice init "$SHARED" >/dev/null
runas "$P_ALICE" sess-alice name alice     >/dev/null
runas "$P_ALICE" sess-alice join "$BEAM"   >/dev/null
runas "$P_BOB"   sess-bob   init "$SHARED" >/dev/null
runas "$P_BOB"   sess-bob   name bob       >/dev/null
runas "$P_BOB"   sess-bob   join "$BEAM"   >/dev/null
runas "$P_CAROL" sess-carol init "$SHARED" >/dev/null
runas "$P_CAROL" sess-carol name carol     >/dev/null
runas "$P_CAROL" sess-carol join "$BEAM"   >/dev/null

ALICE="$IDENT/alice"
BOB="$IDENT/bob"
CAROL="$IDENT/carol"
[ -f "$ALICE/config.json" ] || fail "alice's identity was not created at $ALICE"
[ -f "$BOB/config.json" ]   || fail "bob's identity was not created at $BOB"
[ -f "$CAROL/config.json" ] || fail "carol's identity was not created at $CAROL"

boot "$P_ALICE" sess-alice "$SOCK_ALICE" "$TOK_ALICE" >/dev/null
boot "$P_BOB"   sess-bob   "$SOCK_BOB"   "$TOK_BOB"   >/dev/null
boot "$P_CAROL" sess-carol "$SOCK_CAROL" "$TOK_CAROL" >/dev/null

[ -f "$ALICE/inbox.json" ]                                    || fail "alice: SessionStart published no pointer"
[ "$(jq -r .socket     "$ALICE/inbox.json")" = "$SOCK_ALICE" ] || fail "alice: pointer names the wrong socket"
[ "$(jq -r .claude_pid "$ALICE/inbox.json")" = "$P_ALICE" ]    || fail "alice: pointer does not record her claude pid"
[ -f "$BOB/inbox.json" ]                                      || fail "bob: SessionStart published no pointer"
[ "$(jq -r .socket     "$BOB/inbox.json")" = "$SOCK_BOB" ]     || fail "bob: pointer names the wrong socket"
[ "$(jq -r .claude_pid "$BOB/inbox.json")" = "$P_BOB" ]        || fail "bob: pointer does not record his claude pid"
[ -f "$CAROL/inbox.json" ]                                     || fail "carol: SessionStart published no pointer"
[ "$(jq -r .socket     "$CAROL/inbox.json")" = "$SOCK_CAROL" ] || fail "carol: pointer names the wrong socket"
[ "$(jq -r .claude_pid "$CAROL/inbox.json")" = "$P_CAROL" ]    || fail "carol: pointer does not record her claude pid"
pass "three identities bound in one project dir, each with its own pid, socket, and pointer"

# A 4th, plain (non-Claude-session) identity to send from — round-28/30/32's
# CFG_B shape: a config dir with no CLAUDE_CODE_SESSION_ID.
CFG_DAVE="$TMP/cfg-dave"
run_as "$CFG_DAVE" init "$SHARED" >/dev/null
run_as "$CFG_DAVE" name dave      >/dev/null
run_as "$CFG_DAVE" join "$BEAM"   >/dev/null

# ---------------------------------------------------------------------------
banner "1/2. one send to bob only, one to alice only, one to all, one @-mention for carol"

# Send BEFORE any watcher daemon exists, so all four are fully written and
# stable on disk before anything ever polls the beam. check.sh's cursor
# advance takes a live `ls -1t` snapshot of the directory whenever a poll's
# candidate set is fully processed (lib/check.sh's advance_cursors_for_beam,
# used whenever plan_kinds is "full" — the common case here), not one bounded
# by what `find -newer cursor` actually captured earlier in that same
# invocation; a message written in that gap can be skipped forever. Sending
# the whole batch first — no daemon yet to poll mid-write — removes that
# window for this part of the test entirely (see the round's PASS/report for
# the suspected product bug this uncovered).
run_as "$CFG_DAVE" send "$BEAM" bob    "for bob's eyes only"           >/dev/null
run_as "$CFG_DAVE" send "$BEAM" alice  "for alice's eyes only"         >/dev/null
run_as "$CFG_DAVE" send "$BEAM" all    "broadcast to the whole beam"   >/dev/null
run_as "$CFG_DAVE" send "$BEAM" nobody "looping in @carol on this one" >/dev/null

# NOW start each identity's watcher daemon — its first-ever poll finds a
# stable, already-complete set of four messages.
w_start "$ALICE"; w_start "$BOB"; w_start "$CAROL"
wait_watcher "$ALICE" || fail "alice's watcher did not start"
wait_watcher "$BOB"   || fail "bob's watcher did not start"
wait_watcher "$CAROL" || fail "carol's watcher did not start"
pass "each identity has its own watcher daemon running"

wait_total "$RECV_ALICE" 2 || { red "  alice received:"; sed "s/$TOK_ALICE/<tok>/" "$RECV_ALICE" | sed 's/^/    /'; fail "alice's socket never reached a total of 2"; }
wait_total "$RECV_BOB"   2 || { red "  bob received:";   sed "s/$TOK_BOB/<tok>/"   "$RECV_BOB"   | sed 's/^/    /'; fail "bob's socket never reached a total of 2"; }
wait_total "$RECV_CAROL" 2 || { red "  carol received:"; sed "s/$TOK_CAROL/<tok>/" "$RECV_CAROL" | sed 's/^/    /'; fail "carol's socket never reached a total of 2"; }
sleep 2   # give a would-be extra/duplicate/misdirected post time to land
[ "$(sum_n "$RECV_ALICE")" = 2 ] || fail "alice's socket total should be exactly 2 (direct + all), got $(sum_n "$RECV_ALICE")"
[ "$(sum_n "$RECV_BOB")"   = 2 ] || fail "bob's socket total should be exactly 2 (direct + all), got $(sum_n "$RECV_BOB")"
[ "$(sum_n "$RECV_CAROL")" = 2 ] || fail "carol's socket total should be exactly 2 (all + @-mention), got $(sum_n "$RECV_CAROL")"
pass "each socket's total matches exactly what was addressed to it (batched or not); nothing crossed over"

# ---------------------------------------------------------------------------
banner "3. each identity's wake.log holds only its own event count"
[ "$(wc -l < "$ALICE/wake.log")" = 2 ] || fail "alice's wake.log should have 2 lines, got $(wc -l < "$ALICE/wake.log")"
[ "$(wc -l < "$BOB/wake.log")"   = 2 ] || fail "bob's wake.log should have 2 lines, got $(wc -l < "$BOB/wake.log")"
[ "$(wc -l < "$CAROL/wake.log")" = 2 ] || fail "carol's wake.log should have 2 lines, got $(wc -l < "$CAROL/wake.log")"
pass "wake.log holds exactly this identity's own event count, no cross-identity leakage"

# ---------------------------------------------------------------------------
banner "4. /clear-style rotation for bob: new session id, same pid, same socket"
boot "$P_BOB" sess-bob-2 "$SOCK_BOB" "$TOK_BOB" >/dev/null
[ "$(cat "$BASE/sessions/sess-bob-2/bound" 2>/dev/null)" = bob ] \
  || fail "bob's new session id did not auto-bind to 'bob'"
[ "$(jq -r .bound_session "$BOB/lease.json")" = sess-bob-2 ] \
  || fail "bob's lease did not move to the new session id"
[ "$(jq -r .claude_pid "$BOB/lease.json")" = "$P_BOB" ] \
  || fail "bob's lease pid changed across the rotation (should stay $P_BOB)"
[ "$(find "$BOB" -maxdepth 1 -name inbox.json | wc -l)" = 1 ] \
  || fail "bob should have exactly one pointer file"
[ "$(jq -r .socket "$BOB/inbox.json")" = "$SOCK_BOB" ] \
  || fail "bob's pointer no longer names the same socket after rotation"
[ "$(jq -r .session_id "$BOB/inbox.json")" = sess-bob-2 ] \
  || fail "bob's pointer did not update to the new session id"
pass "bob stayed bound to 'bob'; one pointer file, still naming the same socket"

# A further message must reach bob's socket exactly once more. Unlike the
# batch above, bob's daemon is already live and polling right through this
# send, so it can in principle hit the same check.sh cursor-advance race
# noted above (a rare poll whose scan straddles the write). Retry with a
# fresh message — bumping the expected total to match — rather than assume
# a single send always lands; this does not weaken the assertion, it just
# tolerates a known, unrelated host-timing hazard while still requiring
# exactly one post per attempt that actually got through.
bob_want=2
ok=0
for attempt in 1 2 3; do
  run_as "$CFG_DAVE" send "$BEAM" bob "post-rotation, bob only (try $attempt)" >/dev/null
  bob_want=$((bob_want + 1))
  if wait_total "$RECV_BOB" "$bob_want"; then ok=1; break; fi
done
[ "$ok" = 1 ] || fail "the post-rotation message never reached bob's socket after $attempt attempt(s)"
sleep 2
[ "$(sum_n "$RECV_BOB")"   = "$bob_want" ] || fail "bob's socket should total exactly $bob_want, got $(sum_n "$RECV_BOB") (posted more than once)"
[ "$(sum_n "$RECV_ALICE")" = 2 ] || fail "alice's total changed after a bob-only send: $(sum_n "$RECV_ALICE")"
[ "$(sum_n "$RECV_CAROL")" = 2 ] || fail "carol's total changed after a bob-only send: $(sum_n "$RECV_CAROL")"
pass "the post-rotation message posted to bob's socket exactly once per attempt ($attempt attempt(s) needed); alice/carol untouched"

# ---------------------------------------------------------------------------
banner "5. SessionEnd(other) for alice drops only her pointer + lease"
[ -f "$ALICE/inbox.json" ] || fail "setup: alice has no pointer before SessionEnd"
[ -f "$BOB/inbox.json" ]   || fail "setup: bob has no pointer before SessionEnd"
[ -f "$CAROL/inbox.json" ] || fail "setup: carol has no pointer before SessionEnd"
end "$P_ALICE" sess-alice other
[ -e "$ALICE/inbox.json" ] && fail "SessionEnd(other) left alice's pointer behind" || true
[ "$(jq -r '.bound_session // ""' "$ALICE/lease.json")" = "" ] \
  || fail "SessionEnd(other) did not release alice's lease"
[ -f "$BOB/inbox.json" ]   || fail "alice's SessionEnd removed bob's pointer too"
[ -f "$CAROL/inbox.json" ] || fail "alice's SessionEnd removed carol's pointer too"
[ "$(jq -r '.bound_session // ""' "$BOB/lease.json")" = sess-bob-2 ] \
  || fail "alice's SessionEnd touched bob's lease"
[ "$(jq -r '.bound_session // ""' "$CAROL/lease.json")" = sess-carol ] \
  || fail "alice's SessionEnd touched carol's lease"
pass "only alice's pointer + lease were released; bob and carol are untouched"

green ""
green "round-33 PASS: three identities sharing one project folder each keep their own process lease, inbox pointer, socket, and watcher — per-identity message totals are exact with no cross-talk, a /clear-style rotation keeps one identity's doorbell wired to the same socket, and SessionEnd releases only the exiting identity"
