#!/usr/bin/env bash
# Stop hook: when a session finishes a turn while new beam messages are waiting,
# block the stop and hand Claude the inbox as its next instruction (the Stop
# `reason` is fed back to Claude verbatim), so an active session surfaces /
# responds without the user having to re-type. Surface-and-let-the-session-
# decide: the injected text tells Claude to respond on the beam ONLY if this
# session's role calls for it.
#
# OPT-IN. Does nothing unless this session set react.on_stop=true (e.g. via
# `/beams:init --profile responder`). A plain session never burns an extra turn.
#
# Loop-safe on three counts: (1) Claude Code sets stop_hook_active=true once
# we've triggered a continuation, and we exit early on it; (2) check.sh --stop
# advances the cursor on delivery, so the follow-up turn has nothing left to
# re-block; (3) Claude Code caps Stop blocks at 8 in a row as a final backstop.

set -uo pipefail

# Stop hook JSON arrives on stdin; we need stop_hook_active out of it.
input=$(cat 2>/dev/null || true)

{
  root="${CLAUDE_PLUGIN_ROOT:-}"
  [ -x "$root/lib/check.sh" ]   || exit 0
  command -v jq >/dev/null 2>&1 || exit 0

  # Loop guard: if we already triggered this continuation, let the turn end.
  active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
  [ "$active" = "true" ] && exit 0

  # Resolve this session's identity the SAME way every other entry point does.
  # That now follows a restart-safe name binding (sessions/<id>/bound →
  # projects/<project>/identities/<name>); an inline shortcut would miss it and
  # silently stop delivering to bound sessions. Sourcing common.sh costs a few
  # ms per turn-end; the opt-in gate still short-circuits a non-opted-in session
  # before any real work, and check.sh below reuses the same resolution.
  source "$root/lib/common.sh" 2>/dev/null || exit 0
  beams::config_exists || exit 0
  [ "$(beams::react_flag on_stop)" = "true" ] || exit 0

  # Opted in. Pin the resolved identity for the check.sh child, then render the
  # Stop block (or nothing, when no message is actually waiting).
  export BEAMS_CONFIG_DIR
  out=$("$root/lib/check.sh" --stop 2>/dev/null) || exit 0
  [ -n "$out" ] && printf '%s' "$out"
} 2>/dev/null

exit 0
