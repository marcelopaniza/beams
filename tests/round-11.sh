#!/usr/bin/env bash
# Regression test for the hook-mtime-stash symlink-overwrite vulnerability.
#
# Bug (Opus N1, security review 2026-05-24):
#   hooks/check-messages.sh wrote the mtime cache via:
#     { ... } > "$state_dir/hook-mtime-stash.tmp"
#     mv      "$state_dir/hook-mtime-stash.tmp" "$state_dir/hook-mtime-stash"
#   A same-UID peer plants the fixed-name `.tmp` file as a symlink to any
#   victim-writable file. The redirection follows the symlink and truncates+
#   overwrites the target with stash bytes. The plugin's threat model
#   explicitly assumes same-UID peers may be hostile, so this is a real
#   arbitrary-file-overwrite primitive.
#
# Fix: create the tmp file via mktemp under $state_dir, which uses
# O_CREAT|O_EXCL semantics — refuses to overwrite an existing path
# regardless of whether it's a regular file or a symlink.

set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEST_TMPDIR=$(mktemp -d /tmp/beams-test-r11.XXXXXX)
SHARED="$TEST_TMPDIR/share"
CFG_A="$TEST_TMPDIR/cfg-a"
CFG_B="$TEST_TMPDIR/cfg-b"
VICTIM="$TEST_TMPDIR/victim-precious"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

as_a() { ( export BEAMS_CONFIG_DIR="$CFG_A"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }
as_b() { ( export BEAMS_CONFIG_DIR="$CFG_B"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }

banner "1. set up two sessions on a fresh shared dir"
mkdir -p "$SHARED"
as_a init "$SHARED"   >/dev/null
as_b init "$SHARED"   >/dev/null
as_a name alice       >/dev/null
as_b name bob         >/dev/null
as_a create general   >/dev/null
as_a join   general   >/dev/null
as_b join   general   >/dev/null
pass "alice and bob both on beam 'general'"

banner "2. plant a victim file with known content"
victim_content="dont-touch-me-attacker-$(date +%s)"
printf '%s\n' "$victim_content" > "$VICTIM"
victim_hash_before=$(md5sum "$VICTIM" | awk '{print $1}')
pass "victim canary: $VICTIM ($victim_hash_before)"

banner "3. attacker plants the symlink at alice's stash tmp path"
mkdir -p "$CFG_A/state"
attacker_tmp="$CFG_A/state/hook-mtime-stash.tmp"
ln -sf "$VICTIM" "$attacker_tmp"
[ -L "$attacker_tmp" ] || fail "symlink not planted"
pass "planted: $attacker_tmp -> $VICTIM"

banner "4. fire alice's UserPromptSubmit hook"
# No existing stash file → slow path runs → stash refresh writes via the
# tmp path the attacker has poisoned. With pre-fix code, the write follows
# the symlink and overwrites $VICTIM.
(
  export BEAMS_CONFIG_DIR="$CFG_A"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN"
  printf '{}' | "$PLUGIN/hooks/check-messages.sh"
) >/dev/null 2>&1 || true

banner "5. ASSERT victim file content unchanged"
victim_hash_after=$(md5sum "$VICTIM" 2>/dev/null | awk '{print $1}' || echo MISSING)
if [ "$victim_hash_after" = "$victim_hash_before" ]; then
  pass "victim file unchanged (hash=$victim_hash_after) — symlink attack failed"
else
  red "  before: $victim_hash_before"
  red "  after:  $victim_hash_after"
  red "  content now: $(head -3 "$VICTIM" 2>/dev/null)"
  fail "victim file was overwritten — symlink attack succeeded"
fi

green ""
green "round-11 PASS: hook stash write resists symlink-overwrite"
