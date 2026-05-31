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

banner "10. SessionStart hook prompts an unbound session to bind (project has identities)"
bout=$(boot boot-sess)
printf '%s' "$bout" | grep -q 'not yet bound' || fail "boot hook didn't emit a bind prompt: $bout"
printf '%s' "$bout" | grep -q 'loop'          || fail "boot prompt didn't list known names: $bout"
pass "SessionStart prompts an unbound session to /beams:name"

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

green ""
green "round-18 PASS: durable identity + bind/rebind/migrate + lease + status + boot prompt + Stop delivery"
