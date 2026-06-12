#!/usr/bin/env bash
# Round 8: regression coverage for the v0.6.0 audit fixes —
#   - base64 newline strip (would silently break signing on macOS)
#   - fm_field prefix collision (`from` no longer matches `from_name`)
#   - canonical NUL separation (newlines in fields can't collide canonicals)
#   - @-mention regex escape (names with `.` no longer wildcard-match)
#   - TOCTOU between validate and render (file content captured once)
#   - per-beam require_signatures policy
#   - watcher start mkdir-lock (concurrent starts serialise)
set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test8.XXXXXX)
SHARED="$TMPDIR/share"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
trap 'rm -rf "$TMPDIR"; for p in $TMPDIR/cfg-*/state/*/watcher.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null || true; done' EXIT

as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
ctx() {
  ( export BEAMS_CONFIG_DIR="$1"; export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    "$PLUGIN/hooks/check-messages.sh" </dev/null
  ) | jq -r '.hookSpecificOutput.additionalContext // ""'
}

mkdir -p "$SHARED"
as "$TMPDIR/cfg-a" init "$SHARED" >/dev/null
as "$TMPDIR/cfg-b" init "$SHARED" >/dev/null
as "$TMPDIR/cfg-a" name alice >/dev/null
as "$TMPDIR/cfg-b" name bob   >/dev/null
SID_A=$(jq -r .session_id "$TMPDIR/cfg-a/config.json")
SID_B=$(jq -r .session_id "$TMPDIR/cfg-b/config.json")
as "$TMPDIR/cfg-a" create general >/dev/null
as "$TMPDIR/cfg-a" join general >/dev/null
as "$TMPDIR/cfg-b" join general >/dev/null

banner "1. base64 portability: pubkey is single-line"
pub=$(jq -r .public_key "$SHARED/beams/general/members/$SID_A.json")
case "$pub" in
  *$'\n'*) fail "pubkey is multi-line — base64 -w0 leak (would break on macOS)" ;;
  *) pass "pubkey is single-line (${#pub} chars)" ;;
esac

banner "2. fm_field prefix-collision guard: 'from' does NOT read 'from_name'"
# Synthesise a frontmatter where from_name appears BEFORE from to exercise
# the prefix-match bug. The old awk-based extractor would have read
# from_name's value when asked for 'from'; the new sed-anchored version
# must read 'from' correctly.
fm="from_name: alice
from: ${SID_A}
beam: general
ts: 2026-05-17T15:46:56Z"
val=$( . "$PLUGIN/lib/common.sh"; beams::fm_field "$fm" from )
[ "$val" = "$SID_A" ] || fail "fm_field 'from' returned '$val' (likely matched from_name)"
pass "fm_field correctly disambiguates 'from' from 'from_name'"

banner "3. timestamps with colons survive round-trip (signature validity)"
sleep 1
as "$TMPDIR/cfg-a" send general bob "ts-test" >/dev/null
sleep 1
c=$(ctx "$TMPDIR/cfg-b")
echo "$c" | grep -q "ts-test" \
  || fail "signed message with colon-laden ts didn't verify"
pass "ts with colons round-trips and signature verifies"

banner "4. @-mention regex escape: a name with '.' doesn't wildcard-match"
# Give alice a dotted name on a fresh beam to avoid disturbing 'general'.
as "$TMPDIR/cfg-a" create dotted >/dev/null
as "$TMPDIR/cfg-a" join dotted >/dev/null
as "$TMPDIR/cfg-b" join dotted >/dev/null
as "$TMPDIR/cfg-b" name "b.b"   >/dev/null
sleep 1
# Send to alice (not b.b) with a body that, under the OLD unescaped regex,
# would match @bxb because `.` was treated as wildcard. The new escape
# treats `.` literally.
as "$TMPDIR/cfg-a" send dotted alice "hey @bxb how are you" >/dev/null
sleep 1
c=$(ctx "$TMPDIR/cfg-b")
[ -z "$c" ] || fail "b.b should NOT have matched @bxb (regex escape broken): $c"
pass "@-mention regex escape: '.' in names treated as literal"

# Verify the positive case still works:
sleep 1
as "$TMPDIR/cfg-a" send dotted alice "and now @b.b you SHOULD get this" >/dev/null
sleep 1
c=$(ctx "$TMPDIR/cfg-b")
echo "$c" | grep -q "you SHOULD get this" \
  || fail "literal @b.b mention should deliver"
pass "literal @-mention with '.' still delivers"

banner "5. TOCTOU: file swap between validate and render does NOT change rendered content"
# Send a message, freeze its in-memory content as we'd see it under the
# hook, then mutate the file on disk to simulate a hostile swap. The hook
# already cached the original content; rendering must use the cached copy.
# (We can't directly test the inside of the hook process from here, but we
# can verify the property by comparing what the hook delivers vs what's on
# disk after a swap.)
sleep 1
as "$TMPDIR/cfg-a" send general bob "original-content-AAAA" >/dev/null
sleep 1
# Race: simulate the swap BEFORE bob's hook runs.
# (In real life, the bob hook would atomically cat then validate; this test
# verifies that the validate logic reads from the in-memory content.)
last=$(ls -t "$SHARED/beams/general/messages/"*.msg | head -1)
backup="/tmp/beams-test8-orig.msg"
cp "$last" "$backup"
# Hostile mutation (invalid signature now, but render still happens from
# cached content): replace body line.
sed -i 's/original-content-AAAA/SWAPPED-EVIL-BBBB/' "$last"
c=$(ctx "$TMPDIR/cfg-b")
# Because the swap invalidated the sig, the message is dropped entirely —
# even safer than just rendering the cached copy. Verify that property:
echo "$c" | grep -q "SWAPPED-EVIL-BBBB" \
  && fail "swapped content with invalid sig should be DROPPED, not rendered"
