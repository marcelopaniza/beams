#!/usr/bin/env bash
# Round 4: driver rename, transfer-driver, cleanup-stale, multi-recipient, @-tags.
set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test4.XXXXXX)
SHARED="$TMPDIR/share"
CFG_A="$TMPDIR/cfg-a"
CFG_B="$TMPDIR/cfg-b"
CFG_C="$TMPDIR/cfg-c"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
banner(){ printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()  { red "FAIL: $*"; exit 1; }
pass()  { green "PASS: $*"; }
trap 'rm -rf "$TMPDIR"' EXIT

as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
hook() { ( export BEAMS_CONFIG_DIR="$1"; export CLAUDE_PLUGIN_ROOT="$PLUGIN"; "$PLUGIN/hooks/check-messages.sh" </dev/null ); }
ctx() { hook "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }

mkdir -p "$SHARED"
as "$CFG_A" init "$SHARED" >/dev/null
as "$CFG_B" init "$SHARED" >/dev/null
as "$CFG_C" init "$SHARED" >/dev/null
as "$CFG_A" name alice >/dev/null
as "$CFG_B" name bob   >/dev/null
as "$CFG_C" name carol >/dev/null
SID_A=$(jq -r '.session_id' "$CFG_A/config.json")
SID_B=$(jq -r '.session_id' "$CFG_B/config.json")
SID_C=$(jq -r '.session_id' "$CFG_C/config.json")

# alice creates and is driver
as "$CFG_A" create team >/dev/null
as "$CFG_A" join team >/dev/null
as "$CFG_B" join team >/dev/null
as "$CFG_C" join team >/dev/null

banner "1. driver field is written on create (no legacy 'manager' key)"
jq -e '.driver != null and .manager == null' "$SHARED/beams/team/manifest.json" >/dev/null \
  || fail "new beam should have .driver and no .manager"
pass "new manifest uses .driver"

banner "2. legacy 'manager' field is still recognised"
# Simulate a pre-rename manifest by writing manager directly.
echo '{"name":"legacy","created":"2020-01-01","created_by":"'$SID_A'","manager":"'$SID_A'"}' \
  > "$SHARED/beams/team/manifest.json"
mkdir -p "$SHARED/beams/team/members"
as "$CFG_A" lock team "test" >/dev/null \
  || fail "alice (legacy manager) should be able to lock"
# After the lock, write should have migrated manager → driver
jq -e '.driver == "'"$SID_A"'" and .manager == null' "$SHARED/beams/team/manifest.json" >/dev/null \
  || fail "manifest should have auto-migrated to .driver on write"
as "$CFG_A" unlock team >/dev/null
pass "legacy manager honoured; auto-migrates to driver on write"

banner "3. /beams:members shows 'driver' and 'rider'"
# Refresh member records for everyone
as "$CFG_A" join team >/dev/null
as "$CFG_B" join team >/dev/null
as "$CFG_C" join team >/dev/null
m=$(as "$CFG_A" members team)
echo "$m" | grep -E "$SID_A.*driver" >/dev/null || fail "alice should be driver"
echo "$m" | grep -E "$SID_B.*rider"  >/dev/null || fail "bob should be rider"
pass "role column shows driver/rider"

banner "4. /beams:transfer-driver — bob (not driver) cannot transfer"
if out=$(as "$CFG_B" transfer-driver team alice 2>&1); then
  fail "non-driver transfer should fail; got: $out"
fi
pass "non-driver transfer refused"

banner "5. alice transfers driver to bob (by name)"
out=$(as "$CFG_A" transfer-driver team bob)
echo "  $out"
jq -e '.driver == "'"$SID_B"'"' "$SHARED/beams/team/manifest.json" >/dev/null \
  || fail "driver should now be bob"
pass "driver transferred to bob"

banner "6. alice cannot transfer back (no longer driver)"
if as "$CFG_A" transfer-driver team alice >/dev/null 2>&1; then
  fail "alice should no longer be driver"
fi
pass "old driver lost privileges"

banner "7. --force refuses when current driver looks active"
if out=$(as "$CFG_A" transfer-driver team alice --force 2>&1); then
  fail "--force should be refused when driver's record is fresh; got: $out"
fi
case "$out" in
  *"active in the last 7 days"*) pass "--force refused for fresh driver (staleness gate works)" ;;
  *) fail "wrong error: $out" ;;
esac

banner "7b. --force takeover succeeds once the driver looks gone"
# Backdate bob's member record to 8 days ago to simulate "machine dead".
touch -t $(date -d '8 days ago' +%Y%m%d%H%M 2>/dev/null \
           || date -v-8d +%Y%m%d%H%M) \
       "$SHARED/beams/team/members/$SID_B.json"
out=$(as "$CFG_A" transfer-driver team alice --force)
echo "  $out"
jq -e '.driver == "'"$SID_A"'"' "$SHARED/beams/team/manifest.json" >/dev/null \
  || fail "alice should have taken over via --force after backdating"
pass "--force takeover works when driver is stale"

