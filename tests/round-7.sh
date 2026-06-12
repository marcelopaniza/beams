#!/usr/bin/env bash
# Round 7: Ed25519 signing — keys, sign/verify, forgery defence, tamper detection.
set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test7.XXXXXX)
export XDG_CONFIG_HOME="$TMPDIR/xdg"   # keep TOFU known_keys hermetic on direct runs
SHARED="$TMPDIR/share"
CFG_A="$TMPDIR/cfg-a"
CFG_B="$TMPDIR/cfg-b"
CFG_M="$TMPDIR/cfg-mallory"

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

mkdir -p "$SHARED"
as "$CFG_A" init "$SHARED" >/dev/null
as "$CFG_B" init "$SHARED" >/dev/null
as "$CFG_M" init "$SHARED" >/dev/null
as "$CFG_A" name alice   >/dev/null
as "$CFG_B" name bob     >/dev/null
as "$CFG_M" name mallory >/dev/null
SID_A=$(jq -r .session_id "$CFG_A/config.json")
SID_B=$(jq -r .session_id "$CFG_B/config.json")
SID_M=$(jq -r .session_id "$CFG_M/config.json")

as "$CFG_A" create general >/dev/null
as "$CFG_A" join general >/dev/null
as "$CFG_B" join general >/dev/null
as "$CFG_M" join general >/dev/null

MSG_DIR="$SHARED/beams/general/messages"

banner "1. each session has its own private key at init"
for cfg in "$CFG_A" "$CFG_B" "$CFG_M"; do
  [ -f "$cfg/identity.key" ] || fail "$cfg missing identity.key"
  mode=$(stat -c '%a' "$cfg/identity.key")
  [ "$mode" = "600" ] || fail "$cfg/identity.key mode is $mode (expected 600)"
done
# Keys must differ.
diff -q "$CFG_A/identity.key" "$CFG_B/identity.key" >/dev/null \
  && fail "alice and bob share the same private key" || true
pass "3 distinct private keys, all chmod 600"

banner "2. public keys are published in member records and they all differ"
pub_a=$(jq -r .public_key "$SHARED/beams/general/members/$SID_A.json")
pub_b=$(jq -r .public_key "$SHARED/beams/general/members/$SID_B.json")
pub_m=$(jq -r .public_key "$SHARED/beams/general/members/$SID_M.json")
for p in "$pub_a" "$pub_b" "$pub_m"; do
  [ -n "$p" ] && [ "$p" != "null" ] || fail "missing pubkey in a member record"
done
[ "$pub_a" != "$pub_b" ] && [ "$pub_b" != "$pub_m" ] && [ "$pub_a" != "$pub_m" ] \
  || fail "pubkeys collided across sessions"
pass "all three pubkeys published and distinct"

banner "3. a real signed send round-trips end-to-end"
sleep 1
as "$CFG_A" send general bob "signed hello from alice" >/dev/null
sleep 1
c=$(ctx "$CFG_B")
echo "$c" | grep -q "signed hello from alice" || fail "signed message not delivered"
# And the actual file does include a sig: line
msg=$(ls "$MSG_DIR/"*.msg | tail -1)
grep -q '^sig: ' "$msg" || fail "sent message lacks sig field"
pass "signed message delivered + sig field present in file"

banner "4. tampering the body invalidates the signature → message dropped"
sleep 1
as "$CFG_A" send general bob "I will be tampered" >/dev/null
sleep 1
tampered=$(ls -t "$MSG_DIR/"*.msg | head -1)
# Rewrite body in place
sed -i 's/I will be tampered/HAHA REPLACED BY ATTACKER/' "$tampered"
c=$(ctx "$CFG_B")
echo "$c" | grep -q "REPLACED" \
  && fail "tampered message leaked through — signature check is broken"
pass "body tamper detected (sig verify rejected)"

