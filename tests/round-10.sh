#!/usr/bin/env bash
# Regression test for the /buses:send slash-command injection bug.
#
# Bug: commands/send.md invoked lib/send.sh as `"$LIB/send.sh" "$ARGUMENTS"`.
# Claude Code substitutes $ARGUMENTS at .md-template time, BEFORE bash parses
# the script. The resulting bash source has the user's message body sitting
# inside double quotes, where $() and backticks ARE still expanded by bash.
# A malicious or careless body like `hi $(touch /tmp/x)` therefore executed
# the touch on the SENDER's machine while the message was being sent.
#
# Fix: route $ARGUMENTS through a quoted-delimiter heredoc piped to
# lib/send.sh --from-stdin. Quoted heredocs suppress ALL expansion, so the
# body lands verbatim in the message file and nothing executes locally.
#
# This test simulates Claude Code's substitution by reading the !-block of
# commands/send.md, splicing the malicious payload into the $ARGUMENTS token,
# and bash-exec'ing the result. It asserts (a) no side-effect marker file
# was created, and (b) the message body stored on the bus equals the
# literal attacker payload.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEST_TMPDIR=$(mktemp -d /tmp/buses-test-r10.XXXXXX)
SHARED="$TEST_TMPDIR/share"
CFG_A="$TEST_TMPDIR/cfg-a"
CFG_B="$TEST_TMPDIR/cfg-b"
MARKER="$TEST_TMPDIR/PWNED_via_dollar_paren"
MARKER_BT="$TEST_TMPDIR/PWNED_via_backtick"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

as_a() { ( export BUSES_CONFIG_DIR="$CFG_A"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }
as_b() { ( export BUSES_CONFIG_DIR="$CFG_B"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }

# ----------------------------------------------------------------------------
banner "1. set up two sessions on a fresh shared dir"
mkdir -p "$SHARED"
as_a init "$SHARED" >/dev/null
as_b init "$SHARED" >/dev/null
as_a name "alice" >/dev/null
as_b name "bob"   >/dev/null
as_a create general >/dev/null
as_a join   general >/dev/null
as_b join   general >/dev/null
pass "alice and bob both on bus 'general'"

# ----------------------------------------------------------------------------
banner "2. extract the !-block from commands/send.md"
# Pull the bash payload from between the ```! ... ``` fences.
slash_block=$(awk '
  /^```!/ { in_block=1; next }
  /^```/  { if (in_block) { in_block=0; exit } }
  in_block { print }
' "$PLUGIN/commands/send.md")
[ -n "$slash_block" ] || fail "could not extract !-block from send.md"
printf '%s\n' "$slash_block" | head -3 >&2
pass "extracted !-block ($(printf '%s' "$slash_block" | wc -l) lines)"

# ----------------------------------------------------------------------------
banner "3. craft attacker payload with dollar-paren AND backtick"
# The body contains BOTH expansion forms. If either fires, a marker file
# appears under \$TMPDIR.
ATTACKER_BODY="hello bob this is a normal-looking message \$(touch $MARKER) and \`touch $MARKER_BT\` ok"
ATTACKER_ARGS="general bob $ATTACKER_BODY"
pass "payload: $ATTACKER_ARGS"

# ----------------------------------------------------------------------------
banner "4. simulate Claude Code's \$ARGUMENTS substitution + exec"
# Substitute the LITERAL string '\$ARGUMENTS' in the slash_block with the
# attacker-controlled content, then hand the result to bash -c. This is the
# precise sequence Claude Code performs when the user types a /slash command.
substituted="${slash_block//\$ARGUMENTS/$ATTACKER_ARGS}"

# Run as alice. CLAUDE_PLUGIN_ROOT is what the !-block uses to find send.sh.
rm -f "$MARKER" "$MARKER_BT"
(
  export BUSES_CONFIG_DIR="$CFG_A"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN"
  bash -c "$substituted"
) >"$TEST_TMPDIR/send.out" 2>"$TEST_TMPDIR/send.err" || {
  # Non-zero exit is fine if the send happened or was rejected for a reason
  # other than injection; we check the marker + stored body below.
  :
}
printf 'stdout: %s\n' "$(cat "$TEST_TMPDIR/send.out")" >&2
printf 'stderr: %s\n' "$(cat "$TEST_TMPDIR/send.err")" >&2

# ----------------------------------------------------------------------------
banner "5. ASSERT no injection executed locally"
inj_fail=0
if [ -e "$MARKER" ]; then
  red "  marker $MARKER EXISTS — dollar-paren \$() expansion fired"
  inj_fail=1
fi
if [ -e "$MARKER_BT" ]; then
  red "  marker $MARKER_BT EXISTS — backtick expansion fired"
  inj_fail=1
fi
[ "$inj_fail" -eq 0 ] || fail "injection executed — the bug is present"
pass "no marker files; \$() and backticks were NOT expanded"

# ----------------------------------------------------------------------------
banner "6. ASSERT message body stored verbatim"
msg_file=$(find "$SHARED/buses/general/messages" -name '*.msg' -type f 2>/dev/null | head -1)
[ -n "$msg_file" ] || fail "no message file landed on the bus"
# Pull body (everything after the second `---` line)
body=$(awk '
  /^---$/ { dashes++; next }
  dashes >= 2 { print }
' "$msg_file")
expected_body="$ATTACKER_BODY"
if [ "$body" = "$expected_body" ]; then
  pass "stored body equals attacker payload verbatim"
else
  red "  expected: $expected_body"
  red "  stored:   $body"
  fail "stored body differs — partial expansion or truncation happened"
fi

# ----------------------------------------------------------------------------
banner "7. ASSERT bob can read the message and the body is intact"
bob_inbox=$(as_b check --human 2>/dev/null || true)
if printf '%s' "$bob_inbox" | grep -qF "$ATTACKER_BODY"; then
  pass "bob's inbox contains the literal payload, fully intact"
else
  red "  bob inbox:"; printf '%s\n' "$bob_inbox" | sed 's/^/    /' >&2
  fail "bob's view of the body differs from what was sent"
fi

green ""
green "round-10 PASS: slash-command injection is fixed"
