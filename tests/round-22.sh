#!/usr/bin/env bash
# Round 22 — security regressions for the v0.10.2 pentest fixes:
#   A. kick refuses a path-traversal ".id" planted in a member record
#      (resolve_member must only ever return a bare UUID).
#   B. a poisoned "-1" watcher pid reads as NOT RUNNING, so /beams:watch can
#      never escalate to `kill -TERM/-KILL -1` (signal every process we own).
#   C. the watcher writes its pid via rename, never THROUGH a planted symlink.
#   D. a far-future-dated junk .msg cannot freeze the cursor (denial of delivery).
#   E. lib/on-message.sh exits promptly when wake.log is a FIFO (no hang).

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r22.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg" HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
export BEAMS_DISABLE_WATCH_ON_BOOT=1
export BEAMS_NOTIFIER_CMD=true        # no real desktop notifications from the daemon
SHARED="$TMP/share"; mkdir -p "$SHARED"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

WPID=""
cleanup() { [ -n "$WPID" ] && kill "$WPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

run() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }

# ── setup: driver sess-A ('alice') creates and joins beam 'work' ────────────
run sess-A init "$SHARED" >/dev/null
run sess-A name alice      >/dev/null
run sess-A join work       >/dev/null
BEAM_DIR="$SHARED/beams/work"
MEMBERS="$BEAM_DIR/members"
[ -d "$MEMBERS" ] || fail "setup: no members dir at $MEMBERS"

# ── A. kick refuses a traversal .id ─────────────────────────────────────────
banner "A. kick refuses a path-traversal .id in a planted member record"
SENTINEL="$TMP/sentinel.json"; echo keep > "$SENTINEL"
# members dir is $SHARED/beams/work/members → ../../../../ climbs to $TMP.
jq -n '{id:"../../../../sentinel", name:"victim", host:"x", last_seen:0}' \
  > "$MEMBERS/deadbeef-0000-0000-0000-000000000000.json"
run sess-A kick work victim >/tmp/r22-kick.out 2>&1 || true
[ -f "$SENTINEL" ] || fail "kick followed the traversal .id and deleted $SENTINEL"
grep -q 'no member named' /tmp/r22-kick.out || fail "expected kick to reject the bad record; got: $(cat /tmp/r22-kick.out)"
pass "kick rejected the traversal .id; sentinel survived"

# ── B. poisoned '-1' pid reads as NOT RUNNING (kill -1 path unreachable) ─────
banner "B. a poisoned '-1' watcher pid is treated as NOT RUNNING"
run sess-A watch start 5 >/tmp/r22-w.out 2>&1 || fail "watch start failed: $(cat /tmp/r22-w.out)"
PIDFILE=$(run sess-A watch status 2>/dev/null | sed -n 's/.*pid_file: *//p' | head -1)
[ -n "$PIDFILE" ] || fail "could not learn pid_file path from watch status"
WPID=$(cat "$PIDFILE" 2>/dev/null || echo "")
run sess-A watch stop >/dev/null 2>&1 || true
printf -- '-1\n' > "$PIDFILE"
status=$(run sess-A watch status 2>/dev/null || true)
printf '%s' "$status" | grep -q 'NOT RUNNING' \
  || fail "is_alive accepted a '-1' pid (status said: $status) — kill -1 reachable"
pass "a '-1' pid file reads as NOT RUNNING (is_alive rejects non-positive pids)"

# ── C. pid write goes via rename, never through a planted symlink ───────────
banner "C. the watcher writes its pid via rename, never through a symlink"
PIDVICTIM="$TMP/pid-victim"; echo original > "$PIDVICTIM"
ln -sf "$PIDVICTIM" "$PIDFILE"     # pre-plant the pid path as a symlink to the victim
run sess-A watch start 5 >/tmp/r22-w2.out 2>&1 || fail "watch start (symlink case) failed: $(cat /tmp/r22-w2.out)"
sleep 0.6
WPID=$(cat "$PIDFILE" 2>/dev/null || echo "")
[ "$(cat "$PIDVICTIM" 2>/dev/null)" = original ] \
  || fail "watcher wrote its pid THROUGH the symlink, clobbering $PIDVICTIM"
[ ! -L "$PIDFILE" ] || fail "pid_file is still a symlink — rename did not replace it"
run sess-A watch stop >/dev/null 2>&1 || true; WPID=""
pass "watcher replaced the planted symlink with a regular pid file; victim untouched"

# ── D. a future-dated junk .msg cannot freeze delivery ──────────────────────
banner "D. a far-future junk .msg cannot freeze the cursor (denial of delivery)"
run sess-B init "$SHARED" >/dev/null
run sess-B name bob        >/dev/null
run sess-B join work       >/dev/null
mkdir -p "$BEAM_DIR/messages"
JUNK="$BEAM_DIR/messages/29991231235959__junkjunk.msg"
printf 'id: not-a-uuid\nbeam: work\n' > "$JUNK"
touch -t 209912312359 "$JUNK" 2>/dev/null || touch -d '2099-12-31T23:59:59' "$JUNK"
# First pull as alice: this is where a future "latest" would poison her cursor.
run sess-A check --hook >/dev/null 2>&1 || true
# Now bob sends a real signed message to alice; she must still receive it.
run sess-B send work alice "hello from bob" >/dev/null 2>&1 || fail "bob's send failed"
out=$(run sess-A check --hook 2>/dev/null || true)
printf '%s' "$out" | grep -q 'hello from bob' \
  || fail "future-dated junk froze the cursor — bob's message was never delivered"
pass "legit message delivered despite a year-2099 junk file (cursor clamped to now)"

# ── E. on-message.sh does not hang on a FIFO wake file ──────────────────────
banner "E. lib/on-message.sh exits promptly when wake.log is a FIFO"
if command -v timeout >/dev/null 2>&1; then
  OMCFG="$TMP/om-fifo-cfg"; mkdir -p "$OMCFG"
  mkfifo "$OMCFG/wake.log"
  BEAMS_CONFIG_DIR="$OMCFG" \
    BEAMS_BEAM=all BEAMS_FROM=z BEAMS_PREVIEW=hi \
    timeout 5 bash "$PLUGIN/lib/on-message.sh"; rc=$?
  [ "$rc" -ne 124 ] || fail "on-message.sh hung on a FIFO wake file (timed out)"
  [ "$rc" -eq 0 ]   || fail "on-message.sh exited rc=$rc on a FIFO wake file (want silent 0)"
  [ -p "$OMCFG/wake.log" ] || fail "on-message.sh replaced or wrote through the FIFO"
  pass "on-message.sh refused the FIFO wake file promptly (rc=$rc)"
else
  echo "  (skipped — no 'timeout' on this host)"
fi

green ""
green "round-22 PASS: kick rejects traversal ids; watcher pid is symlink-safe and refuses non-positive pids; future-dated junk can't freeze the cursor; on-message.sh won't hang on a FIFO"
