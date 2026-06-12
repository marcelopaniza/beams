#!/usr/bin/env bash
# Round 23 — TOFU key pinning + fmt-2 from_name signing (the v0.10.2 CRITICAL fix).
#
# The hole this closes: msg_validate used to fetch the verifying pubkey straight
# from the shared, attacker-writable member record. So anyone who could write
# the share could overwrite a victim's members/<uuid>.json — substitute their
# own key (impersonate) or drop the key (downgrade to unsigned) — and speak as
# the victim. Now the verifying key is PINNED locally on first contact; a later
# substitution/removal can't impersonate or downgrade. fmt-2 additionally signs
# from_name so a third party can't relabel someone's signed message.
#
# Cases:
#   1. first contact verifies, delivers, and PINS the sender's key
#   2. continued legit messages keep verifying against the pin
#   3. fmt-2 from_name relabel by a third party is rejected (sig covers from_name)
#   4. CRITICAL: pubkey substitution in the shared member record cannot
#      impersonate a pinned sender
#   5. downgrade (drop the shared pubkey + send unsigned) cannot impersonate a
#      pinned sender

set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r23.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"        # hermetic TOFU known_keys store
SHARED="$TMP/share"
CFG_A="$TMP/cfg-a"; CFG_B="$TMP/cfg-b"; CFG_M="$TMP/cfg-m"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
trap 'rm -rf "$TMP"' EXIT

as()  { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
ctx() { ( export BEAMS_CONFIG_DIR="$1"; export CLAUDE_PLUGIN_ROOT="$PLUGIN"
          "$PLUGIN/hooks/check-messages.sh" </dev/null
        ) | jq -r '.hookSpecificOutput.additionalContext // ""'; }

command -v openssl >/dev/null 2>&1 || { echo "  (skipped — no openssl)"; exit 0; }

mkdir -p "$SHARED"
as "$CFG_A" init "$SHARED" >/dev/null; as "$CFG_A" name alice   >/dev/null
as "$CFG_B" init "$SHARED" >/dev/null; as "$CFG_B" name bob     >/dev/null
as "$CFG_M" init "$SHARED" >/dev/null; as "$CFG_M" name mallory >/dev/null
SID_A=$(jq -r .session_id "$CFG_A/config.json")
SID_M=$(jq -r .session_id "$CFG_M/config.json")
as "$CFG_A" create general >/dev/null
for c in "$CFG_A" "$CFG_B" "$CFG_M"; do as "$c" join general >/dev/null; done
MSG_DIR="$SHARED/beams/general/messages"
MEM_A="$SHARED/beams/general/members/$SID_A.json"
PIN_A="$XDG_CONFIG_HOME/beams/known_keys/$SID_A"

# ── 1. first contact verifies, delivers, and pins ───────────────────────────
banner "1. first contact delivers and pins the sender's key"
sleep 1
as "$CFG_A" send general bob "first contact from alice" >/dev/null
sleep 1
c=$(ctx "$CFG_B")
echo "$c" | grep -q "first contact from alice" || fail "first-contact message not delivered"
[ -f "$PIN_A" ] || fail "alice's key was not pinned at $PIN_A"
# the pin must equal alice's published pubkey
[ "$(cat "$PIN_A")" = "$(jq -r .public_key "$MEM_A")" ] || fail "pinned key != alice's real pubkey"
pass "first contact delivered + alice's key pinned"

# ── 2. continued legit messages keep verifying against the pin ──────────────
banner "2. a second legit message still verifies (against the pin)"
sleep 1
as "$CFG_A" send general bob "second legit message" >/dev/null
sleep 1
ctx "$CFG_B" | grep -q "second legit message" || fail "legit follow-up was wrongly rejected"
pass "continued legit delivery works"

# ── 3. third-party from_name relabel is rejected (fmt-2 signs from_name) ─────
banner "3. a third-party from_name relabel is rejected"
sleep 1
as "$CFG_A" send general bob "relabel target body" >/dev/null
sleep 1
victim=$(ls -t "$MSG_DIR"/*.msg | head -1)
grep -q '^fmt: 2' "$victim" || fail "expected fmt-2 message from a 0.10.2 sender"
# attacker rewrites the (signed) from_name in place
sed -i 's/^from_name: .*/from_name: TOTALLY-LEGIT-BOSS/' "$victim"
c=$(ctx "$CFG_B")
echo "$c" | grep -q "relabel target body" \
  && fail "a from_name-tampered message was delivered — fmt-2 did not protect from_name"
pass "from_name relabel broke the signature → message rejected"

# ── 4. CRITICAL: pubkey substitution can't impersonate a pinned sender ──────
banner "4. CRITICAL — substituting alice's published pubkey cannot impersonate her"
MAL_PUB=$(jq -r .public_key "$SHARED/beams/general/members/$SID_M.json")
# attacker overwrites alice's member record with MALLORY's pubkey
tmp=$(mktemp); jq --arg k "$MAL_PUB" '.public_key=$k' "$MEM_A" > "$tmp" && mv "$tmp" "$MEM_A"
# attacker forges a message "from alice", signed with MALLORY's key, over the
# exact fmt-2 canonical beams uses (NUL-separated id,beam,from,from_name,to,ts + body)
IMP_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
IMP_TS="2026-06-02T12:00:00Z"
IMP_BODY="MALLORY SPEAKING AS ALICE"
{ printf '%s\0' "$IMP_ID" general "$SID_A" alice bob "$IMP_TS"; printf '%s' "$IMP_BODY"; } > "$TMP/canon"
imp_sig=$(openssl pkeyutl -sign -inkey "$CFG_M/identity.key" -rawin -in "$TMP/canon" 2>/dev/null | base64 | tr -d '\n')
[ -n "$imp_sig" ] || fail "could not build the forged signature"
cat > "$MSG_DIR/20990101T000001Z__imp.msg" <<EOF
---
fmt: 2
id: $IMP_ID
beam: general
from: $SID_A
from_name: alice
to: bob
ts: $IMP_TS
sig: $imp_sig
---
$IMP_BODY
EOF
c=$(ctx "$CFG_B")
echo "$c" | grep -q "MALLORY SPEAKING AS ALICE" \
  && fail "pubkey substitution impersonated alice — TOFU pin was not enforced"
pass "substituted shared pubkey ignored; impersonation rejected (verified against the pin)"

# ── 5. downgrade (drop pubkey + unsigned) can't impersonate a pinned sender ─
banner "5. downgrade to unsigned cannot impersonate a pinned sender"
tmp=$(mktemp); jq 'del(.public_key)' "$MEM_A" > "$tmp" && mv "$tmp" "$MEM_A"
cat > "$MSG_DIR/20990101T000002Z__dg.msg" <<EOF
---
id: bbbbbbbb-cccc-dddd-eeee-ffffffffffff
beam: general
from: $SID_A
from_name: alice
to: bob
ts: 2026-06-02T12:01:00Z
---
UNSIGNED MALLORY AS ALICE
EOF
c=$(ctx "$CFG_B")
echo "$c" | grep -q "UNSIGNED MALLORY AS ALICE" \
  && fail "unsigned downgrade impersonated alice — pinned sender must require a sig"
pass "unsigned downgrade rejected (a pinned sender always requires a valid signature)"

green ""
green "round-23 PASS: TOFU pins on first contact; pubkey substitution + unsigned downgrade can no longer impersonate a pinned sender; fmt-2 protects from_name from third-party relabeling"
