#!/usr/bin/env bash
# Regression test for the --profile mechanism on /beams:init.
#
# Feature (v0.7.4): /beams:init <shared> --profile <name> reads
# presets/<name>.json from the plugin root and applies overlays after the
# standard init:
#   - default_name (string)        → set session name
#   - role         (string)        → write into config.json
#   - auto_subscribe (array)       → /beams:join each beam
#
# Profile name must match [A-Za-z0-9_-]+ — reject path traversal, dotfiles,
# slashes, leading dash, etc. before touching any state.
#
# This round verifies the `hermes` preset (presets/hermes.json) — Jose-
# flavoured defaults: name=jose, role=hermes, auto_subscribe=[all].

set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEST_TMPDIR=$(mktemp -d /tmp/beams-test-r14.XXXXXX)
SHARED="$TEST_TMPDIR/share"
CFG="$TEST_TMPDIR/cfg"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

run_init() {
  ( export BEAMS_CONFIG_DIR="$CFG"; "$PLUGIN/lib/init.sh" "$@" )
}

banner "1. init with --profile hermes on a fresh shared dir"
mkdir -p "$SHARED"
out=$(run_init "$SHARED" --profile hermes)
printf '%s\n' "$out" | sed 's/^/  /' >&2
pass "init returned ok"

banner "2. session name is 'jose' (preset default_name)"
name=$(jq -r '.session_name // ""' "$CFG/config.json")
[ "$name" = "jose" ] || fail "expected session_name='jose', got '$name'"
pass "session_name=jose"

banner "3. role field is 'hermes' in config.json"
role=$(jq -r '.role // ""' "$CFG/config.json")
[ "$role" = "hermes" ] || fail "expected role='hermes', got '$role'"
pass "role=hermes"

banner "4. auto-subscribed to beam 'all'"
sub=$(jq -r '.beams[]? // empty' "$CFG/config.json" | sort | paste -sd ',' -)
case ",$sub," in
  *,all,*) pass "subscribed to 'all' (full list: $sub)" ;;
  *)       fail "expected to be subscribed to 'all', got: $sub" ;;
esac

banner "5. profile summary appears in init output"
if printf '%s' "$out" | grep -qE 'profile:\s+hermes'; then
  pass "init output mentions profile"
else
  fail "init output did not mention profile"
fi

banner "6. invalid profile names are rejected before any state change"
CFG2="$TEST_TMPDIR/cfg2"
SHARED2="$TEST_TMPDIR/share2"
mkdir -p "$SHARED2"
for bad in '../etc/passwd' '/abs/path' '.hidden' '-flag' 'has space' 'with;semicolon' '$(ls)'; do
  if ( export BEAMS_CONFIG_DIR="$CFG2"; "$PLUGIN/lib/init.sh" "$SHARED2" --profile "$bad" ) >/dev/null 2>&1; then
    fail "init accepted invalid profile name: '$bad'"
  fi
done
[ ! -e "$CFG2/config.json" ] || fail "init created config despite invalid profile"
pass "all 7 malformed profile names rejected; no config side-effects"

banner "7. unknown profile name fails cleanly"
CFG3="$TEST_TMPDIR/cfg3"
SHARED3="$TEST_TMPDIR/share3"
mkdir -p "$SHARED3"
if ( export BEAMS_CONFIG_DIR="$CFG3"; "$PLUGIN/lib/init.sh" "$SHARED3" --profile no-such-profile-xyz ) >/dev/null 2>&1; then
  fail "init accepted nonexistent profile name"
fi
[ ! -e "$CFG3/config.json" ] || fail "init created config despite unknown profile"
pass "unknown profile rejected; no config side-effects"

green ""
green "round-14 PASS: --profile mechanism + hermes preset"