banner "5. mallory forging alice's identity is rejected"
# Mallory writes a message claiming `from: alice's UUID`, signed with HER key.
# Receiver looks up alice's pubkey (the real one), tries to verify Mallory's
# signature → fails → message dropped.
sleep 1
forged="$MSG_DIR/20991231T000099Z__forged.msg"
fake_body="mallory pretending to be alice"
canonical=$(printf 'fffffff0-aaaa-bbbb-cccc-aaaaaaaaaaaa\ngeneral\n%s\nbob\n2026-05-17T13:00:00Z\n%s' "$SID_A" "$fake_body")
sig=$(printf '%s' "$canonical" | openssl pkeyutl -sign -inkey "$CFG_M/identity.key" -rawin -in /dev/stdin 2>/dev/null | base64 -w0) || {
  # openssl 3.x needs file input, fallback:
  printf '%s' "$canonical" > "$TMPDIR/forge_msg"
  sig=$(openssl pkeyutl -sign -inkey "$CFG_M/identity.key" -rawin -in "$TMPDIR/forge_msg" 2>/dev/null | base64 -w0)
}
cat > "$forged" <<EOF
---
id: fffffff0-aaaa-bbbb-cccc-aaaaaaaaaaaa
beam: general
from: $SID_A
to: bob
ts: 2026-05-17T13:00:00Z
sig: $sig
---
$fake_body
EOF
c=$(ctx "$CFG_B")
echo "$c" | grep -q "mallory pretending" && fail "forged from-alice message leaked"
pass "forged sender identity rejected (signature didn't match alice's pubkey)"

banner "6. mallory's own legitimately signed message DOES deliver"
sleep 1
as "$CFG_M" send general bob "legitimate from mallory" >/dev/null
sleep 1
c=$(ctx "$CFG_B")
echo "$c" | grep -q "legitimate from mallory" \
  || fail "mallory's own signed send should be accepted"
pass "honest signed message from a real member delivers"

banner "7. swapping someone else's valid signature into another message also fails"
sleep 1
# Take alice's last signed message and swap its sig into a NEW different-content file.
last_alice_msg=$(ls -t "$MSG_DIR/"*.msg | grep -v forged | head -1)
real_sig=$(awk '/^sig: /{sub(/^sig: /,""); print; exit}' "$last_alice_msg")
swap="$MSG_DIR/20991231T000100Z__swap.msg"
cat > "$swap" <<EOF
---
id: aaaaaaaa-1234-1234-1234-aaaaaaaaaaaa
beam: general
from: $SID_A
to: bob
ts: 2026-05-17T13:00:00Z
sig: $real_sig
---
totally different content the sig wasn't for
EOF
c=$(ctx "$CFG_B")
echo "$c" | grep -q "totally different content" \
  && fail "sig-swap attack leaked — signature should not match new canonical"
pass "sig-swap attack rejected (sig binds to specific canonical)"

banner "8. fingerprint is stable across calls within a session"
fp1=$( export BEAMS_CONFIG_DIR="$CFG_A"; . "$PLUGIN/lib/common.sh"; beams::fingerprint )
fp2=$( export BEAMS_CONFIG_DIR="$CFG_A"; . "$PLUGIN/lib/common.sh"; beams::fingerprint )
[ "$fp1" = "$fp2" ] && [ -n "$fp1" ] || fail "fingerprint should be stable: $fp1 vs $fp2"
pass "fingerprint stable: $fp1"

banner "9. /beams:status shows fingerprint"
out=$(as "$CFG_A" status)
echo "$out" | grep -q "fingerprint:" || fail "status missing fingerprint line"
echo "$out" | grep -q "$fp1"          || fail "status fingerprint doesn't match: got '$(echo "$out" | grep fingerprint)'"
pass "/beams:status reveals fingerprint"

banner "10. ts field with colons survives the round trip (the bug that triggered round 7)"
sleep 1
as "$CFG_A" send general bob "ts-roundtrip test" >/dev/null
sleep 1
last=$(ls -t "$MSG_DIR/"*.msg | grep -v -e forged -e swap | head -1)
ts_value=$(awk '/^ts: /{sub(/^ts: /,""); print; exit}' "$last")
case "$ts_value" in
  *Z) pass "ts preserved end-to-end: $ts_value" ;;
  *) fail "ts looks truncated: '$ts_value'" ;;
esac

green ""
green "ALL ROUND-7 TESTS PASSED"
