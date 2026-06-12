#!/usr/bin/env bash
# Round 6: pre-read validation gate + directory permission tightening.
set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test6.XXXXXX)
SHARED="$TMPDIR/share"
CFG_A="$TMPDIR/cfg-a"
CFG_B="$TMPDIR/cfg-b"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
trap 'rm -rf "$TMPDIR"' EXIT

as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
ctx() {
  ( export BEAMS_CONFIG_DIR="$1"; export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    "$PLUGIN/hooks/check-messages.sh" </dev/null
  ) | jq -r '.hookSpecificOutput.additionalContext // ""'
}

# Setup: alice + bob, both joined to 'general'.
mkdir -p "$SHARED"
as "$CFG_A" init "$SHARED" >/dev/null
as "$CFG_B" init "$SHARED" >/dev/null
as "$CFG_A" name alice >/dev/null
as "$CFG_B" name bob   >/dev/null
as "$CFG_A" create general >/dev/null
as "$CFG_A" join general >/dev/null
as "$CFG_B" join general >/dev/null
SID_A=$(jq -r '.session_id' "$CFG_A/config.json")
SID_B=$(jq -r '.session_id' "$CFG_B/config.json")

MSG_DIR="$SHARED/beams/general/messages"

# Helper to write a raw .msg file directly into the share.
write_raw_msg() {
  local fname="$1"; shift
  printf '%s' "$1" > "$MSG_DIR/$fname"
}

banner "1. directory perms are 0700 after create + join"
for d in "$SHARED/beams/general" "$SHARED/beams/general/messages" "$SHARED/beams/general/members"; do
  mode=$(stat -c '%a' "$d")
  [ "$mode" = "700" ] || fail "expected $d to be 0700, got $mode"
done
pass "all beam dirs tightened to 0700"

banner "2. a real send passes validation and delivers"
sleep 1
as "$CFG_A" send general bob "real message that should arrive" >/dev/null
sleep 1
c=$(ctx "$CFG_B")
echo "$c" | grep -q "real message that should arrive" || fail "valid message not delivered"
pass "valid message delivered"

banner "3. message missing frontmatter is silently dropped"
sleep 1
write_raw_msg "20991231T000000Z__nofront.msg" "no frontmatter here, just a body"
c=$(ctx "$CFG_B")
[ -z "$c" ] || fail "malformed (no frontmatter) message leaked: $c"
pass "no-frontmatter message dropped"

banner "4. message with missing 'from' field dropped"
sleep 1
write_raw_msg "20991231T000001Z__nofrom.msg" "---
id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
beam: general
ts: 2026-05-17T13:00:00Z
to: bob
---
body without from"
c=$(ctx "$CFG_B")
[ -z "$c" ] || fail "missing-from message leaked: $c"
pass "missing-from dropped"

banner "5. message with spoofed beam field dropped"
sleep 1
write_raw_msg "20991231T000002Z__spoofbeam.msg" "---
id: aaaaaaaa-bbbb-cccc-dddd-000000000001
beam: SOME-OTHER-BEAM
from: $SID_A
ts: 2026-05-17T13:00:00Z
to: bob
---
spoofed beam name"
c=$(ctx "$CFG_B")
[ -z "$c" ] || fail "beam-spoofed message leaked: $c"
pass "beam-spoof dropped (anti-rename anti-confusion)"

banner "6. message claiming unknown 'from' UUID dropped"
sleep 1
write_raw_msg "20991231T000003Z__unknown.msg" "---
id: aaaaaaaa-bbbb-cccc-dddd-000000000002
beam: general
from: deadbeef-dead-beef-dead-beefdeadbeef
ts: 2026-05-17T13:00:00Z
to: bob
---
no such member"
c=$(ctx "$CFG_B")
[ -z "$c" ] || fail "stranger-sender message leaked: $c"
pass "unknown-sender dropped (membership allowlist)"

