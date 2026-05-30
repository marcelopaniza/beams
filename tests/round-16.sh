#!/usr/bin/env bash
# Round 16: proactive delivery hooks (v0.9.0).
#
# Verifies the SessionStart + Stop hooks added in v0.9.0:
#   1. SessionStart hook surfaces unread as additionalContext (hookEventName
#      "SessionStart").
#   2. It advances the cursor, so it's silent on the next start.
#   3. It's a silent no-op for a session with no buses config.
#   4. The Stop hook does NOTHING by default (react.on_stop unset/false).
#   5. With react.on_stop=true the Stop hook emits {"decision":"block",reason}
#      carrying the inbox when a message arrived.
#   6. The stop_hook_active guard short-circuits (no re-block) AND does not
#      consume the message (a later non-active fire still delivers it).
#   7. Fresh configs default react flags to false; the `responder` preset
#      flips them on.
#
# No daemon, no notifier — pure hook logic, so it stays portable under CI.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/buses-test-r16.XXXXXX)
SHARED="$TMPDIR/share"
CFG_A="$TMPDIR/cfg-a"        # alice — recipient, runs the hooks
CFG_B="$TMPDIR/cfg-b"        # bob   — sender
CFG_C="$TMPDIR/cfg-c"        # carol — responder-preset session
CFG_NONE="$TMPDIR/cfg-none"  # never initialised

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() {
  # Kill any watcher the responder-preset path may have spawned.
  for cfg in "$CFG_A" "$CFG_B" "$CFG_C"; do
    for f in "$cfg"/state/*/watcher.pid; do
      [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
    done
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

run_as() { ( export BUSES_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
as_a() { run_as "$CFG_A" "$@"; }
as_b() { run_as "$CFG_B" "$@"; }

# Run a hook script with a given identity + stdin JSON, exactly as Claude Code
# would: CLAUDE_PLUGIN_ROOT set, the hook payload on stdin.
hook() {
  # $1 = config dir, $2 = hook script basename, $3 = stdin JSON (may be empty)
  ( export CLAUDE_PLUGIN_ROOT="$PLUGIN" BUSES_CONFIG_DIR="$1"
    printf '%s' "${3:-}" | "$PLUGIN/hooks/$2" )
}

mkdir -p "$SHARED"

banner "init alice (recipient) + bob (sender) on bus r16-bus"
as_a init "$SHARED" >/dev/null
as_b init "$SHARED" >/dev/null
as_a name alice >/dev/null
as_b name bob   >/dev/null
as_b create r16-bus >/dev/null
as_b join   r16-bus >/dev/null
as_a join   r16-bus >/dev/null
pass "alice + bob subscribed"

# ── 1. SessionStart surfaces unread ────────────────────────────────────────
banner "SessionStart hook surfaces unread as additionalContext"
as_b send r16-bus alice "boot-check-msg-one" >/dev/null
out=$(hook "$CFG_A" check-on-start.sh '{"hook_event_name":"SessionStart","source":"startup"}')
[ -n "$out" ] || fail "SessionStart produced no output for a waiting message"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "hookEventName is not SessionStart"; }
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("boot-check-msg-one")' >/dev/null \
  || fail "additionalContext missing the message body"
pass "SessionStart injected the message"

# ── 2. cursor advanced → silent next time ──────────────────────────────────
banner "SessionStart is silent once the message is delivered"
out=$(hook "$CFG_A" check-on-start.sh '{"source":"startup"}')
[ -z "$out" ] || { echo "$out" | sed 's/^/    /'; fail "SessionStart re-delivered an already-seen message"; }
pass "SessionStart silent after cursor advance"

# ── 3. no config → silent no-op ────────────────────────────────────────────
banner "SessionStart no-ops for a session with no buses config"
out=$(hook "$CFG_NONE" check-on-start.sh '{"source":"startup"}')
[ -z "$out" ] || { echo "$out" | sed 's/^/    /'; fail "SessionStart emitted for a non-buses session"; }
pass "SessionStart silent without config"

# ── 4. Stop hook off by default ────────────────────────────────────────────
banner "Stop hook does nothing when react.on_stop is unset (default)"
sleep 1
as_b send r16-bus alice "stop-msg-default-off" >/dev/null
out=$(hook "$CFG_A" respond-on-stop.sh '{"stop_hook_active":false}')
[ -z "$out" ] || { echo "$out" | sed 's/^/    /'; fail "Stop hook fired without opt-in"; }
pass "Stop hook inert by default"

# ── 5. opt in → Stop delivers a block ──────────────────────────────────────
banner "react.on_stop=true → Stop hook emits decision:block carrying the inbox"
# Flip the flag the way a user (or the responder preset) would.
tmp=$(mktemp); jq '.react.on_stop = true' "$CFG_A/config.json" > "$tmp" && mv "$tmp" "$CFG_A/config.json"
out=$(hook "$CFG_A" respond-on-stop.sh '{"stop_hook_active":false}')
[ -n "$out" ] || fail "Stop hook produced nothing after opt-in (a message was waiting)"
echo "$out" | jq -e '.decision == "block"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "Stop output is not decision:block"; }
echo "$out" | jq -e '.reason | contains("stop-msg-default-off")' >/dev/null \
  || fail "Stop reason missing the waiting message body"
pass "Stop hook delivered block + inbox"

# ── 6. loop guard + non-consumption ────────────────────────────────────────
banner "stop_hook_active guard short-circuits without consuming the message"
sleep 1
as_b send r16-bus alice "guard-msg" >/dev/null
out=$(hook "$CFG_A" respond-on-stop.sh '{"stop_hook_active":true}')
[ -z "$out" ] || { echo "$out" | sed 's/^/    /'; fail "Stop hook blocked despite stop_hook_active=true"; }
# The guarded fire must NOT have advanced the cursor: a normal fire still gets it.
out=$(hook "$CFG_A" respond-on-stop.sh '{"stop_hook_active":false}')
echo "$out" | jq -e '.reason | contains("guard-msg")' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "guarded fire consumed the message (cursor advanced wrongly)"; }
pass "guard short-circuits and preserves the message"

# ── 7. react defaults + responder preset ───────────────────────────────────
banner "fresh config defaults react flags off; responder preset flips them on"
jq -e '.react.watch_on_boot == false and .react.on_stop == false' "$CFG_B/config.json" >/dev/null \
  || fail "fresh config should default react flags to false"
( export BUSES_CONFIG_DIR="$CFG_C"; "$PLUGIN/lib/init.sh" "$SHARED" --profile responder >/dev/null )
jq -e '.role == "responder" and .react.watch_on_boot == true and .react.on_stop == true' "$CFG_C/config.json" >/dev/null \
  || { jq '.' "$CFG_C/config.json" | sed 's/^/    /'; fail "responder preset did not enable react flags"; }
pass "react defaults + responder preset correct"

banner "round 16 complete"
green "ALL ROUND-16 CHECKS PASSED"
