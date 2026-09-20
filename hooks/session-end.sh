#!/usr/bin/env bash
# SessionEnd hook: when a Claude Code session really ends, let go of the in-use
# lease on this terminal's identity, so the next session in this project can
# auto-bind to the name at once instead of waiting out the heartbeat window
# (BEAMS_INUSE_STALE_SECONDS) or proving the holder dead.
#
# Keep the lease on `clear` and `resume`: both keep the SAME Claude process
# alive under a new session id, and the SessionStart hook that follows rebinds
# on the lease's claude_pid (see beams::lease_state) — releasing here would
# turn that certain match into a guess when the project has several names.
#
# Also drops the session's inbox pointer (the native doorbell transport's
# socket + token — see beams::inbox_publish), for the same reason: it describes
# a process that is exiting.
#
# Budget: Claude Code gives SessionEnd hooks ~1.5 s in total, so this does one
# source, two jq calls and one unlink, and nothing else. Silent on every failure.

set -uo pipefail

__hook_in=$(cat 2>/dev/null) || __hook_in=""

{
  root="${CLAUDE_PLUGIN_ROOT:-}"
  [ -f "$root/lib/common.sh" ]  || exit 0
  command -v jq >/dev/null 2>&1 || exit 0

  reason=$(printf '%s' "$__hook_in" | jq -r '.reason // empty' 2>/dev/null) || reason=""
  case "$reason" in clear|resume) exit 0 ;; esac

  # shellcheck source=../lib/common.sh
  source "$root/lib/common.sh" 2>/dev/null || exit 0
  beams::config_exists || exit 0
  beams::lease_release
  # Drop the inbox pointer too: the session socket dies with the Claude process,
  # so leaving it behind would only make the watcher log a dead-socket fallback
  # line and /beams:status advertise a transport that is gone. Kept on
  # clear/resume by the early return above — same process, same socket.
  beams::inbox_forget
} 2>/dev/null

exit 0
