#!/usr/bin/env bash
# Round 17 — /beams:admin dispatcher.
#
# v0.9.x consolidated the rare driver-only and maintenance slash commands
# behind a single /beams:admin <subcommand> router (lib/admin.sh), shrinking
# the slash menu to 8 everyday commands + admin. This round proves the router:
#   - forwards "$ARGUMENTS" as one string to the right lib (init/create/leave)
#   - keeps the members/riders alias
#   - prints usage on no-args and exits 0
#   - rejects unknown subcommands with a sanitised, capped, ESC-free hint
#   - leaves each lib's own config/driver enforcement intact
#
# Injection safety for the stdin verbs (kick/lock) is covered by round-13,
# which drives the attack through commands/admin.md.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEST_TMPDIR=$(mktemp -d /tmp/beams-test-r17.XXXXXX)
SHARED="$TEST_TMPDIR/share"
CFG_A="$TEST_TMPDIR/cfg-a"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() { rm -rf "$TEST_TMPDIR"; }
trap cleanup EXIT

# Drive the router exactly as commands/admin.md does: one quoted "$ARGUMENTS"
# string handed to lib/admin.sh, with this terminal's identity pinned via
# BEAMS_CONFIG_DIR.
admin()    { ( export BEAMS_CONFIG_DIR="$CFG_A"; "$PLUGIN/lib/admin.sh" "$1" ); }
as_alice() { ( export BEAMS_CONFIG_DIR="$CFG_A"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }

banner "1. admin routes 'init' to lib/init.sh"
mkdir -p "$SHARED"
admin "init $SHARED" >/dev/null || fail "admin init exited nonzero"
[ -f "$CFG_A/config.json" ] || fail "admin init did not create config.json"
pass "admin init initialised this terminal"

banner "2. admin routes 'create' to lib/create.sh"
admin "create general" >/dev/null || fail "admin create exited nonzero"
[ -d "$SHARED/beams/general" ] || fail "admin create did not create the beam dir"
pass "admin create made beam 'general'"

banner "3. everyday name + join stay top-level; admin members lists the roster"
as_alice name alice   >/dev/null
as_alice join general >/dev/null
members_out=$(admin "members general")
printf '%s' "$members_out" | grep -q alice || fail "admin members didn't list alice"
pass "admin members lists the roster"

banner "4. members/riders alias parity"
riders_out=$(admin "riders general")
[ "$members_out" = "$riders_out" ] || fail "admin riders output differs from admin members"
pass "admin riders == admin members"

banner "5. no-arg prints usage and exits 0"
usage_out=$(admin "") || fail "admin with no args should exit 0"
printf '%s' "$usage_out" | grep -q 'usage: /beams:admin'            || fail "no-arg usage missing header"
printf '%s' "$usage_out" | grep -q 'Everyday commands stay top-level' || fail "usage missing everyday footer"
pass "no-arg -> usage, exit 0"

banner "6. unknown subcommand -> exit 2, sanitised + capped + ESC-free stderr"
esc=$(printf '\033')
long_bogus="bogus${esc}[31m$(printf 'X%.0s' {1..120})"
set +e
err_out=$( admin "$long_bogus" 2>&1 1>/dev/null )
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown subcommand should exit 2 (got $rc)"
printf '%s' "$err_out" | grep -q 'unknown admin subcommand' || fail "missing 'unknown admin subcommand' hint"
printf '%s' "$err_out" | grep -q "$esc" && fail "raw ESC byte leaked into stderr"
echoed=$(printf '%s' "$err_out" | sed -n 's/^beams: unknown admin subcommand: //p' | head -1)
[ "${#echoed}" -le 40 ] || fail "unknown subcommand echo not capped (${#echoed} chars)"
pass "unknown subcommand -> rc=2, sanitised + capped, no ESC"

banner "7. admin routes 'leave' to lib/leave.sh"
admin "leave general" >/dev/null || fail "admin leave exited nonzero"
subs=$( export BEAMS_CONFIG_DIR="$CFG_A"; jq -r '.beams | length' "$CFG_A/config.json" )
[ "$subs" = "0" ] || fail "admin leave did not unsubscribe (beams=$subs)"
pass "admin leave unsubscribed this terminal"

green ""
green "round-17 PASS: /beams:admin dispatches, aliases, sanitises, and forwards args"
