#!/usr/bin/env bash
# Round 15: regression for `--on-message <cmd>` on /beams:watch (v0.8.0).
#
# Verifies:
#   1. Each new message addressed to us fires the user's cmd ONCE.
#   2. BEAMS_BEAM / BEAMS_FROM / BEAMS_PREVIEW are exported correctly.
#   3. Multi-word quoted cmds survive the slash-command arg pipeline
#      (i.e. lib/watch.sh's special-case parser preserves them).
#   4. A non-zero exit from the user cmd does NOT crash the daemon; the
#      exit code is logged to on-message.log and the next message still
#      dispatches.
#   5. The cmd is NOT persisted: a `restart` without --on-message clears
#      it (next message → no dispatch).
#   6. `/beams:watch status` reports on-message=ACTIVE / off correctly.
#
# Self-contained — own tmpdir, two sessions on the same shared folder.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test-r15.XXXXXX)
SHARED="$TMPDIR/share"
CFG_A="$TMPDIR/cfg-a"
CFG_B="$TMPDIR/cfg-b"
OM_MARKER="$TMPDIR/on-message-marker.log"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() {
  for cfg in "$CFG_A" "$CFG_B"; do
    for f in "$cfg"/state/*/watcher.pid; do
      [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
    done
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

run_as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
as_a() { run_as "$CFG_A" "$@"; }
as_b() { run_as "$CFG_B" "$@"; }

# Drive lib/watch.sh exactly the way commands/watch.md does — a single
# whitespace-joined arg, so the arg-parser's special-case for --on-message
# is exercised end-to-end.
watch_a() {
  ( export BEAMS_CONFIG_DIR="$CFG_A"; "$PLUGIN/lib/watch.sh" "$*" )
}

mkdir -p "$SHARED"

banner "init two sessions: alice (recipient), bob (sender)"
as_a init "$SHARED" >/dev/null
as_b init "$SHARED" >/dev/null
as_a name alice >/dev/null
as_b name bob   >/dev/null
as_b create r15-beam >/dev/null
as_b join   r15-beam >/dev/null
as_a join   r15-beam >/dev/null
pass "alice and bob on beam r15-beam"

# ── 1. multi-word --on-message survives arg parsing ────────────────────────
banner "alice starts watcher with --on-message (multi-word cmd, single quoted)"

# This is the cmd we want the daemon to run on each new message. It echoes
# the env vars into a marker file separated by | so we can grep.
OM_CMD="printf '%s|%s|%s\n' \"\$BEAMS_BEAM\" \"\$BEAMS_FROM\" \"\$BEAMS_PREVIEW\" >> \"$OM_MARKER\""

> "$OM_MARKER"
# Pass exactly the way the slash command would: whitespace-joined single arg.
out=$( BEAMS_CONFIG_DIR="$CFG_A" \
       "$PLUGIN/lib/watch.sh" "start 1 --on-message $OM_CMD" )
echo "  $out"
echo "$out" | grep -q "on-message=ACTIVE" \
  || fail "start output should mention on-message=ACTIVE; got: $out"

pid_file=$(ls "$CFG_A/state"/*/watcher.pid 2>/dev/null | head -1)
[ -n "$pid_file" ] && [ -f "$pid_file" ] || fail "watcher pid file missing"
pid=$(cat "$pid_file")
kill -0 "$pid" 2>/dev/null || fail "watcher pid $pid is not alive"
pass "watcher running pid=$pid with --on-message active"

# ── 2. dispatch fires with correct env vars ────────────────────────────────
banner "bob sends to alice → on-message should fire once with BEAMS_* env"
sleep 1
as_b send r15-beam alice "round 15 — automation works" >/dev/null

# Wait for the daemon's poll (1s) + dispatch + write to marker
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  [ -s "$OM_MARKER" ] && grep -q "round 15 — automation works" "$OM_MARKER" 2>/dev/null && break
done

if ! grep -q "round 15 — automation works" "$OM_MARKER" 2>/dev/null; then
  red "  on-message marker contents:"
  cat "$OM_MARKER" 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
  red "  watcher.log tail:"
  tail -n 30 "$CFG_A/state"/*/watcher.log 2>/dev/null | sed 's/^/    /' || true
  red "  on-message.log tail:"
  tail -n 30 "$CFG_A/state"/*/on-message.log 2>/dev/null | sed 's/^/    /' || true
  fail "on-message dispatch did not fire (or didn't see BEAMS_PREVIEW)"
fi

