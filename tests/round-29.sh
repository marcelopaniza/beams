#!/usr/bin/env bash
# Round 29 — the doorbell arms when you JOIN, not just at the next restart:
# lib/join.sh, lib/name.sh, and a profile init call beams::doorbell_autostart,
# which (a) starts the watcher armed with the wake-file hook (idempotent
# `start`) and (b) prints the Monitor-arm instruction into the command output
# — so the very session that ran /beams:start or "join beams as <name>" goes
# real-time immediately. The open-reader probe (fuser/lsof on wake.log)
# suppresses the instruction when a live monitor already tails the file (a
# /clear keeps the process and its monitors; only the context is wiped).
# Cases:
#   A. wizard flow: bare init emits NO doorbell block; name (create/bind)
#      emits it; join emits it too; watcher comes up on-message=ACTIVE
#   B. a live reader on wake.log (the /clear-survivor stand-in) → rename and
#      join emit NO doorbell block; watcher untouched
#   C. BEAMS_DISABLE_WATCH_ON_BOOT=1 → join: no instruction, no watcher
#   D. react.watch_on_boot=false → join: no instruction, no watcher
#   E. no CLAUDE_CODE_SESSION_ID (cross-CLI, explicit BEAMS_CONFIG_DIR) →
#      join starts the watcher but emits NO instruction (no Monitor tool there)
#   F. init --profile responder → instruction is in the (visible) init output,
#      carries the RESPONDER reply clause; watcher on-message=ACTIVE
#   G. /beams:status shows doorbell ground truth: "NOT armed" with no reader,
#      "armed (wake.log reader pid N)" while something tails wake.log

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r29.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg" HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR
export BEAMS_NOTIFIER_CMD=true        # no real desktop notifications
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # positive cases unset this per-call
SHARED="$TMP/share"; mkdir -p "$SHARED"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

TAIL_PID=""
cleanup() {
  [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
  local f
  for f in "$XDG_CONFIG_HOME"/beams/projects/*/identities/*/state/*/watcher.pid \
           "$XDG_CONFIG_HOME"/beams/sessions/*/state/*/watcher.pid \
           "$TMP"/cfg-*/state/*/watcher.pid; do
    [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# runas <claude-session-id> <lib> [args…] — doorbell autostart ENABLED.
runas()  { ( unset BEAMS_CONFIG_DIR BEAMS_DISABLE_WATCH_ON_BOOT
             export CLAUDE_CODE_SESSION_ID="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
# run_as <config-dir> <lib> [args…] — no Claude session id (cross-CLI shape).
run_as() { ( unset CLAUDE_CODE_SESSION_ID BEAMS_DISABLE_WATCH_ON_BOOT
             export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }

# wait_watcher <identity-dir> [want] — poll up to 5s for the watcher pid file
# (the autostart is detached; watch.sh itself sleeps 0.4s before validating).
wait_watcher() {
  local dir="$1" i pf
  for i in $(seq 1 25); do
    for pf in "$dir"/state/*/watcher.pid; do
      [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && return 0
    done
    sleep 0.2
  done
  return 1
}

# ---------------------------------------------------------------------------
banner "A. wizard flow: init silent, name arms + instructs, join instructs"
out=$(runas s29a init "$SHARED")
printf '%s' "$out" | grep -q 'beams: initialised' || fail "init failed: $out"
printf '%s' "$out" | grep -q 'beams doorbell' \
  && fail "bare init must NOT emit the doorbell block (name/join own that)"
pass "bare init emits no doorbell block"

out=$(runas s29a name ringo)
printf '%s' "$out" | grep -q 'beams doorbell'        || fail "name did not emit the doorbell block: $out"
printf '%s' "$out" | grep -q 'Monitor'               || fail "instruction does not name the Monitor tool"
printf '%s' "$out" | grep -q 'beams doorbell (ringo)' || fail "instruction missing the session name"
IDDIR="$XDG_CONFIG_HOME/beams/projects"/*/identities/ringo
IDDIR=$(echo $IDDIR)
[ -d "$IDDIR" ] || fail "identity dir not found"
printf '%s' "$out" | grep -qF "$IDDIR/wake.log"      || fail "instruction missing the wake.log path"
[ -f "$IDDIR/wake.log" ]                             || fail "wake.log was not created"
pass "name → bind emits the arm instruction + creates wake.log"

out=$(runas s29a join all)
printf '%s' "$out" | grep -q 'beams: joined "all"'   || fail "join failed: $out"
printf '%s' "$out" | grep -q 'beams doorbell' \
  || fail "join did not emit the doorbell block (no live reader yet): $out"
wait_watcher "$IDDIR" || fail "watcher did not come up after name/join"
st=$(run_as "$IDDIR" watch status)
printf '%s' "$st" | grep -q 'watcher RUNNING'        || fail "watcher not RUNNING: $st"
printf '%s' "$st" | grep -q 'on-message: ACTIVE'     || fail "watcher missing the wake-file hook: $st"
pass "join re-offers the instruction; watcher RUNNING with on-message=ACTIVE"

# ---------------------------------------------------------------------------
banner "B. a live wake.log reader suppresses the instruction (the /clear case)"
if command -v fuser >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1; then
  tail -n 0 -F "$IDDIR/wake.log" >/dev/null 2>&1 &
  TAIL_PID=$!
  sleep 0.3   # let tail open the file
  out=$(runas s29a name ringo)   # plain-rename fast path
  printf '%s' "$out" | grep -q 'beams doorbell' \
    && fail "rename re-emitted the instruction despite a live reader"
  out=$(runas s29a join second-beam)
  printf '%s' "$out" | grep -q 'beams: joined "second-beam"' || fail "join failed: $out"
  printf '%s' "$out" | grep -q 'beams doorbell' \
    && fail "join re-emitted the instruction despite a live reader"
  kill "$TAIL_PID" 2>/dev/null || true; wait "$TAIL_PID" 2>/dev/null || true; TAIL_PID=""
  pass "live reader on wake.log → no duplicate doorbell instruction"
else
  pass "SKIPPED (neither fuser nor lsof on this box)"
fi

# ---------------------------------------------------------------------------
banner "C. BEAMS_DISABLE_WATCH_ON_BOOT=1 → join arms nothing"
( export CLAUDE_CODE_SESSION_ID=s29c; unset BEAMS_CONFIG_DIR
  "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null
  "$PLUGIN/lib/name.sh" mute >/dev/null
  out=$("$PLUGIN/lib/join.sh" all)
  printf '%s' "$out" | grep -q 'beams doorbell' \
    && { red "FAIL: instruction emitted despite the env opt-out"; exit 1; }
  exit 0
) || fail "case C inner check failed"
MUTEDIR=$(echo "$XDG_CONFIG_HOME/beams/projects"/*/identities/mute)
sleep 1
ls "$MUTEDIR"/state/*/watcher.pid >/dev/null 2>&1 \
  && fail "watcher started despite BEAMS_DISABLE_WATCH_ON_BOOT=1"
pass "env opt-out respected: no instruction, no watcher"

# ---------------------------------------------------------------------------
banner "D. react.watch_on_boot=false → join arms nothing"
out=$(runas s29d init "$SHARED"); runas s29d name quiet >/dev/null
QDIR=$(echo "$XDG_CONFIG_HOME/beams/projects"/*/identities/quiet)
jq '.react.watch_on_boot = false' "$QDIR/config.json" > "$QDIR/config.json.tmp" \
  && mv "$QDIR/config.json.tmp" "$QDIR/config.json"
