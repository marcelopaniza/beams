#!/usr/bin/env bash
# SessionStart hook: when a Claude Code session starts (or resumes / clears),
# surface any unread beam messages addressed to this session as context — the
# same zero-token-when-idle pull the UserPromptSubmit hook does, just at boot,
# so the session greets you already aware of the beam. Silent + ~0 tokens when
# there's nothing waiting; never blocks or fails session start.
#
# Opt-in extra: if this session set react.watch_on_boot=true (e.g. via
# `/beams:init --profile responder`), also start the background notifier daemon
# idempotently — so desktop notifications / the Channels bridge come up without
# the user remembering `/beams:watch start`.
#
# Like the other hooks, a missing config (a terminal that never ran
# /beams:init) makes this a silent no-op: beams stays invisible to non-users.

set -uo pipefail

# Drain stdin (Claude Code passes SessionStart JSON we don't consume).
cat >/dev/null 2>&1 || true

# Be paranoid: a misconfigured hook must never break the user's session.
{
  root="${CLAUDE_PLUGIN_ROOT:-}"
  [ -x "$root/lib/check.sh" ]      || exit 0
  command -v jq    >/dev/null 2>&1 || exit 0
  command -v find  >/dev/null 2>&1 || exit 0

  # Source common.sh for correct per-terminal config resolution. (The hot
  # UserPromptSubmit fast path reproduces a looser version inline for speed;
  # SessionStart fires once per session, so we can afford the real thing.)
  # shellcheck source=../lib/common.sh
  source "$root/lib/common.sh" 2>/dev/null || exit 0
  beams::config_exists || exit 0   # not a beams session → stay silent

  # Pull unread FIRST — this advances the NOTIFY cursor too, so the notifier
  # daemon we may start next won't re-notify messages we just surfaced at boot.
  out=$("$root/lib/check.sh" --hook SessionStart 2>/dev/null) || out=""

  # Opt-in: bring up the notifier daemon on boot. Idempotent (watch.sh no-ops
  # when one is already running), detached, and fully silenced so its "watcher
  # started" line never leaks into the session context. Pin BEAMS_CONFIG_DIR so
  # the daemon resolves the exact same identity this hook just did.
  if [ "$(beams::react_flag watch_on_boot)" = "true" ]; then
    export BEAMS_CONFIG_DIR
    nohup bash "$root/lib/watch.sh" start >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
  fi

  [ -n "$out" ] && printf '%s' "$out"
} 2>/dev/null

exit 0
