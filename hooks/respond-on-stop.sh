#!/usr/bin/env bash
# Stop hook: when a session finishes a turn while new bus messages are waiting,
# block the stop and hand Claude the inbox as its next instruction (the Stop
# `reason` is fed back to Claude verbatim), so an active session surfaces /
# responds without the user having to re-type. Surface-and-let-the-session-
# decide: the injected text tells Claude to respond on the bus ONLY if this
# session's role calls for it.
#
# OPT-IN. Does nothing unless this session set react.on_stop=true (e.g. via
# `/buses:init --profile responder`). A plain session never burns an extra turn.
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

  # Cheap opt-in gate WITHOUT sourcing common.sh or running check.sh, so a
  # session that didn't opt in pays almost nothing per turn. A Stop hook only
  # ever fires inside Claude Code, so the config is at exactly one of:
  #   $BUSES_CONFIG_DIR (explicit override), or
  #   <xdg>/buses/sessions/$CLAUDE_CODE_SESSION_ID  (the per-terminal default).
  # The non-Claude terminals/projects fallbacks in common.sh can't apply here,
  # so this inline resolution is complete for the hook's runtime context.
  cfgdir="${BUSES_CONFIG_DIR:-}"
  if [ -z "$cfgdir" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/buses/sessions/$CLAUDE_CODE_SESSION_ID"
  fi
  [ -n "$cfgdir" ] && [ -f "$cfgdir/config.json" ] || exit 0
  [ "$(jq -r '.react.on_stop // false' "$cfgdir/config.json" 2>/dev/null)" = "true" ] || exit 0

  # Opted in. Pin check.sh to the exact identity we just gated on, then render
  # the Stop block (or nothing, when no message is actually waiting).
  export BUSES_CONFIG_DIR="$cfgdir"
  out=$("$root/lib/check.sh" --stop 2>/dev/null) || exit 0
  [ -n "$out" ] && printf '%s' "$out"
} 2>/dev/null

exit 0
