#!/usr/bin/env bash
# Round 31 — the in-use lease follows the Claude PROCESS, not the session id.
#
# Claude Code mints a new CLAUDE_CODE_SESSION_ID on /clear (same process) and on
# every restart (new process). The lease used to identify its holder by session
# id and prove liveness by scanning /proc for that id — but only CHILD processes
# carry it (the claude process itself does not), so the long-lived watcher
# daemon made a dead session look alive, and a /clear looked like a foreign
# live holder: "not initialised" until the 15-minute window passed. Now the
# lease records $CLAUDE_PID (+ start time, a pid-reuse guard):
#   A. a bind records claude_pid + claude_pid_start
#   B. /clear: a NEW session id in the SAME process auto-binds silently — even
#      with a second, foreign-held identity in the project (certain match)
#   C. restart: the holder's process is gone → the name is free again, no --force
#   D. a DIFFERENT live process still needs --force (never steal)
#   E. pid reuse: same pid number, different start time → treated as gone
#   F. SessionEnd releases the lease on a real exit, keeps it on clear/resume,
#      and ignores a non-holder
#   G. the watcher daemon no longer carries CLAUDE_CODE_SESSION_ID (Linux /proc)

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r31.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg" HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR CLAUDE_PID BEAMS_FAKE_LIVE_SESSIONS
export BEAMS_DISABLE_WATCH_ON_BOOT=1
export BEAMS_NOTIFIER_CMD=true
SHARED="$TMP/share"; mkdir -p "$SHARED"
BASE="$XDG_CONFIG_HOME/beams"
PKEY=$(printf '%s' "$CLAUDE_PROJECT_DIR" | sed 's,/,-,g')
IDENT="$BASE/projects/$PKEY/identities"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
P1=""; P2=""; P9=""
cleanup() {
  for p in "$P1" "$P2" "$P9"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  local f
  for f in "$IDENT"/*/state/*/watcher.pid; do
    [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# run <claude-pid> <session-id> <lib> [args…] — real session/bind resolution.
run()  { ( unset BEAMS_CONFIG_DIR; export CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2"; "$PLUGIN/lib/$3.sh" "${@:4}" ); }
# boot <claude-pid> <session-id> — the SessionStart hook for an unbound session.
boot() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN"
           printf '{"source":"startup"}' | bash "$PLUGIN/hooks/check-on-start.sh" ); }
# end <claude-pid> <session-id> <reason> — the SessionEnd hook.
end()  { ( unset BEAMS_CONFIG_DIR; export CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN"
           printf '{"reason":"%s"}' "$3" | bash "$PLUGIN/hooks/session-end.sh" ); }
LEASE="$IDENT/atlas/lease.json"
holder() { jq -r '.bound_session' "$LEASE"; }

# Stand-ins for Claude processes: any live pid works for kill -0 / ps lstart.
sleep 600 & P1=$!
sleep 600 & P2=$!
sleep 600 & P9=$!

# ---------------------------------------------------------------------------
banner "A. a bind records the Claude process (pid + start time)"
run "$P1" sess-1 init "$SHARED" >/dev/null
run "$P1" sess-1 name atlas     >/dev/null
[ "$(holder)" = sess-1 ]                                  || fail "holder != sess-1"
[ "$(jq -r .claude_pid "$LEASE")" = "$P1" ]               || fail "lease did not record claude_pid: $(jq -c . "$LEASE")"
[ -n "$(jq -r '.claude_pid_start // ""' "$LEASE")" ]      || fail "lease did not record claude_pid_start"
pass "lease: session sess-1, pid $P1, start time recorded"

# A second identity held by a DIFFERENT live process makes the project ambiguous
# for the old (free-count) rule; the pid match must still be certain.
run "$P9" sess-9 name other >/dev/null
[ "$(jq -r .bound_session "$IDENT/other/lease.json")" = sess-9 ] || fail "setup: 'other' not held by sess-9"

# ---------------------------------------------------------------------------
banner "B. /clear: new session id, same process → silent auto-bind (2 identities present)"
out=$(boot "$P1" sess-2)
[ -f "$BASE/sessions/sess-2/bound" ] || fail "sess-2 did not auto-bind after a /clear: $out"
[ "$(cat "$BASE/sessions/sess-2/bound")" = atlas ] || fail "sess-2 bound to the wrong identity: $(cat "$BASE/sessions/sess-2/bound")"
[ "$(holder)" = sess-2 ]                           || fail "lease did not move to sess-2 (holder=$(holder))"
printf '%s' "$out" | grep -q 'you can use' && fail "/clear rebind fell back to the pick-one prompt" || true
pass "same pid → certain match → rebound silently despite a second identity"

# ---------------------------------------------------------------------------
banner "C. restart: the holder's process is gone → reclaimable with no --force"
kill "$P1" 2>/dev/null; wait "$P1" 2>/dev/null || true; P1=""
out=$(boot "$P2" sess-3)
[ "$(cat "$BASE/sessions/sess-3/bound" 2>/dev/null)" = atlas ] || fail "sess-3 (new process) did not auto-bind to the freed name: $out"
[ "$(holder)" = sess-3 ]                                        || fail "lease did not move to sess-3"
[ "$(jq -r .claude_pid "$LEASE")" = "$P2" ]                     || fail "lease pid not updated to the new process"
pass "dead holder process → name free → auto-bound by the restarted terminal"

# ---------------------------------------------------------------------------
banner "D. a different LIVE process still needs --force"
sleep 600 & P1=$!
if run "$P1" sess-4 name atlas >"$TMP/d.out" 2>&1; then fail "bound over a live holder process without --force"; fi
grep -q 'in use by another active session' "$TMP/d.out" || fail "wrong refusal: $(cat "$TMP/d.out")"
[ "$(holder)" = sess-3 ]                               || fail "a live holder lost its lease"
run "$P1" sess-4 name atlas --force >/dev/null         || fail "--force takeover failed"
[ "$(holder)" = sess-4 ]                               || fail "--force did not move the lease"
[ "$(jq -r .claude_pid "$LEASE")" = "$P1" ]            || fail "--force did not record the new pid"
pass "live foreign process → busy; --force still takes over"

# ---------------------------------------------------------------------------
banner "E. pid reuse guard: same pid number, different start time → gone"
tmp=$(mktemp); jq '.claude_pid_start = "Thu Jan  1 00:00:00 1970"' "$LEASE" > "$tmp" && mv "$tmp" "$LEASE"
run "$P2" sess-5 name atlas >/dev/null || fail "a recycled pid (start-time mismatch) should read as gone"
[ "$(holder)" = sess-5 ] || fail "lease did not move after the pid-reuse check"
pass "start-time mismatch → holder treated as gone → reclaimed with no --force"

# ---------------------------------------------------------------------------
banner "F. SessionEnd: release on exit, keep on clear/resume, ignore non-holders"
end "$P2" sess-5 clear
[ "$(holder)" = sess-5 ] || fail "SessionEnd(clear) released the lease (must keep it for the same-pid rebind)"
end "$P2" sess-5 resume
[ "$(holder)" = sess-5 ] || fail "SessionEnd(resume) released the lease"
end "$P9" sess-9 other        # sess-9 holds 'other', not 'atlas' → no effect here
[ "$(holder)" = sess-5 ] || fail "a non-holder's SessionEnd touched the lease"
end "$P2" sess-5 other
[ "$(holder)" = "" ]     || fail "SessionEnd(other) did not release the lease: $(jq -c . "$LEASE")"
[ "$(jq -r '.claude_pid // ""' "$LEASE")" = "" ] || fail "release left claude_pid behind"
# ...and 'other' was released by its own holder's SessionEnd above.
[ "$(jq -r .bound_session "$IDENT/other/lease.json")" = "" ] || fail "'other' not released by sess-9's SessionEnd"
pass "released on a real exit only; a freed name is immediately reclaimable"

# ---------------------------------------------------------------------------
banner "G. the watcher daemon does not carry CLAUDE_CODE_SESSION_ID"
if [ -d /proc ] && [ -r /proc/self/environ ]; then
  ( export BEAMS_CONFIG_DIR="$IDENT/atlas" CLAUDE_CODE_SESSION_ID=sess-7
    "$PLUGIN/lib/watch.sh" start 1 ) >/dev/null
  wpid=""
  for _ in $(seq 1 25); do
    wpid=$(cat "$IDENT"/atlas/state/*/watcher.pid 2>/dev/null | head -1) || wpid=""
    [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && break
    sleep 0.2
  done
  [ -n "$wpid" ] || fail "watcher did not start"
  if tr '\0' '\n' < "/proc/$wpid/environ" | grep -q '^CLAUDE_CODE_SESSION_ID='; then
    fail "daemon env still carries CLAUDE_CODE_SESSION_ID (would impersonate a live session)"
  fi
  tr '\0' '\n' < "/proc/$wpid/environ" | grep -q '^BEAMS_CONFIG_DIR=' || fail "daemon lost BEAMS_CONFIG_DIR"
  ( export BEAMS_CONFIG_DIR="$IDENT/atlas"; "$PLUGIN/lib/watch.sh" stop ) >/dev/null 2>&1 || true
  pass "daemon env: no session id, identity pinned via BEAMS_CONFIG_DIR"
else
  pass "SKIPPED (no readable /proc on this host)"
fi

# ---------------------------------------------------------------------------
banner "H. a lease with no claude_pid stays busy for the heartbeat window"
# A lease written before the pid was recorded leaves only the /proc environ scan
# for the holder's session id, and that scan cannot prove a session GONE — the
# claude process does not carry CLAUDE_CODE_SESSION_ID and the watcher daemon is
# spawned without it (case G) — so a live holder used to read as "gone" and its
# name was reclaimable with no --force. It must read as "unknown" instead: busy
# until the heartbeat window expires, --force meanwhile, and no guess at all
# after a real exit (SessionEnd releases the lease). tests/round-20 case E
# asserts the same contract through the real /proc scan.
run "$P2" sess-8 name atlas >/dev/null || fail "setup: could not take atlas for the no-pid case"
tmp=$(mktemp); jq 'del(.claude_pid) | del(.claude_pid_start)' "$LEASE" > "$tmp" && mv "$tmp" "$LEASE"
tmp=$(mktemp); jq --argjson n "$(date -u +%s)" '.last_seen = $n' "$LEASE" > "$tmp" && mv "$tmp" "$LEASE"
if run "$P1" sess-98 name atlas >"$TMP/h.out" 2>&1; then
  fail "a fresh lease with no claude_pid was reclaimed without --force"
fi
grep -q 'in use by another active session' "$TMP/h.out" || fail "wrong refusal: $(cat "$TMP/h.out")"
[ "$(holder)" = sess-8 ] || fail "the lease moved anyway (holder=$(holder))"
# ...and once the heartbeat window really has passed, the name frees up.
tmp=$(mktemp); jq --argjson n "$(( $(date -u +%s) - 1000 ))" '.last_seen = $n' "$LEASE" > "$tmp" && mv "$tmp" "$LEASE"
run "$P1" sess-98 name atlas >/dev/null || fail "a lease past the heartbeat window still blocked the bind"
[ "$(holder)" = sess-98 ] || fail "the expired lease did not move"
pass "no claude_pid → unknown, not gone: busy inside the window, free after it"

green ""
green "round-31 PASS: the lease follows the Claude process — /clear rebinds silently, a restart reclaims, a live foreign process stays protected, SessionEnd releases, the daemon never impersonates a session"