# Parse marker line: <beam>|<from>|<preview>
line=$(grep "round 15 — automation works" "$OM_MARKER" | tail -1)
beam_got="${line%%|*}"
rest="${line#*|}"
from_got="${rest%%|*}"
preview_got="${rest#*|}"

[ "$beam_got"  = "r15-beam" ] || fail "BEAMS_BEAM=$beam_got expected r15-beam"
[ "$from_got" = "bob"     ] || fail "BEAMS_FROM=$from_got expected bob"
case "$preview_got" in
  *"round 15 — automation works"*) : ;;
  *) fail "BEAMS_PREVIEW missing body text: $preview_got" ;;
esac
pass "dispatch fired once with BEAMS_BEAM=r15-beam BEAMS_FROM=bob BEAMS_PREVIEW correct"

# ── 3. /beams:watch status reports on-message=ACTIVE ───────────────────────
banner "/beams:watch status reports on-message=ACTIVE"
status_out=$( BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" status )
echo "$status_out" | grep -qE 'on-message:\s+ACTIVE' \
  || { red "  status output:"; echo "$status_out" | sed 's/^/    /'; fail "status missing on-message=ACTIVE"; }
pass "status surface reports ACTIVE"

# ── 4. non-zero exit doesn't crash the daemon; subsequent dispatch ok ──────
banner "restart with cmd that exits non-zero; daemon survives; exit logged"
BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop >/dev/null
> "$OM_MARKER"

# `bash -c "exit 7"` returns 7 → daemon should log and continue.
FAIL_CMD="printf '%s\n' \"\$BEAMS_FROM-saw-msg\" >> \"$OM_MARKER\"; exit 7"
BEAMS_CONFIG_DIR="$CFG_A" \
  "$PLUGIN/lib/watch.sh" "start 1 --on-message $FAIL_CMD" >/dev/null

# Need new pid_file path since restart re-creates state
pid_file=$(ls "$CFG_A/state"/*/watcher.pid 2>/dev/null | head -1)
pid=$(cat "$pid_file")

sleep 1
as_b send r15-beam alice "fail-cmd-msg-1" >/dev/null
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  grep -q "bob-saw-msg" "$OM_MARKER" 2>/dev/null && break
done
grep -q "bob-saw-msg" "$OM_MARKER" || fail "failing cmd: side effect missing"
kill -0 "$pid" 2>/dev/null || fail "daemon died after non-zero exit cmd"

# Exit code 7 should appear in on-message.log
om_log=$(ls "$CFG_A/state"/*/on-message.log 2>/dev/null | head -1)
[ -n "$om_log" ] && [ -f "$om_log" ] || fail "on-message.log missing"
grep -q "on-message exit=7" "$om_log" || {
  red "  on-message.log:"; cat "$om_log" | sed 's/^/    /'
  fail "on-message.log missing 'exit=7' entry"
}
pass "daemon survived non-zero exit; exit=7 logged"

# Second message should also dispatch (daemon healthy)
sleep 1
as_b send r15-beam alice "fail-cmd-msg-2" >/dev/null
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  [ "$(grep -c bob-saw-msg "$OM_MARKER" 2>/dev/null || echo 0)" -ge 2 ] && break
done
n_fires=$(grep -c bob-saw-msg "$OM_MARKER" 2>/dev/null || echo 0)
[ "$n_fires" -ge 2 ] || fail "expected 2 fires after non-zero exit; got $n_fires"
pass "subsequent dispatch still works ($n_fires fires total)"

# ── 5. no-persistence: restart without --on-message → no dispatch ──────────
banner "restart without --on-message clears the cmd (no dispatch on next msg)"
BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop >/dev/null
> "$OM_MARKER"

BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" "start 1" >/dev/null
sleep 1
as_b send r15-beam alice "after-clear-msg" >/dev/null
sleep 4
# After 4s of poll cycles, marker should still be empty — the cmd was cleared.
if [ -s "$OM_MARKER" ]; then
  red "  unexpected marker contents:"
  cat "$OM_MARKER" | sed 's/^/    /'
  fail "restart without --on-message should have cleared the dispatcher"
fi

# And /beams:watch status should now say on-message=off
status_out=$( BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" status )
echo "$status_out" | grep -qE 'on-message:\s+off' \
  || { red "  status output:"; echo "$status_out" | sed 's/^/    /'; fail "status missing on-message=off"; }
pass "restart cleared --on-message and status reflects it"

BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop >/dev/null

# ── 6. --on-message with a wrong subcommand is rejected ────────────────────
banner "--on-message with 'status' subcommand is rejected loudly"
if ( BEAMS_CONFIG_DIR="$CFG_A" \
     "$PLUGIN/lib/watch.sh" "status --on-message foo" ) >/dev/null 2>&1; then
  fail "should have rejected --on-message on 'status'"
fi
pass "--on-message rejected outside start/restart"

# ── 7. --on-message with an empty cmd is rejected (not silently discarded) ─
banner "--on-message with empty cmd is rejected"
if ( BEAMS_CONFIG_DIR="$CFG_A" \
     "$PLUGIN/lib/watch.sh" "start 1 --on-message " ) >/dev/null 2>&1; then
  fail "should have rejected --on-message with empty value"
fi
# Also via direct argv (different parser branch)
if ( BEAMS_CONFIG_DIR="$CFG_A" \
     "$PLUGIN/lib/watch.sh" start 1 --on-message "" ) >/dev/null 2>&1; then
  fail "should have rejected --on-message '' via direct argv"
fi
pass "empty --on-message rejected via both arg paths"

# ── 8. body bytes don't reach the cmd as argv — only env vars ──────────────
# Security-critical contract: a future refactor that accidentally passes
# body content as positional args would open the same RCE class as v0.7.3's
# heredoc bug. This test would catch that regression.
banner "body content does NOT leak into argv (env-only contract)"
ARGV_MARKER="$TMPDIR/argv-marker.log"
> "$ARGV_MARKER"
# Cmd writes its full argv list (should be empty) plus env-derived preview.
ARGV_CMD="printf 'argc=%s argv=[%s]\n' \"\$#\" \"\$*\" >> \"$ARGV_MARKER\""
BEAMS_CONFIG_DIR="$CFG_A" \
  "$PLUGIN/lib/watch.sh" "start 1 --on-message $ARGV_CMD" >/dev/null
sleep 1
as_b send r15-beam alice "body-as-argv-attempt" >/dev/null
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  [ -s "$ARGV_MARKER" ] && break
done
[ -s "$ARGV_MARKER" ] || fail "cmd never fired"
line=$(head -1 "$ARGV_MARKER")
[ "$line" = "argc=0 argv=[]" ] || {
  red "  argv marker:"; cat "$ARGV_MARKER" | sed 's/^/    /'
  fail "body leaked into argv — expected 'argc=0 argv=[]', got '$line'"
}
pass "cmd sees argc=0 — body content does not reach as argv"
BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop >/dev/null

# ── 9. C0 control chars in body are stripped from BEAMS_PREVIEW ────────────
# A malicious body containing ANSI escapes (\033...) would poison logs and
# hijack terminals on anyone who `cat`s on-message.log. lib/check.sh --notify
# and lib/watcher_daemon.sh dispatch_on_message both strip C0+DEL.
banner "ANSI/C0 chars in body are stripped before reaching BEAMS_PREVIEW"
ANSI_MARKER="$TMPDIR/ansi-marker.log"
> "$ANSI_MARKER"
# Dump preview as hex; verify no 0x1b (ESC), 0x09 (TAB), or 0x07 (BEL) bytes.
ANSI_CMD="printf '%s' \"\$BEAMS_PREVIEW\" | od -An -tx1 -v >> \"$ANSI_MARKER\""
BEAMS_CONFIG_DIR="$CFG_A" \
  "$PLUGIN/lib/watch.sh" "start 1 --on-message $ANSI_CMD" >/dev/null

# Body with ESC sequence (clear-line + cursor-up), TAB, BEL, and DEL.
HOSTILE=$'PRE\x1b[2K\x1b[1A\x07\x09\x7fPOST'
sleep 1
as_b send r15-beam alice "$HOSTILE" >/dev/null
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  [ -s "$ANSI_MARKER" ] && break
done
[ -s "$ANSI_MARKER" ] || fail "ANSI test cmd never fired"
hex=$(tr -d ' \n' < "$ANSI_MARKER")
# After stripping: should still contain 50 52 45 (PRE) and 50 4f 53 54 (POST)
# but NOT 1b, 07, 09, 7f.
case "$hex" in
  *1b*) fail "ESC byte (0x1b) survived in BEAMS_PREVIEW: $hex" ;;
  *07*) fail "BEL byte (0x07) survived in BEAMS_PREVIEW: $hex" ;;
  *09*) fail "TAB byte (0x09) survived in BEAMS_PREVIEW: $hex" ;;
  *7f*) fail "DEL byte (0x7f) survived in BEAMS_PREVIEW: $hex" ;;
