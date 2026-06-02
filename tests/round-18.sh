#!/usr/bin/env bash
# Round 18 — durable, name-keyed identity that survives a Claude restart, plus
# the in-use lease that stops two live sessions sharing one name.
#
# A fresh Claude session gets a NEW $CLAUDE_CODE_SESSION_ID, which used to orphan
# the per-session config ("not initialised after restart"). Identity is now
# anchored on the NAME (/beams:name) keyed per project; a session BINDS to it via
# a pointer that resolution follows, and a lease records who currently holds it.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r18.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"        # sandbox the whole ~/.config/beams tree
export HOME="$TMP/home"                   # keep legacy-config detection inert
export CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
# The watcher auto-arms on boot by default now; this round tests identity/binding,
# not the watcher, so suppress autostart to keep `boot` from spawning daemons.
export BEAMS_DISABLE_WATCH_ON_BOOT=1
SHARED="$TMP/share"; mkdir -p "$SHARED"
BASE="$XDG_CONFIG_HOME/beams"
PKEY=$(printf '%s' "$CLAUDE_PROJECT_DIR" | sed 's,/,-,g')
IDENT="$BASE/projects/$PKEY/identities"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# Run a lib as a specific Claude Code session id, with NO BEAMS_CONFIG_DIR
# override, so the real session/bind resolution is exercised.
run() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
# Fire the SessionStart hook as a given (unbound) session id.
boot() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN"; bash "$PLUGIN/hooks/check-on-start.sh" </dev/null ); }

banner "1. session S1: init writes a scratch per-session config"
run sess-1 init "$SHARED" >/dev/null
[ -f "$BASE/sessions/sess-1/config.json" ] || fail "no scratch config after init"
pass "scratch config at sessions/sess-1/"

banner "2. /beams:name loop migrates the scratch config into a durable identity + binds"
run sess-1 name loop >/dev/null
[ -f "$BASE/sessions/sess-1/bound" ]              || fail "no bound pointer"
[ "$(cat "$BASE/sessions/sess-1/bound")" = loop ] || fail "bound pointer != loop"
[ -f "$IDENT/loop/config.json" ]                  || fail "no durable identity config"
[ ! -f "$BASE/sessions/sess-1/config.json" ]      || fail "scratch config not migrated away"
UUID1=$(jq -r '.session_id' "$IDENT/loop/config.json")
[ -n "$UUID1" ] && [ "$UUID1" != null ]           || fail "durable identity has no UUID"
pass "migrated to durable identity 'loop' (uuid=$UUID1)"

banner "3. resolution: S1 status now resolves to the durable identity"
out=$(run sess-1 status)
printf '%s' "$out" | grep -q 'session_name: loop' || fail "status didn't resolve to loop: $out"
pass "bound session resolves to the durable identity"

banner "4. lease: a different live session is refused without --force"
# The holder (sess-1) must look alive for the busy gate to engage — a lease whose
# holder is a gone same-host session is now reclaimable (round-20). Force sess-1
# 'live' via the test seam so this exercises live-session protection.
export BEAMS_FAKE_LIVE_SESSIONS=sess-1
if run sess-2 name loop >/tmp/r18-s2.out 2>&1; then
  fail "S2 bound 'loop' while S1 holds a fresh lease (expected refusal)"
fi
grep -q 'in use by another active session' /tmp/r18-s2.out || fail "wrong refusal: $(cat /tmp/r18-s2.out)"
pass "concurrent bind to a fresh-lease name is refused"

banner "5. --force takes over; rebind preserves the same UUID"
run sess-2 name loop --force >/dev/null
[ "$(cat "$BASE/sessions/sess-2/bound")" = loop ] || fail "S2 not bound after --force"
UUID2=$(jq -r '.session_id' "$IDENT/loop/config.json")
[ "$UUID2" = "$UUID1" ] || fail "rebind changed the UUID ($UUID1 -> $UUID2)"
[ "$(jq -r '.bound_session' "$IDENT/loop/lease.json")" = sess-2 ] || fail "lease holder not moved to sess-2"
pass "forced takeover rebinds same identity (uuid stable), lease moves to S2"
unset BEAMS_FAKE_LIVE_SESSIONS

