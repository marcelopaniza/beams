#!/usr/bin/env bash
# End-to-end smoke test for the beams plugin.
# Simulates two sessions (A and B) on a single machine using two distinct config dirs.
set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test.XXXXXX)
SHARED="$TMPDIR/share"
CFG_A="$TMPDIR/cfg-a"
CFG_B="$TMPDIR/cfg-b"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
banner(){ printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()  { red "FAIL: $*"; exit 1; }
pass()  { green "PASS: $*"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Helpers to run a lib script "as" session A or B.
as_a() { ( export BEAMS_CONFIG_DIR="$CFG_A"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }
as_b() { ( export BEAMS_CONFIG_DIR="$CFG_B"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }
hook_a() { ( export BEAMS_CONFIG_DIR="$CFG_A"; export CLAUDE_PLUGIN_ROOT="$PLUGIN"; "$PLUGIN/hooks/check-messages.sh" </dev/null ); }
hook_b() { ( export BEAMS_CONFIG_DIR="$CFG_B"; export CLAUDE_PLUGIN_ROOT="$PLUGIN"; "$PLUGIN/hooks/check-messages.sh" </dev/null ); }

banner "1. init both sessions against shared=$SHARED"
mkdir -p "$SHARED"
as_a init "$SHARED" >/dev/null
as_b init "$SHARED" >/dev/null
[ -f "$CFG_A/config.json" ] && [ -f "$CFG_B/config.json" ] || fail "configs not written"
SID_A=$(jq -r '.session_id' "$CFG_A/config.json")
SID_B=$(jq -r '.session_id' "$CFG_B/config.json")
[ "$SID_A" != "$SID_B" ] || fail "session IDs collided"
pass "two configs, session_a=$SID_A session_b=$SID_B"

banner "2. friendly names"
as_a name "alice" >/dev/null
as_b name "bob"   >/dev/null
[ "$(jq -r '.session_name' "$CFG_A/config.json")" = "alice" ] || fail "alice name not set"
[ "$(jq -r '.session_name' "$CFG_B/config.json")" = "bob"   ] || fail "bob name not set"
pass "alice and bob named"

banner "3. create beam + both join"
as_a create general >/dev/null
[ -d "$SHARED/beams/general" ] || fail "beam not created"
as_a join general >/dev/null
as_b join general >/dev/null
ls "$SHARED/beams/general/members" | sort > "$TMPDIR/members.txt"
[ "$(wc -l < "$TMPDIR/members.txt")" = "2" ] || fail "expected 2 member records, got: $(cat "$TMPDIR/members.txt")"
pass "both joined, 2 member records present"

banner "4. alice -> bob direct message"
out=$(as_a send general bob "hey bob, can you check the deploy?")
echo "  $out"
sleep 1   # ensure mtime > cursor mtime (find -newer is strict)

banner "5. bob checks (hook output)"
bob_hook_out=$(hook_b)
[ -n "$bob_hook_out" ] || fail "hook produced no output despite a new message"
echo "$bob_hook_out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null || fail "hook output is not valid JSON with additionalContext"
ctx=$(echo "$bob_hook_out" | jq -r '.hookSpecificOutput.additionalContext')
echo "$ctx" | grep -q "alice → bob" || fail "context missing 'alice → bob' line"
echo "$ctx" | grep -q "can you check the deploy" || fail "context missing message body"
pass "bob received alice's message via hook"

banner "6. bob's second check returns nothing (cursor advanced)"
bob_hook_out2=$(hook_b)
[ -z "$bob_hook_out2" ] || fail "second hook call should be silent — got: $bob_hook_out2"
pass "cursor correctly advanced; silent second check"

banner "7. alice's own check returns nothing (self-messages filtered)"
alice_hook=$(hook_a)
[ -z "$alice_hook" ] || fail "alice should not receive her own message — got: $alice_hook"
pass "self-message filter works"

banner "8. bob broadcasts to 'all'"
sleep 1
out=$(as_b send general all "team standup in 5 minutes")
echo "  $out"
sleep 1

banner "9. alice receives broadcast"
alice_hook2=$(hook_a)
[ -n "$alice_hook2" ] || fail "alice should have received the broadcast"
echo "$alice_hook2" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "standup in 5 minutes" || fail "broadcast body missing"
pass "alice received bob's broadcast"

banner "10. bob does NOT receive own broadcast"
bob_hook3=$(hook_b)
[ -z "$bob_hook3" ] || fail "bob should not receive own broadcast — got: $bob_hook3"
pass "broadcast self-filter works"

banner "11. /beams:status sanity"
status_out=$(as_a status)
echo "$status_out" | grep -q "session_name: alice" || fail "status missing alice's name"
echo "$status_out" | grep -q "general" || fail "status missing 'general' subscription"
pass "status output looks right"

banner "12. /beams:list and /beams:members"
list_out=$(as_a list)
echo "$list_out" | grep -q "general" || fail "list missing 'general'"
members_out=$(as_a members general)
echo "$members_out" | grep -q "alice" && echo "$members_out" | grep -q "bob" || fail "members output missing alice or bob"
pass "list and members work"

banner "13. hook idle-cost: no new messages = empty output"
empty=$(hook_a)
[ -z "$empty" ] || fail "idle hook should be empty"
pass "idle hook produces no output (zero tokens injected)"

banner "14. timing the idle hook"
t0=$(date +%s%N)
hook_a >/dev/null
t1=$(date +%s%N)
us=$(( (t1 - t0) / 1000 ))
echo "  idle hook took ${us} µs"
[ "$us" -lt 500000 ] || red "  (warning: idle hook took > 500ms; not a failure but worth investigating)"

banner "15. /beams:read after a fresh message"
sleep 1
as_a send general bob "second message" >/dev/null
sleep 1
read_out=$(as_b check --human)
echo "$read_out" | grep -q "second message" || fail "/beams:read missing fresh message"
pass "/beams:read shows new message"

green ""
green "ALL TESTS PASSED"