banner "8. /beams:cleanup-stale — backdate a member, then clean"
# Backdate carol's member file to 60 days ago.
touch -t $(date -d '60 days ago' +%Y%m%d%H%M 2>/dev/null \
           || date -v-60d +%Y%m%d%H%M) \
       "$SHARED/beams/team/members/$SID_C.json"
out=$(as "$CFG_A" cleanup-stale team --older-than 30d)
echo "  $out"
[ ! -f "$SHARED/beams/team/members/$SID_C.json" ] || fail "carol's stale record should be removed"
[ -f "$SHARED/beams/team/members/$SID_A.json" ]   || fail "driver alice should be preserved"
[ -f "$SHARED/beams/team/members/$SID_B.json" ]   || fail "fresh bob should be preserved"
pass "cleanup removed stale carol, kept alice (driver) and fresh bob"

banner "9. cleanup-stale --dry-run does not delete"
# Re-create carol then re-backdate
as "$CFG_C" join team >/dev/null
touch -t $(date -d '60 days ago' +%Y%m%d%H%M 2>/dev/null \
           || date -v-60d +%Y%m%d%H%M) \
       "$SHARED/beams/team/members/$SID_C.json"
out=$(as "$CFG_A" cleanup-stale team --older-than 30d --dry-run)
[ -f "$SHARED/beams/team/members/$SID_C.json" ] || fail "dry-run should not delete"
echo "$out" | grep -q "WOULD-REMOVE"            || fail "dry-run should print WOULD-REMOVE lines"
pass "--dry-run preserves files and reports intent"

banner "10. multi-recipient: alice → bob,carol"
# Fresh members so cleanup didn't leave carol absent
as "$CFG_C" join team >/dev/null
sleep 1
as "$CFG_A" send team "bob,carol" "hi bob and carol — multi-recipient test" >/dev/null
sleep 1
ctx_b=$(ctx "$CFG_B"); ctx_c=$(ctx "$CFG_C"); ctx_a=$(ctx "$CFG_A")
echo "$ctx_b" | grep -q "multi-recipient test" || fail "bob should have received"
echo "$ctx_c" | grep -q "multi-recipient test" || fail "carol should have received"
[ -z "$ctx_a" ] || fail "alice should NOT receive her own message — got: $ctx_a"
pass "multi-recipient reached both, sender filtered"

banner "11. multi-recipient: outsider (newly-joined david) does NOT receive"
mkdir -p "$TMPDIR/cfg-d"
as "$TMPDIR/cfg-d" init "$SHARED" >/dev/null
as "$TMPDIR/cfg-d" name david >/dev/null
as "$TMPDIR/cfg-d" join team >/dev/null
sleep 1
as "$CFG_A" send team "bob,carol" "outsider-test direct only" >/dev/null
sleep 1
ctx_d=$(ctx "$TMPDIR/cfg-d")
[ -z "$ctx_d" ] || fail "david should not receive direct-to-bob+carol; got: $ctx_d"
pass "outsider not delivered for direct multi-recipient"

banner "12. @-tag: broadcast that mentions david → david receives"
sleep 1
as "$CFG_A" send team all "team note — @david please review the PR" >/dev/null
sleep 1
ctx_d=$(ctx "$TMPDIR/cfg-d")
echo "$ctx_d" | grep -q "please review the PR" \
  || fail "david should have received the broadcast he was tagged in; got: $ctx_d"
pass "@-tag matched (and broadcast 'all' would have anyway in this case — see next)"

banner "13. @-tag matters: direct to bob only, but mentions david → david also gets it"
sleep 1
as "$CFG_A" send team bob "@david heads up about this thread" >/dev/null
sleep 1
ctx_d=$(ctx "$TMPDIR/cfg-d")
ctx_b=$(ctx "$CFG_B")
echo "$ctx_b" | grep -q "heads up about this thread" || fail "bob (in to) should receive"
echo "$ctx_d" | grep -q "heads up about this thread" || fail "david (in @-tag) should receive"
pass "@-tag delivers even when 'to' doesn't list the recipient"

banner "14. @-tag false-positive guard: @davidson should NOT match @david"
sleep 1
as "$CFG_A" send team bob "report from @davidson" >/dev/null
sleep 1
ctx_d=$(ctx "$TMPDIR/cfg-d")
[ -z "$ctx_d" ] || fail "@davidson should not match @david; got: $ctx_d"
pass "word-boundary check prevents @-tag false positives"

banner "15. hook output includes systemMessage with sender summary"
sleep 1
as "$CFG_A" send team bob "with system message" >/dev/null
sleep 1
out=$(hook "$CFG_B")
echo "$out" | jq -e '.systemMessage' >/dev/null \
  || fail "hook should include a top-level systemMessage now"
sysmsg=$(echo "$out" | jq -r '.systemMessage')
case "$sysmsg" in
  *"alice"*) pass "systemMessage names the sender: $sysmsg" ;;
  *) fail "systemMessage missing sender name: $sysmsg" ;;
esac

green ""
green "ALL ROUND-4 TESTS PASSED"
