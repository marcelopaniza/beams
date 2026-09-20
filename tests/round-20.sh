#!/usr/bin/env bash
# Round 20 — a restarted terminal reclaims its OWN name without --force
# (dead-same-host-holder lease reclaim).
#
# The in-use lease marks a name busy for BEAMS_INUSE_STALE_SECONDS after the
# holder's last heartbeat. After a Claude restart the departed session's lease
# lingers fresh for up to that window, so rebinding the same name used to demand
# --force ("name in use by another active session"). lease_state now asks one
# more question for a still-fresh lease: was the holder a session on THIS host
# that is already gone? If so the name isn't really in use — free it, and the
# restarted terminal reclaims it with no --force. Holders that are still alive,
# on another machine, or recorded by a pre-host-field (legacy) lease all stay
# protected (busy), since beams can't prove those are gone.
#
# Liveness is driven deterministically by the BEAMS_FAKE_LIVE_SESSIONS test seam;
# case E additionally exercises the real /proc scan when /proc is present. One
# limit of that scan, asserted in E: with no claude_pid in the lease it can only
# prove a holder ALIVE (a process carrying its session id), never gone — so an
# invisible holder stays busy for the heartbeat window and needs --force.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r20.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"        # sandbox the whole ~/.config/beams tree
export HOME="$TMP/home"                   # keep legacy-config detection inert
export CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
export BEAMS_DISABLE_WATCH_ON_BOOT=1
# Leases now record the holder's Claude process ($CLAUDE_PID); inside a real
# Claude session every fake session here would share that pid and read as
# "mine". Drop it so the lease assertions see distinct sessions.
unset CLAUDE_PID
SHARED="$TMP/share"; mkdir -p "$SHARED"
BASE="$XDG_CONFIG_HOME/beams"
PKEY=$(printf '%s' "$CLAUDE_PROJECT_DIR" | sed 's,/,-,g')
IDENT="$BASE/projects/$PKEY/identities"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
LP=""                                     # pid of the optional live-holder process (case E)
cleanup(){ [ -n "$LP" ] && kill "$LP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Run a lib as a specific Claude Code session id (real session/bind resolution).
run()    { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
LEASE="$IDENT/vis/lease.json"
holder() { jq -r '.bound_session' "$LEASE"; }
MYHOST=$(hostname 2>/dev/null || echo unknown)

banner "0. session sess-A binds identity 'vis' — the lease records this host"
run sess-A init "$SHARED" >/dev/null
run sess-A name vis       >/dev/null
[ -f "$LEASE" ]                              || fail "no lease after bind"
[ "$(holder)" = sess-A ]                     || fail "holder != sess-A"
[ "$(jq -r '.host' "$LEASE")" = "$MYHOST" ]  || fail "lease did not record host: $(jq -c . "$LEASE")"
pass "'vis' bound by sess-A; lease records host=$MYHOST"

banner "A. a GONE same-host holder is reclaimed WITHOUT --force"
# sess-A has gone (a restart); its lease is still fresh. The seam reports every
# id as dead, so sess-A reads gone — the lone identity must reclaim, no --force.
export BEAMS_FAKE_LIVE_SESSIONS=__nobody__
run sess-B name vis >/dev/null || fail "reclaim of a gone same-host holder should NOT need --force"
[ "$(holder)" = sess-B ] || fail "reclaim did not move the lease to sess-B (holder=$(holder))"
unset BEAMS_FAKE_LIVE_SESSIONS
pass "a restarted terminal reclaimed its name with no --force"

banner "B. a LIVE same-host holder is still protected (needs --force)"
export BEAMS_FAKE_LIVE_SESSIONS=sess-B          # sess-B (the current holder) is alive
if run sess-C name vis >/tmp/r20.out 2>&1; then fail "bound over a LIVE holder without --force"; fi
grep -q 'in use by another active session' /tmp/r20.out || fail "wrong refusal: $(cat /tmp/r20.out)"
[ "$(holder)" = sess-B ]                               || fail "a live holder lost its lease"
run sess-C name vis --force >/dev/null                 || fail "--force takeover of a live holder failed"
[ "$(holder)" = sess-C ]                               || fail "--force did not move the lease"
unset BEAMS_FAKE_LIVE_SESSIONS
pass "a live holder is protected; --force still takes over"

banner "C. a holder on ANOTHER host stays busy (its processes are unseeable here)"
jq -n --arg s ghost --arg h not-this-host --argjson t "$(date -u +%s)" \
  '{bound_session:$s, host:$h, last_seen:$t}' > "$LEASE"
if run sess-D name vis >/tmp/r20.out 2>&1; then fail "reclaimed a cross-host holder without --force (unsafe)"; fi
grep -q 'in use by another active session' /tmp/r20.out || fail "wrong refusal for cross-host: $(cat /tmp/r20.out)"
pass "a holder on another machine is never silently stolen"

banner "D. a pre-host-field (legacy) lease also stays busy"
jq -n --arg s ghost2 --argjson t "$(date -u +%s)" '{bound_session:$s, last_seen:$t}' > "$LEASE"
if run sess-E name vis >/tmp/r20.out 2>&1; then fail "reclaimed a host-less legacy lease without --force"; fi
grep -q 'in use by another active session' /tmp/r20.out || fail "wrong refusal for legacy lease: $(cat /tmp/r20.out)"
pass "a host-less legacy lease stays busy (no liveness claim possible)"

banner "E. the REAL /proc scan: a live child protects; absence is not proof (skipped without /proc)"
if [ -d /proc ] && [ -r /proc/self/environ ]; then
  unset BEAMS_FAKE_LIVE_SESSIONS                 # use the real liveness path
  LIVE="r20live$$"
  L2="$IDENT/realid/lease.json"
  run "$LIVE" init "$SHARED" >/dev/null
  run "$LIVE" name realid    >/dev/null
  [ "$(jq -r .bound_session "$L2")" = "$LIVE" ] || fail "setup: realid not held by \$LIVE"
  # Keep $LIVE genuinely alive on this host, then wait until its env is visible.
  CLAUDE_CODE_SESSION_ID="$LIVE" sleep 30 & LP=$!
  ok=""
  for _ in $(seq 1 30); do
    if cat "/proc/$LP/environ" 2>/dev/null | tr '\0' '\n' | grep -Fxq "CLAUDE_CODE_SESSION_ID=$LIVE"; then ok=1; break; fi
    sleep 0.1
  done
  [ -n "$ok" ] || fail "could not make a live holder visible under /proc"
  # A real, live holder → refused without --force.
  if run sess-take name realid >/tmp/r20.out 2>&1; then fail "real /proc: bound over a genuinely live holder"; fi
  grep -q 'in use by another active session' /tmp/r20.out || fail "real /proc: wrong refusal: $(cat /tmp/r20.out)"
  # The visible child goes away. This lease carries NO claude_pid (a harness that
  # exports no $CLAUDE_PID — see the unset at the top), so all that is left is
  # the environ scan, and on such a harness the only processes that ever carry
  # the session id are the session's transient hooks: "nothing carries it right
  # now" is the normal state of a live session, not proof of death. So the name
  # stays busy for the heartbeat window instead of being handed over silently.
  kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null || true; LP=""
  if run sess-take name realid >/tmp/r20.out 2>&1; then
    fail "real /proc: an unproven absence evicted the holder without --force"
  fi
  grep -q 'in use by another active session' /tmp/r20.out \
    || fail "real /proc: wrong refusal once the child was gone: $(cat /tmp/r20.out)"
  [ "$(jq -r .bound_session "$L2")" = "$LIVE" ] || fail "real /proc: the lease moved anyway"
  # --force is always available for the terminal that knows it restarted...
  run sess-take name realid --force >/dev/null   || fail "real /proc: --force takeover failed"
  [ "$(jq -r .bound_session "$L2")" = sess-take ] || fail "real /proc: --force did not move the lease"
  # ...and a lease nobody refreshed falls out of the heartbeat window on its own.
  # (A real exit does not even need that: SessionEnd releases the lease.)
  tmp=$(mktemp)      # 1000s > the 900s default BEAMS_INUSE_STALE_SECONDS
  jq --argjson n "$(( $(date -u +%s) - 1000 ))" '.last_seen = $n' "$L2" > "$tmp" && mv "$tmp" "$L2"
  run sess-late name realid >/dev/null            || fail "real /proc: a lease past the heartbeat window still blocked the bind"
  [ "$(jq -r .bound_session "$L2")" = sess-late ] || fail "real /proc: the expired lease did not move"
  pass "real /proc: a live child protects; an unproven absence needs --force or the window"
else
  echo "  (skipped — no readable /proc on this host)"
fi

green ""
green "round-20 PASS: a provably gone same-host holder is reclaimable with no --force; live, cross-host, legacy, and merely-unseeable holders stay protected"