banner "6. a stale lease frees the name without --force"
export BEAMS_INUSE_STALE_SECONDS=0
run sess-3 name loop >/dev/null || fail "stale-lease bind should succeed without --force"
unset BEAMS_INUSE_STALE_SECONDS
[ "$(jq -r '.bound_session' "$IDENT/loop/lease.json")" = sess-3 ] || fail "stale takeover didn't move the lease"
pass "stale lease is reclaimed without --force"

banner "7. a second name in the same project creates a sibling identity (own UUID, inherited folder)"
run sess-4 name game2 >/dev/null
[ -f "$IDENT/game2/config.json" ] || fail "no sibling identity 'game2'"
UUID_G=$(jq -r '.session_id' "$IDENT/game2/config.json")
[ "$UUID_G" != "$UUID1" ] || fail "sibling identity reused the same UUID"
[ "$(jq -r '.shared_path' "$IDENT/game2/config.json")" = "$SHARED" ] || fail "sibling didn't inherit the shared folder"
pass "sibling 'game2' created with its own UUID + inherited folder"

banner "8. path-traversal name is rejected (no escape from identities/)"
if run sess-5 name '../evil' >/tmp/r18-ev.out 2>&1; then
  fail "accepted a path-traversal name"
fi
[ ! -e "$BASE/projects/$PKEY/evil" ] && [ ! -e "$BASE/projects/evil" ] || fail "traversal escaped the identities dir"
pass "path-traversal name rejected"

banner "9. status reports the binding + in-use lease"
sout=$(run sess-3 status)
printf '%s' "$sout" | grep -qE 'bound:[[:space:]]+loop' || fail "status missing 'bound: loop': $sout"
printf '%s' "$sout" | grep -qE 'in use:[[:space:]]+yes'  || fail "status missing 'in use: yes': $sout"
pass "status reports bound=loop, in use=yes"

banner "10. SessionStart auto-binds an unbound session to a lone FREE identity; never asks"
# 'loop' (held by sess-3) and 'game2' (held by sess-4) both hold fresh leases →
# an unbound session must NOT bind to a busy name and must NOT prompt: silent.
# Their holders must look alive for "busy" to hold (a gone same-host holder is
# reclaimable now — round-20); force both live via the test seam.
export BEAMS_FAKE_LIVE_SESSIONS=sess-3,sess-4
bout=$(boot boot-sess)
[ -z "$bout" ] || fail "boot hook spoke while every identity was busy (must stay silent, never steal): $bout"
# Free exactly one identity (its holder went away) → now exactly one bindable,
# so an unbound session silently rebinds to it — no prompt, no question.
rm -f "$IDENT/loop/lease.json"
bout=$(boot boot-sess2)
printf '%s' "$bout" | jq -e '.hookSpecificOutput.additionalContext | test("auto-bound to \"loop\"")' >/dev/null \
  || fail "boot hook didn't auto-bind to the lone free identity: $bout"
[ "$(cat "$BASE/sessions/boot-sess2/bound" 2>/dev/null)" = loop ] \
  || fail "auto-bind didn't write boot-sess2's bound pointer"
pass "SessionStart auto-binds to a lone free identity; silent when busy or ambiguous"
unset BEAMS_FAKE_LIVE_SESSIONS

banner "11. Stop hook delivers to a bound, opted-in session (proactive, no new prompt)"
run sess-3 join general >/dev/null                       # sess-3 is bound to 'loop'
tmp=$(mktemp); jq '.react.on_stop = true' "$IDENT/loop/config.json" > "$tmp" && mv "$tmp" "$IDENT/loop/config.json"
run sender-x init "$SHARED" >/dev/null
run sender-x name sender    >/dev/null
run sender-x join general   >/dev/null
run sender-x send general loop 'ping-without-typing' >/dev/null
stopout=$( printf '{"stop_hook_active":false}' | ( unset BEAMS_CONFIG_DIR; \
  export CLAUDE_CODE_SESSION_ID=sess-3 CLAUDE_PLUGIN_ROOT="$PLUGIN"; \
  bash "$PLUGIN/hooks/respond-on-stop.sh" ) )
printf '%s' "$stopout" | grep -q '"decision"'        || fail "Stop hook didn't emit a block decision: $stopout"
printf '%s' "$stopout" | grep -q 'ping-without-typing' || fail "Stop hook didn't surface the waiting message: $stopout"
pass "Stop hook surfaces a waiting message to a bound opted-in session"

