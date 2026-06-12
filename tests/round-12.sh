#!/usr/bin/env bash
# Regression test for the hook stash censorship vulnerability.
#
# Bug (Opus N2, security review 2026-05-24):
#   hooks/check-messages.sh fast-path iterated over `stash_beams` and exited
#   0 with all_match=1 if every cached beam mtime matched current. An empty
#   stash_beams yielded vacuous all_match=1 → silent message drop. A peer
#   (or stash forgery) could write a stash containing only
#     cfg=$current_mtime
#     shared=$shared
#   with NO `b=` lines, and the fast path then delivered nothing until the
#   victim happened to modify config.json. The same primitive worked in
#   subtler form by including only some beams, allowing targeted censorship
#   of any chosen beam.
#
# Fix: in the fast path, cross-check the cached beam list against the
# authoritative `jq .beams` from config.json. Mismatch (including an
# all-empty stash with a non-empty config) forces fall-through to the
# slow path, which uses the authoritative beam list and delivers the
# messages.

set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEST_TMPDIR=$(mktemp -d /tmp/beams-test-r12.XXXXXX)
SHARED="$TEST_TMPDIR/share"
CFG_A="$TEST_TMPDIR/cfg-a"
CFG_B="$TEST_TMPDIR/cfg-b"

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
as_a init "$SHARED"  >/dev/null
as_b init "$SHARED"  >/dev/null
as_a name alice      >/dev/null
as_b name bob        >/dev/null
as_a create critical >/dev/null
as_a join   critical >/dev/null
as_b join   critical >/dev/null
pass "alice and bob on beam 'critical'"

banner "2. bob sends a real message addressed to alice"
as_b send critical alice "important-urgent-message-canary" >/dev/null
sleep 0.3
pass "bob sent message"

banner "3. attacker plants a curated empty-beam-list stash for alice"
mkdir -p "$CFG_A/state"
cfg_mtime=$(stat -c %Y "$CFG_A/config.json")
cat > "$CFG_A/state/hook-mtime-stash" <<EOF
cfg=$cfg_mtime
shared=$SHARED
EOF
pass "planted censorship stash (no b= lines)"

banner "4. fire alice's UserPromptSubmit hook"
hook_out=$(
  export BEAMS_CONFIG_DIR="$CFG_A"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN"
  printf '{}' | "$PLUGIN/hooks/check-messages.sh" 2>/dev/null || true
)

banner "5. ASSERT hook delivered bob's message despite the censorship stash"
if printf '%s' "$hook_out" | grep -qF "important-urgent-message-canary"; then
  pass "hook delivered the message — censorship attack failed"
else
  red "  hook output:"
  printf '%s\n' "$hook_out" | sed 's/^/    /' >&2
  red "  alice's inbox state:"
  ls -la "$SHARED/beams/critical/messages/" 2>&1 | sed 's/^/    /' >&2
  fail "hook returned no content for bob's message — censorship attack succeeded"
fi

green ""
green "round-12 PASS: hook fast-path cross-checks stash against config"
