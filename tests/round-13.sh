#!/usr/bin/env bash
# Regression test for the slash-command-injection widening to /buses:lock.
#
# Bug (Opus security review 2026-05-24, "patch them all in v0.7.3"):
#   The send.md fix was applied only to commands/send.md. All other
#   commands/*.md files that interpolate $ARGUMENTS via `"$ARGUMENTS"`
#   inside a bash block remained vulnerable to the same class of attack:
#   Claude Code substitutes $ARGUMENTS into the template text BEFORE bash
#   parses, so $() and backticks in user-supplied reason text still fire.
#   /buses:lock and /buses:kick were the highest-risk siblings because
#   their `[reason...]` field is free-form text.
#
# Fix: route $ARGUMENTS through a quoted-delimiter heredoc piped to the
# lib script in --from-stdin mode. Same Pattern B as send.md.
#
# This test exercises lock.md as representative; kick.md uses the same
# pattern and is covered by symmetry.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEST_TMPDIR=$(mktemp -d /tmp/buses-test-r13.XXXXXX)
SHARED="$TEST_TMPDIR/share"
CFG_A="$TEST_TMPDIR/cfg-a"
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

banner "1. set up alice as driver of bus 'general'"
mkdir -p "$SHARED"
as_a init "$SHARED" >/dev/null
as_a name alice     >/dev/null
as_a create general >/dev/null
as_a join   general >/dev/null
pass "alice initialised as driver"

banner "2. extract the !-block from commands/lock.md"
slash_block=$(awk '
  /^```!/ { in_block=1; next }
  /^```/  { if (in_block) { in_block=0; exit } }
  in_block { print }
' "$PLUGIN/commands/lock.md")
[ -n "$slash_block" ] || fail "could not extract !-block from lock.md"
printf '%s\n' "$slash_block" | head -3 >&2
pass "extracted !-block ($(printf '%s' "$slash_block" | wc -l) lines)"

banner "3. craft attacker payload with both dollar-paren and backtick"
ATTACKER_REASON="urgent maintenance \$(touch $MARKER) and \`touch $MARKER_BT\` ok"
ATTACKER_ARGS="general $ATTACKER_REASON"
pass "payload: $ATTACKER_ARGS"

banner "4. simulate Claude Code's \$ARGUMENTS substitution + exec"
substituted="${slash_block//\$ARGUMENTS/$ATTACKER_ARGS}"

rm -f "$MARKER" "$MARKER_BT"
(
  export BUSES_CONFIG_DIR="$CFG_A"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN"
  bash -c "$substituted"
) >"$TEST_TMPDIR/lock.out" 2>"$TEST_TMPDIR/lock.err" || true
printf 'stdout: %s\n' "$(cat "$TEST_TMPDIR/lock.out")" >&2
printf 'stderr: %s\n' "$(cat "$TEST_TMPDIR/lock.err")" >&2

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

banner "6. ASSERT lock manifest stored the reason verbatim"
manifest="$SHARED/buses/general/manifest.json"
[ -f "$manifest" ] || fail "no manifest written"
stored_reason=$(jq -r '.locked.reason // ""' "$manifest")
if [ "$stored_reason" = "$ATTACKER_REASON" ]; then
  pass "stored reason equals attacker payload verbatim"
else
  red "  expected: $ATTACKER_REASON"
  red "  stored:   $stored_reason"
  fail "stored reason differs — partial expansion or truncation happened"
fi

green ""
green "round-13 PASS: /buses:lock resists slash-command injection"