esac
# Visible text must survive (PRE = 50 52 45, POST = 50 4f 53 54).
case "$hex" in *505245*)   : ;; *) fail "PRE text missing — strip too aggressive: $hex" ;; esac
case "$hex" in *504f5354*) : ;; *) fail "POST text missing — strip too aggressive: $hex" ;; esac
pass "C0+DEL stripped from BEAMS_PREVIEW; visible text preserved"
BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop >/dev/null

# ── 10. inflight cap kicks in on burst, no crash, daemon survives ──────────
# Reasonably fast: set MAX_INFLIGHT=2 + a 3-sec sleep cmd; send 5 messages in
# one burst; expect at most 2 fired immediately, the rest logged as SKIPPED.
banner "inflight cap throttles message burst (SKIPPED logged, daemon alive)"
BURST_MARKER="$TMPDIR/burst-marker.log"
> "$BURST_MARKER"
BURST_CMD="printf '%s\n' \"\$BEAMS_PREVIEW\" >> \"$BURST_MARKER\"; sleep 3"
BEAMS_ON_MESSAGE_MAX_INFLIGHT=2 BEAMS_CONFIG_DIR="$CFG_A" \
  "$PLUGIN/lib/watch.sh" "start 1 --on-message $BURST_CMD" >/dev/null

