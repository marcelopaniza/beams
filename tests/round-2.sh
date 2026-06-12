#!/usr/bin/env bash
# Round 2: tests for manager privileges (lock/unlock/kick/unkick) and the
# watcher daemon (with stub notifier). Self-contained — uses fresh tmpdir.
set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test2.XXXXXX)
SHARED="$TMPDIR/share"
CFG_A="$TMPDIR/cfg-a"
CFG_B="$TMPDIR/cfg-b"
CFG_C="$TMPDIR/cfg-c"
NOTIFY_LOG="$TMPDIR/notifier.log"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

# Stop any leftover watcher from prior runs (best effort).
cleanup() {
  for cfg in "$CFG_A" "$CFG_B" "$CFG_C"; do
    pf="$cfg/state/"*"/watcher.pid"
    for f in $pf; do
      [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
    done
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

run_as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
as_a() { run_as "$CFG_A" "$@"; }
as_b() { run_as "$CFG_B" "$@"; }
as_c() { run_as "$CFG_C" "$@"; }

hook_as() {
  ( export BEAMS_CONFIG_DIR="$1"; export CLAUDE_PLUGIN_ROOT="$PLUGIN";
    "$PLUGIN/hooks/check-messages.sh" </dev/null )
}
hook_a() { hook_as "$CFG_A"; }
hook_b() { hook_as "$CFG_B"; }
hook_c() { hook_as "$CFG_C"; }

mkdir -p "$SHARED"

# Stub notifier: invoked as `<cmd> <title> <body>`. Append to log.
cat > "$TMPDIR/notify-stub.sh" <<'EOF'
#!/usr/bin/env bash
printf 'NOTIFY|%s|%s\n' "$1" "$2" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMPDIR/notify-stub.sh"
export NOTIFY_LOG

banner "init three sessions: alice, bob, carol"
as_a init "$SHARED" >/dev/null
as_b init "$SHARED" >/dev/null
as_c init "$SHARED" >/dev/null
as_a name alice >/dev/null
as_b name bob   >/dev/null
as_c name carol >/dev/null
SID_A=$(jq -r '.session_id' "$CFG_A/config.json")
SID_B=$(jq -r '.session_id' "$CFG_B/config.json")
SID_C=$(jq -r '.session_id' "$CFG_C/config.json")
pass "alice=$SID_A bob=$SID_B carol=$SID_C"

# ── manager: carol creates the beam → carol is manager ─────────────────────
banner "carol creates 'team' beam and is manager"
as_c create team >/dev/null
as_c join team   >/dev/null
as_a join team   >/dev/null
as_b join team   >/dev/null
mgr=$(jq -r '(.driver // .manager)' "$SHARED/beams/team/manifest.json")
[ "$mgr" = "$SID_C" ] || fail "driver should be carol ($SID_C), got $mgr"
pass "carol owns the team beam"

# ── lock/unlock ───────────────────────────────────────────────────────────
banner "alice (non-manager) tries to lock → must fail"
if as_a lock team "no reason" >/dev/null 2>&1; then
  fail "alice should not be able to lock"
fi
pass "non-manager lock correctly refused"

banner "carol locks team with reason"
out=$(as_c lock team "release freeze")
echo "  $out"
jq -e '.locked.reason == "release freeze"' "$SHARED/beams/team/manifest.json" >/dev/null \
  || fail "lock manifest field missing or wrong"
pass "lock applied to manifest"

banner "alice tries to send → must fail with lock error"
if out=$(as_a send team carol "hi" 2>&1); then
  fail "alice's send should have failed; got: $out"
fi
case "$out" in *locked*) pass "send blocked with lock message" ;; *) fail "wrong error: $out" ;; esac

banner "carol (manager) can still send to locked beam"
out=$(as_c send team alice "manager override works")
echo "  $out"
sleep 1
ctx=$(hook_a | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$ctx" | grep -q "manager override works" || fail "alice missing manager override message"
pass "manager bypassed the lock"

banner "carol unlocks; alice can send again"
out=$(as_c unlock team)
echo "  $out"
jq -e '.locked == null' "$SHARED/beams/team/manifest.json" >/dev/null \
  || fail "unlock should have removed .locked"
sleep 1
out=$(as_a send team carol "thanks for unlocking")
echo "  $out"
pass "unlock restored send for non-managers"

# ── kick/unkick ───────────────────────────────────────────────────────────
banner "alice (non-manager) tries to kick → must fail"
if as_a kick team bob "no reason" >/dev/null 2>&1; then
  fail "alice should not be able to kick"
fi
pass "non-manager kick refused"

banner "carol kicks bob"
sleep 1
out=$(as_c kick team bob "stop spamming")
echo "  $out"
[ ! -f "$SHARED/beams/team/members/$SID_B.json" ] || fail "bob's member record should be gone"
jq -e --arg b "$SID_B" '.banned | index($b) != null' "$SHARED/beams/team/manifest.json" >/dev/null \
  || fail "bob's UUID not in banlist"
pass "bob removed from members and banlist updated"

banner "bob tries to send → must fail (banned)"
if out=$(as_b send team carol "let me back" 2>&1); then
  fail "bob's send should have failed; got: $out"
fi
case "$out" in *kicked*|*banned*) pass "banned send refused" ;; *) fail "wrong error: $out" ;; esac

