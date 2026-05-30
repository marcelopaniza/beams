#!/usr/bin/env bash
# Regression test for the hook stash censorship vulnerability.
#
# Bug (Opus N2, security review 2026-05-24):
#   hooks/check-messages.sh fast-path iterated over `stash_buses` and exited
#   0 with all_match=1 if every cached bus mtime matched current. An empty
#   stash_buses yielded vacuous all_match=1 → silent message drop. A peer
#   (or stash forgery) could write a stash containing only
#     cfg=$current_mtime
#     shared=$shared
#   with NO `b=` lines, and the fast path then delivered nothing until the
#   victim happened to modify config.json. The same primitive worked in
#   subtler form by including only some buses, allowing targeted censorship
#   of any chosen bus.
#
# Fix: in the fast path, cross-check the cached bus list against the
# authoritative `jq .buses` from config.json. Mismatch (including an
# all-empty stash with a non-empty config) forces fall-through to the
# slow path, which uses the authoritative bus list and delivers the
# messages.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEST_TMPDIR=$(mktemp -d /tmp/buses-test-r12.XXXXXX)
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

as_a() { ( export BUSES_CONFIG_DIR="$CFG_A"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }
as_b() { ( export BUSES_CONFIG_DIR="$CFG_B"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }

banner "1. set up two sessions on a fresh shared dir"
mkdir -p "$SHARED"
as_a init "$SHARED"  >/dev/null
as_b init "$SHARED"  >/dev/null
as_a name alice      >/dev/null
as_b name bob        >/dev/null
as_a create critical >/dev/null
as_a join   critical >/dev/null
as_b join   critical >/dev/null
pass "alice and bob on bus 'critical'"

banner "2. bob sends a real message addressed to alice"
as_b send critical alice "important-urgent-message-canary" >/dev/null
sleep 0.3
pass "bob sent message"

banner "3. attacker plants a curated empty-bus-list stash for alice"
mkdir -p "$CFG_A/state"
cfg_mtime=$(stat -c %Y "$CFG_A/config.json")
cat > "$CFG_A/state/hook-mtime-stash" <<EOF
cfg=$cfg_mtime
shared=$SHARED
EOF
pass "planted censorship stash (no b= lines)"

banner "4. fire alice's UserPromptSubmit hook"
hook_out=$(
  export BUSES_CONFIG_DIR="$CFG_A"
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
  ls -la "$SHARED/buses/critical/messages/" 2>&1 | sed 's/^/    /' >&2
  fail "hook returned no content for bob's message — censorship attack succeeded"
fi

green ""
green "round-12 PASS: hook fast-path cross-checks stash against config"