banner "7. message with non-UUID 'from' dropped"
sleep 1
write_raw_msg "20991231T000004Z__notuuid.msg" "---
id: aaaaaaaa-bbbb-cccc-dddd-000000000003
beam: general
from: not-a-uuid
ts: 2026-05-17T13:00:00Z
to: bob
---
junk from"
c=$(ctx "$CFG_B")
[ -z "$c" ] || fail "non-UUID-from message leaked: $c"
pass "non-UUID from dropped"

banner "8. oversized message (>100KB) dropped"
sleep 1
big_body=$(printf '%.0sX' $(seq 1 110000))   # 110 KB body
write_raw_msg "20991231T000005Z__big.msg" "---
id: aaaaaaaa-bbbb-cccc-dddd-000000000004
beam: general
from: $SID_A
ts: 2026-05-17T13:00:00Z
to: bob
---
$big_body"
sz=$(wc -c < "$MSG_DIR/20991231T000005Z__big.msg")
[ "$sz" -gt 100000 ] || fail "test fixture isn't actually big: $sz"
c=$(ctx "$CFG_B")
echo "$c" | grep -q "$big_body" && fail "oversized message leaked into context"
pass "oversized message dropped (file size cap)"

banner "9. oversized body (between 10KB-100KB) dropped"
sleep 1
mid_body=$(printf '%.0sY' $(seq 1 15000))   # 15 KB body, file still <100KB
write_raw_msg "20991231T000006Z__midbody.msg" "---
id: aaaaaaaa-bbbb-cccc-dddd-000000000005
beam: general
from: $SID_A
ts: 2026-05-17T13:00:00Z
to: bob
---
$mid_body"
c=$(ctx "$CFG_B")
echo "$c" | grep -q "$mid_body" && fail "mid-body-size message leaked"
pass "oversized body dropped (body length cap)"

banner "10a. unsigned message from a sender WITH pubkey is rejected"
sleep 1
write_raw_msg "20991231T000007Z__nosig_known.msg" "---
id: aaaaaaaa-bbbb-cccc-dddd-000000000006
beam: general
from: $SID_A
ts: 2026-05-17T13:00:00Z
to: bob
---
unsigned, but sender HAS pubkey published"
c=$(ctx "$CFG_B")
echo "$c" | grep -q "unsigned, but sender HAS" \
  && fail "unsigned message from known sender should be REJECTED"
pass "unsigned-from-known-sender rejected (forgery defence active)"

banner "10b. unsigned message from a sender WITHOUT pubkey IS accepted (migration)"
sleep 1
# Synthesise a fake member record with no public_key field — simulates a
# pre-signing peer that hasn't upgraded yet.
fake_sid="ffffffff-ffff-ffff-ffff-ffffffffffff"
fake_rec="$SHARED/beams/general/members/$fake_sid.json"
jq -n --arg id "$fake_sid" --arg name "old-peer" --arg host "legacy" \
      --arg seen "$(date -u +%FT%TZ)" \
      '{id: $id, name: $name, host: $host, last_seen: $seen}' > "$fake_rec"
write_raw_msg "20991231T000008Z__nosig_unknown.msg" "---
id: aaaaaaaa-bbbb-cccc-dddd-000000000007
beam: general
from: $fake_sid
ts: 2026-05-17T13:00:00Z
to: bob
---
unsigned migration message"
c=$(ctx "$CFG_B")
echo "$c" | grep -q "unsigned migration message" \
  || fail "back-compat: unsigned from no-pubkey peer should DELIVER, got: $c"
pass "back-compat: unsigned from no-pubkey peer delivered"

banner "11. dir perms re-affirmed on subsequent join"
# Loosen the dir manually, then re-join, then check it tightened back.
chmod 755 "$SHARED/beams/general"
as "$CFG_A" join general >/dev/null
mode=$(stat -c '%a' "$SHARED/beams/general")
[ "$mode" = "700" ] || fail "expected 0700 after re-join, got $mode"
pass "perms re-tightened on /beams:join"

green ""
green "ALL ROUND-6 TESTS PASSED"
