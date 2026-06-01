#!/usr/bin/env bash
# SessionStart hook: when a Claude Code session starts (or resumes / clears),
# surface any unread beam messages addressed to this session as context — the
# same zero-token-when-idle pull the UserPromptSubmit hook does, just at boot,
# so the session greets you already aware of the beam. Silent + ~0 tokens when
# there's nothing waiting; never blocks or fails session start.
#
# Always-on watcher: unless this session opted out (react.watch_on_boot:false,
# or the BEAMS_DISABLE_WATCH_ON_BOOT=1 env escape hatch for headless/CI/tests),
# also start the background notifier daemon idempotently — so EVERY session gets
# the real-time doorbell without the user remembering `/beams:watch start`. The
# daemon is zero-token (pure polling); the only cost is one background process.
#
# A missing config (a terminal that never ran /beams:init) is normally a silent
# no-op so beams stays invisible to non-users — EXCEPT when this project has
# exactly ONE bindable durable identity (free, or already this terminal's). In
# that case the hook silently rebinds to it (e.g. resuming after a Claude
# restart) instead of ever prompting. Zero identities, two-or-more, or all-busy
# (held by another live session) → still a silent no-op; busy names are never
# stolen (use `/beams:name <n> --force` for a deliberate takeover).

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

  autobound=""
  if ! beams::config_exists; then
    # Unbound session — typically a fresh session id after a Claude restart.
    # Policy ("auto-bind, never ask"): if EXACTLY ONE durable identity in this
    # project is bindable — free (no live holder) or already leased by THIS
    # terminal — silently rebind to it so the session comes back up on its
    # beams with zero prompting. Zero or multiple bindable, or all of them busy
    # with another live session, → stay a silent no-op and never ask. A busy
    # name held by another session is never stolen.
    idnames=$(beams::list_identity_names 2>/dev/null) || idnames=""
    [ -n "$idnames" ] || exit 0          # no identities → not a beams project
    cand=""; n=0
    while IFS= read -r nm; do
      [ -n "$nm" ] || continue
      case "$(beams::lease_state "$(beams::identities_dir)/$nm" 2>/dev/null)" in
        free|mine) cand="$nm"; n=$((n + 1)) ;;
      esac
    done <<< "$idnames"
    [ "$n" -eq 1 ] || exit 0              # ambiguous, or all busy → silent

    # Bind silently. bind_session reassigns the config globals to the identity
    # so the unread pull + watch-on-boot below run as it. Any failure (e.g. no
    # session id in this hook's env) degrades to a silent no-op.
    beams::bind_session "$cand" >/dev/null 2>&1 || exit 0
    autobound="$cand"
  fi

  # Pull unread FIRST — this advances the NOTIFY cursor too, so the notifier
  # daemon we may start next won't re-notify messages we just surfaced at boot.
  out=$("$root/lib/check.sh" --hook SessionStart 2>/dev/null) || out=""

  # Default-on: bring up the notifier daemon on boot so every session has the
  # real-time doorbell. Opt out per-session with react.watch_on_boot:false, or
  # globally with BEAMS_DISABLE_WATCH_ON_BOOT=1 (headless/CI/tests). Idempotent
  # (watch.sh no-ops when one is already running), detached, and fully silenced
  # so its "watcher started" line never leaks into the session context. Pin
  # BEAMS_CONFIG_DIR so the daemon resolves the exact same identity this hook did.
  if [ "${BEAMS_DISABLE_WATCH_ON_BOOT:-}" != "1" ] \
     && [ "$(beams::config_get '.react.watch_on_boot')" != "false" ]; then
    export BEAMS_CONFIG_DIR
    nohup bash "$root/lib/watch.sh" start >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
  fi

  if [ -n "$autobound" ]; then
    # Inform the model who it now is (a statement, not a prompt) and fold in any
    # unread the pull surfaced, so one SessionStart context covers both.
    note="beams: this terminal had no bound identity, so it auto-bound to \"$autobound\" for this project (e.g. resuming after a Claude restart). You are now live on that identity's subscribed beams."
    extra=""
    [ -n "$out" ] && extra=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
    if [ -n "$extra" ]; then ctx=$(printf '%s\n\n%s' "$note" "$extra"); else ctx="$note"; fi
    jq -n --arg ctx "$ctx" \
      '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' 2>/dev/null || true
  else
    [ -n "$out" ] && printf '%s' "$out"
  fi
} 2>/dev/null

exit 0