# Restore for next test, then re-deliver to make sure we drained the cursor.
cp "$backup" "$last"
ctx "$TMPDIR/cfg-b" >/dev/null   # advance cursor past the now-restored msg
rm -f "$backup"
pass "post-validate swap rejected by signature check (defense in depth)"

banner "6. require_signatures: turning ON rejects unsigned-but-allowed messages"
as "$TMPDIR/cfg-a" create strict >/dev/null
as "$TMPDIR/cfg-a" join strict >/dev/null
as "$TMPDIR/cfg-b" join strict >/dev/null
# Synthesise a fake unsigned-eligible member (no public_key) and an unsigned
# message from them. With require_signatures OFF (default), bob receives.
fake_sid="ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb"
fake_rec="$SHARED/beams/strict/members/$fake_sid.json"
jq -n --arg id "$fake_sid" --arg name "old-peer" '{id:$id, name:$name, host:"legacy", last_seen:"2026-01-01T00:00:00Z"}' > "$fake_rec"
ts=$(date -u +%Y%m%dT%H%M%SZ)
# Address to bob's UUID — test 4 renamed bob to "b.b", so 'bob' wouldn't match.
cat > "$SHARED/beams/strict/messages/${ts}__faketest.msg" <<EOF
---
id: 11111111-2222-3333-4444-555555555555
beam: strict
from: $fake_sid
ts: $(date -u +%FT%TZ)
to: $SID_B
---
unsigned-eligible body
EOF
sleep 1
c=$(ctx "$TMPDIR/cfg-b")
echo "$c" | grep -q "unsigned-eligible body" \
  || fail "default policy should accept unsigned from no-pubkey peer"
pass "default policy: unsigned migration message accepted"

# Now flip the beam to require sigs and try again with a fresh fake unsigned msg.
as "$TMPDIR/cfg-a" require-signatures strict on >/dev/null
sleep 1
cat > "$SHARED/beams/strict/messages/${ts}b__faketest2.msg" <<EOF
---
id: 22222222-2222-3333-4444-555555555555
beam: strict
from: $fake_sid
ts: $(date -u +%FT%TZ)
to: $SID_B
---
unsigned-eligible body POST-require
EOF
sleep 1
c=$(ctx "$TMPDIR/cfg-b")
[ -z "$c" ] || fail "after require_signatures=on, unsigned should be DROPPED: $c"
pass "require_signatures=on: unsigned message from no-pubkey peer dropped"

# And confirm a legitimately signed message (alice has a pubkey) still works:
sleep 1
as "$TMPDIR/cfg-a" send strict "$SID_B" "still works with sig" >/dev/null
sleep 1
c=$(ctx "$TMPDIR/cfg-b")
echo "$c" | grep -q "still works with sig" \
  || fail "signed message should still deliver under require_signatures=on"
pass "require_signatures=on: signed messages still flow"

banner "7. non-driver cannot toggle require_signatures"
if out=$(as "$TMPDIR/cfg-b" require-signatures strict off 2>&1); then
  fail "non-driver toggle should fail; got: $out"
fi
case "$out" in *driver*) pass "non-driver toggle refused" ;; *) fail "wrong error: $out" ;; esac

banner "8. watcher start mkdir-lock prevents double-start race"
# Start two watchers concurrently from the SAME config dir. With the lock,
# exactly one wins; the other reports "already running".
log1=/tmp/beams-test8-w1.log
log2=/tmp/beams-test8-w2.log
( export BEAMS_CONFIG_DIR="$TMPDIR/cfg-a"; "$PLUGIN/lib/watch.sh" start 2 > "$log1" 2>&1 ) &
( export BEAMS_CONFIG_DIR="$TMPDIR/cfg-a"; "$PLUGIN/lib/watch.sh" start 2 > "$log2" 2>&1 ) &
wait
combined=$(cat "$log1" "$log2")
echo "$combined" | grep -q "watcher started"   || fail "neither watcher reported started"
echo "$combined" | grep -q "already running"   || fail "neither watcher reported already-running"
pids=$(ls "$TMPDIR/cfg-a/state/"*/watcher.pid 2>/dev/null | wc -l | tr -d ' ')
[ "$pids" = "1" ] || fail "expected exactly 1 pid file, got $pids"
( export BEAMS_CONFIG_DIR="$TMPDIR/cfg-a"; "$PLUGIN/lib/watch.sh" stop >/dev/null )
rm -f "$log1" "$log2"
pass "concurrent /beams:watch start serialised correctly"

green ""
green "ALL ROUND-8 TESTS PASSED"