# Stop the watcher the name-bind just started (config was default-true then).
run_as "$QDIR" watch stop >/dev/null 2>&1 || true
out=$(runas s29d join all)
printf '%s' "$out" | grep -q 'beams: joined "all"' || fail "join failed: $out"
printf '%s' "$out" | grep -q 'beams doorbell' \
  && fail "instruction emitted despite watch_on_boot:false"
sleep 1
st=$(run_as "$QDIR" watch status)
printf '%s' "$st" | grep -q 'watcher NOT RUNNING' || fail "watcher restarted despite watch_on_boot:false: $st"
pass "config opt-out respected: no instruction, no watcher"

# ---------------------------------------------------------------------------
banner "E. cross-CLI (no Claude session id): watcher yes, instruction no"
CFG_E="$TMP/cfg-e"; mkdir -p "$CFG_E"
run_as "$CFG_E" init "$SHARED" >/dev/null
run_as "$CFG_E" name crosscli >/dev/null
out=$(run_as "$CFG_E" join all)
printf '%s' "$out" | grep -q 'beams: joined "all"' || fail "join failed: $out"
printf '%s' "$out" | grep -q 'beams doorbell' \
  && fail "instruction emitted with no Claude session id (no Monitor tool there)"
wait_watcher "$CFG_E" || fail "cross-CLI join did not start the watcher"
pass "cross-CLI join: watcher up, no Monitor instruction"

# ---------------------------------------------------------------------------
banner "F. responder profile init: visible instruction with the RESPONDER clause"
out=$(runas s29f init "$SHARED" --profile responder)
printf '%s' "$out" | grep -q 'profile:     responder' || fail "profile summary missing: $out"
printf '%s' "$out" | grep -q 'beams doorbell'         || fail "profile init did not surface the doorbell block"
printf '%s' "$out" | grep -q 'role is RESPONDER'      || fail "instruction missing the responder reply clause"
RDIR=$(echo "$XDG_CONFIG_HOME/beams/projects"/*/identities/responder)
wait_watcher "$RDIR" || fail "responder watcher did not come up"
st=$(run_as "$RDIR" watch status)
printf '%s' "$st" | grep -q 'on-message: ACTIVE' || fail "responder watcher missing the wake-file hook: $st"
pass "responder bootstrap arms watcher + emits the autonomous-reply instruction"

# ---------------------------------------------------------------------------
banner "G. status shows doorbell ground truth (armed vs NOT armed)"
if command -v fuser >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1; then
  out=$(runas s29a status)
  printf '%s' "$out" | grep -q 'doorbell:     NOT armed' \
    || fail "status should say NOT armed with no wake.log reader: $out"
  tail -n 0 -F "$IDDIR/wake.log" >/dev/null 2>&1 &
  TAIL_PID=$!
  sleep 0.3
  out=$(runas s29a status)
  printf '%s' "$out" | grep -Eq 'doorbell:     armed \(wake\.log reader pid [0-9]+\)' \
    || fail "status should show the armed reader pid: $out"
  kill "$TAIL_PID" 2>/dev/null || true; wait "$TAIL_PID" 2>/dev/null || true; TAIL_PID=""
  pass "status reports armed/NOT armed from the open-reader probe"
else
  pass "SKIPPED (neither fuser nor lsof on this box)"
fi

green "round-29 PASS: joining arms the doorbell in the same session — watcher with wake-file hook + Monitor instruction, suppressed by opt-outs, missing session id, or a live reader"