banner "bob tries to rejoin → must fail (banned)"
if out=$(as_b join team 2>&1); then
  fail "bob's join should have failed; got: $out"
fi
case "$out" in *kicked*|*banned*) pass "banned join refused" ;; *) fail "wrong error: $out" ;; esac

banner "bob receives the kick-notice via hook"
sleep 1
ctx=$(hook_b | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$ctx" | grep -qi "kicked" || fail "bob's hook should have surfaced the kick notice"
pass "kick-notice delivered to bob"

banner "carol unkicks bob; bob can rejoin and send"
out=$(as_c unkick team "$SID_B")
echo "  $out"
jq -e --arg b "$SID_B" '.banned // [] | index($b) == null' "$SHARED/beams/team/manifest.json" >/dev/null \
  || fail "bob still in banlist after unkick"
out=$(as_b join team)
echo "  $out"
sleep 1
out=$(as_b send team carol "back online")
echo "  $out"
pass "unkick restored bob"

# ── members.sh shows role + ban ────────────────────────────────────────────
banner "members.sh shows manager role"
m=$(as_c members team)
echo "$m" | grep -E "$SID_C\s.*\s+driver" >/dev/null || fail "carol should be marked driver in members"
pass "members listing marks the driver"

# ── watcher: start, fire notification via stub, stop ──────────────────────
banner "alice starts watcher with stub notifier (1s interval)"
sleep 1
export BEAMS_NOTIFIER_CMD="$TMPDIR/notify-stub.sh"
out=$( BEAMS_CONFIG_DIR="$CFG_A" BEAMS_NOTIFIER_CMD="$BEAMS_NOTIFIER_CMD" \
       "$PLUGIN/lib/watch.sh" start 1 )
echo "  $out"
echo "$out" | grep -q "watcher started" || fail "watcher did not report started"

# Find PID file under cfg-a/state/*/watcher.pid
pid_file=$(ls "$CFG_A/state"/*/watcher.pid 2>/dev/null | head -1)
[ -n "$pid_file" ] && [ -f "$pid_file" ] || fail "watcher pid file missing"
pid=$(cat "$pid_file")
kill -0 "$pid" 2>/dev/null || fail "watcher pid $pid is not alive"
pass "watcher running pid=$pid"

banner "alice's /beams:watch status reports RUNNING"
status_out=$( BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" status )
echo "$status_out" | grep -q "RUNNING" || fail "status didn't say RUNNING"
echo "$status_out" | grep -q "$pid"    || fail "status missing pid"
pass "status reports RUNNING with correct pid"

banner "carol sends to alice; watcher should fire notification"
> "$NOTIFY_LOG"
sleep 1
as_c send team alice "watcher should ping" >/dev/null
# Wait for notifier to fire (interval=1s + slack)
for i in 1 2 3 4 5 6; do
  sleep 1
  grep -q "watcher should ping" "$NOTIFY_LOG" 2>/dev/null && break
done
grep -q "watcher should ping" "$NOTIFY_LOG" || {
  red "  notify log contents:"
  cat "$NOTIFY_LOG" 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
  red "  watcher log tail:"
  tail -n 20 "$CFG_A/state"/*/watcher.log 2>/dev/null | sed 's/^/    /' || true
  fail "notifier was never invoked"
}
grep -q "beams: carol on team" "$NOTIFY_LOG" || fail "notify title missing 'carol on team'"
pass "watcher fired desktop notification with correct content"

banner "verify hook cursor not advanced — alice's next prompt still gets the message"
ctx=$(hook_a | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$ctx" | grep -q "watcher should ping" \
  || fail "hook should still see the message after the watcher notified — got: $ctx"
pass "hook delivery independent of watcher notification"

banner "after hook delivery, watcher should NOT re-notify (both cursors advanced)"
> "$NOTIFY_LOG"
sleep 2
[ ! -s "$NOTIFY_LOG" ] || {
  red "  notify log after hook flush:"
  cat "$NOTIFY_LOG"
  fail "watcher re-notified for a message the hook already delivered"
}
pass "no re-notification after hook delivery"

banner "alice's /beams:watch stop"
out=$( BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop )
echo "  $out"
sleep 0.5
kill -0 "$pid" 2>/dev/null && fail "watcher pid $pid still alive after stop"
[ -f "$pid_file" ] && fail "pid file should be removed after stop"
pass "watcher stopped cleanly"

banner "starting watcher twice is idempotent"
BEAMS_CONFIG_DIR="$CFG_A" BEAMS_NOTIFIER_CMD="$BEAMS_NOTIFIER_CMD" \
  "$PLUGIN/lib/watch.sh" start 1 >/dev/null
out=$( BEAMS_CONFIG_DIR="$CFG_A" BEAMS_NOTIFIER_CMD="$BEAMS_NOTIFIER_CMD" \
       "$PLUGIN/lib/watch.sh" start 1 )
echo "  $out"
echo "$out" | grep -q "already running" || fail "second start should report already running"
BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop >/dev/null
pass "second start is idempotent"

green ""
green "ALL ROUND-2 TESTS PASSED"