# ── 12. concurrent unbound binds: the lock prevents a double-bind (race), and ─
#        a losing bind degrades to a silent no-op instead of crashing the hook ─
banner "12. concurrent SessionStarts bind a lone free identity exactly once; losers exit 0"
PC="$TMP/proj-conc"; PCK=$(printf '%s' "$PC" | sed 's,/,-,g'); CCI="$BASE/projects/$PCK/identities"
( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID=cc-owner CLAUDE_PROJECT_DIR="$PC"; mkdir -p "$PC"
  "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null; "$PLUGIN/lib/name.sh" cc-id >/dev/null )
rm -f "$CCI/cc-id/lease.json"          # exactly one bindable (free) identity in PC
# The 3 racers must look alive so the WINNER's fresh lease reads busy to the
# losers — otherwise each ephemeral boot session dies instantly and the
# dead-holder reclaim (round-20) would let all 3 bind. The bindlock + this seam
# make the "exactly one winner" outcome deterministic.
export BEAMS_FAKE_LIVE_SESSIONS=cc-A,cc-B,cc-C
fire() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$PC" CLAUDE_PLUGIN_ROOT="$PLUGIN"; bash "$PLUGIN/hooks/check-on-start.sh" </dev/null >/dev/null 2>&1 ); }
fire cc-A & pA=$!; fire cc-B & pB=$!; fire cc-C & pC=$!
rcA=0; wait "$pA" || rcA=$?; rcB=0; wait "$pB" || rcB=$?; rcC=0; wait "$pC" || rcC=$?
{ [ "$rcA" = 0 ] && [ "$rcB" = 0 ] && [ "$rcC" = 0 ]; } \
  || fail "a concurrent SessionStart hook exited non-zero (bind-die crashed the hook): rcA=$rcA rcB=$rcB rcC=$rcC"
bc=0; for s in cc-A cc-B cc-C; do [ "$(cat "$BASE/sessions/$s/bound" 2>/dev/null)" = cc-id ] && bc=$((bc + 1)); done
[ "$bc" -eq 1 ] || fail "concurrent bind produced $bc bound pointers to cc-id (expected exactly 1 — lease lock failed)"
pass "exactly 1 of 3 concurrent boots bound cc-id; all 3 hooks exited 0"
unset BEAMS_FAKE_LIVE_SESSIONS

# ── 13. auto-bind + unread must preserve check.sh's top-level systemMessage ───
banner "13. auto-bind preserves the user-visible systemMessage when unread is waiting"
PS="$TMP/proj-sysmsg"; PSK=$(printf '%s' "$PS" | sed 's,/,-,g'); SMI="$BASE/projects/$PSK/identities"
( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID=sm-owner CLAUDE_PROJECT_DIR="$PS"; mkdir -p "$PS"
  "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null
  "$PLUGIN/lib/name.sh" sm-id    >/dev/null
  "$PLUGIN/lib/join.sh" sm-beam  >/dev/null )
run sm-send init "$SHARED" >/dev/null
run sm-send name sm-send   >/dev/null
run sm-send join sm-beam   >/dev/null
run sm-send send sm-beam sm-id 'sysmsg-probe-body' >/dev/null
rm -f "$SMI/sm-id/lease.json"          # free sm-id so the unbound boot auto-binds to it
bout=$( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID=sm-boot CLAUDE_PROJECT_DIR="$PS" CLAUDE_PLUGIN_ROOT="$PLUGIN"; bash "$PLUGIN/hooks/check-on-start.sh" </dev/null )
printf '%s' "$bout" | jq -e '(.systemMessage // "") != ""' >/dev/null \
  || { printf '%s' "$bout" | sed 's/^/    /'; fail "auto-bind dropped check.sh's top-level systemMessage"; }
printf '%s' "$bout" | jq -e '.hookSpecificOutput.additionalContext | test("sysmsg-probe-body")' >/dev/null \
  || fail "auto-bind additionalContext missing the message body"
pass "auto-bind preserved systemMessage + folded the inbox into additionalContext"

green ""
green "round-18 PASS: durable identity + bind/rebind/migrate + lease + status + boot auto-bind + concurrent-bind lock + systemMessage + Stop delivery"