pid_file=$(ls "$CFG_A/state"/*/watcher.pid 2>/dev/null | head -1)
pid=$(cat "$pid_file")

# Burst 5 messages back-to-back (no inter-send delay)
for n in 1 2 3 4 5; do
  as_b send r15-beam alice "burst-msg-$n" >/dev/null
done

# Wait one poll cycle so all 5 hit the daemon in one read-while pass.
sleep 2

# Daemon must still be alive
kill -0 "$pid" 2>/dev/null || fail "daemon died during burst"

# on-message.log must contain at least one SKIPPED entry (inflight cap hit)
om_log=$(ls "$CFG_A/state"/*/on-message.log 2>/dev/null | head -1)
[ -n "$om_log" ] && grep -q "on-message SKIPPED" "$om_log" || {
  red "  on-message.log:"; cat "$om_log" 2>/dev/null | sed 's/^/    /'
  fail "no SKIPPED entries — inflight cap didn't kick in"
}
pass "burst throttled (SKIPPED logged); daemon survived"
BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop >/dev/null

# ── 11. on-message.log as a symlink → dispatch disabled (no follow) ────────
# Defence against a same-UID peer planting on-message.log as a symlink to a
# victim-owned file (e.g. ~/.ssh/authorized_keys) so dispatch output appends
# attacker-influenced bytes there.
banner "on-message.log symlink → dispatch disabled, watcher.log warns"
> "$TMPDIR/symlink-victim.log"
sid_dir=$(ls -d "$CFG_A/state"/*/ 2>/dev/null | head -1)
ln -sf "$TMPDIR/symlink-victim.log" "${sid_dir}on-message.log"

# Verify the symlink is there
[ -L "${sid_dir}on-message.log" ] || fail "test setup: symlink not in place"

> "$OM_MARKER"
BEAMS_CONFIG_DIR="$CFG_A" \
  "$PLUGIN/lib/watch.sh" "start 1 --on-message $OM_CMD" >/dev/null
sleep 1
as_b send r15-beam alice "symlink-attack-msg" >/dev/null
sleep 3

# Victim file must remain empty
[ ! -s "$TMPDIR/symlink-victim.log" ] || {
  red "  victim file (should be empty):"
  cat "$TMPDIR/symlink-victim.log" | sed 's/^/    /'
  fail "symlink was followed — daemon wrote to victim file"
}

# Marker file (the legitimate dispatch target) must also be empty — dispatch
# was disabled at startup, not just redirected.
[ ! -s "$OM_MARKER" ] || {
  red "  OM_MARKER (should be empty):"
  cat "$OM_MARKER" | sed 's/^/    /'
  fail "dispatch ran despite symlink — should have been disabled"
}

# watcher.log must contain the WARN
grep -q "on-message.log is a symlink" "$CFG_A/state"/*/watcher.log \
  || fail "watcher.log missing symlink WARN"
pass "symlink detected; dispatch disabled; victim file untouched"
BEAMS_CONFIG_DIR="$CFG_A" "$PLUGIN/lib/watch.sh" stop >/dev/null
rm -f "${sid_dir}on-message.log"  # clean up symlink for trap

green ""
green "round-15 PASS: --on-message dispatch (v0.8.0)"
