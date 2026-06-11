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
    # Policy: auto-bind silently ONLY when we're certain WHICH identity this is;
    # otherwise surface the choice and let the user pick (never guess, never
    # steal a name a live session still holds).
    idnames=$(beams::list_identity_names 2>/dev/null) || idnames=""
    [ -n "$idnames" ] || exit 0          # no identities → not a beams project

    # Identities this terminal could bind right now: free, or already leased by us.
    bindable=()
    while IFS= read -r nm; do
      [ -n "$nm" ] || continue
      case "$(beams::lease_state "$(beams::identities_dir)/$nm" 2>/dev/null)" in
        free|mine) bindable+=("$nm") ;;
      esac
    done <<< "$idnames"

    cand=""
    if [ "${#bindable[@]}" -eq 0 ]; then
      exit 0                             # all busy (or none) → silent, never steal
    elif [ "${#bindable[@]}" -eq 1 ]; then
      cand="${bindable[0]}"              # unambiguous → silent auto-bind (as before)
    else
      # Several to choose from. Auto-bind ONLY if we're 100% sure which one this
      # is — i.e. this exact terminal (a tmux/screen pane) bound one here before.
      match=$(beams::anchor_lookup 2>/dev/null) || match=""
      if [ -n "$match" ]; then
        for nm in "${bindable[@]}"; do
          [ "$nm" = "$match" ] && { cand="$match"; break; }
        done
      fi
      if [ -z "$cand" ]; then
        # Not sure → surface the choice as context instead of guessing or going
        # silent, so the model can ask. `/beams:name <x>` then binds the pick.
        list=$(printf '%s\n' "${bindable[@]}" | LC_ALL=C sort | sed 's/^/  - /')
        msg=$(printf 'beams: this terminal is not bound to an identity yet, and this project has %s you can use:\n%s\n\nAsk the user which one to use, then run `/beams:name <name>` (or a new name to create one). Until then, beams commands here report "not initialised".' "${#bindable[@]}" "$list")
        jq -n --arg ev SessionStart --arg ctx "$msg" \
          '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
        exit 0
      fi
    fi

    # Bind silently, in a SUBSHELL: bind_session calls beams::die (exit) on
    # recoverable failures (lost the concurrent-bind race → busy, no session id,
    # bad name). A bare call can't catch a function's exit, so the die would
    # crash the hook instead of degrading to the documented silent no-op; the
    # subshell scopes the exit so `|| exit 0` catches it.
    if ( beams::bind_session "$cand" >/dev/null 2>&1 ); then
      autobound="$cand"
      # bind_session reassigned BEAMS_CONFIG_* inside the subshell (lost here);
      # recompute for the now-bound identity so the pull + watch below run as it.
      BEAMS_CONFIG_DIR="$(beams::identities_dir)/$(beams::_safe_key "$cand")"
      BEAMS_CONFIG_FILE="$BEAMS_CONFIG_DIR/config.json"
      BEAMS_IDENTITY_KEY="$BEAMS_CONFIG_DIR/identity.key"
    else
      exit 0
    fi
  fi

  # Pull unread FIRST — this advances the NOTIFY cursor too, so the notifier
  # daemon we may start next won't re-notify messages we just surfaced at boot.
  out=$("$root/lib/check.sh" --hook SessionStart 2>/dev/null) || out=""

  # Default-on: bring up the notifier daemon on boot so every session gets
  # desktop notifications for new beams. Opt out per-session with
  # react.watch_on_boot:false, or globally with BEAMS_DISABLE_WATCH_ON_BOOT=1
  # (headless/CI/tests). Idempotent (watch.sh no-ops when one is already
  # running), detached, and fully silenced so its "watcher started" line never
  # leaks into the session context. Pin BEAMS_CONFIG_DIR so the daemon resolves
  # the exact same identity this hook did.
  # Read the raw value, NOT beams::config_get — config_get appends `// ""`, and
  # jq's `//` treats JSON false as empty, so an explicit watch_on_boot:false
  # would collapse to "" and the `!= "false"` test would WRONGLY arm. Plain jq
  # keeps false/true/null distinct: null/absent → arm (default-on), explicit
  # false → opt out.
  __wob=$(jq -r '.react.watch_on_boot' "$BEAMS_CONFIG_FILE" 2>/dev/null)
  if [ "${BEAMS_DISABLE_WATCH_ON_BOOT:-}" != "1" ] && [ "$__wob" != "false" ]; then
    export BEAMS_CONFIG_DIR
    # Real-time doorbell: when this session was launched with the channel (a
    # channel token is present, or BEAMS_CHANNEL_AUTOWIRE=1 for a token-less/dev
    # setup) AND curl is available, arm the watcher's --on-message hook too, so a
    # new beam WAKES this idle session via a <channel> event instead of only
    # pinging the desktop. The hook (channel/on-message.sh) finds this session's
    # channel-server port from the per-session rendezvous file the server
    # publishes. No channel → the plain notify-only watcher, exactly as before.
    if { [ -n "${BEAMS_CHANNEL_TOKEN:-}" ] || [ -n "${BEAMS_CHANNEL_TOKEN_FILE:-}" ] || [ "${BEAMS_CHANNEL_AUTOWIRE:-}" = "1" ]; } \
       && command -v curl >/dev/null 2>&1; then
      export BEAMS_CHANNEL_TOKEN BEAMS_CHANNEL_TOKEN_FILE
      # Publish WHICH session is live for this identity, so the long-lived,
      # per-identity watcher's on-message hook rings THIS session's channel
      # server instead of the frozen id of whoever first armed it — the cause of
      # the doorbell going dead after the arming session ends. Newest session
      # wins (one watcher per identity can wake only one session anyway). Atomic
      # mktemp+mv so a concurrent on-message read never sees a half-written file;
      # identifier-safe the id first. No session id → nothing to publish (the
      # hook falls back to its own CLAUDE_CODE_SESSION_ID).
      __csid="${CLAUDE_CODE_SESSION_ID:-}"; __csid="${__csid//[^A-Za-z0-9_-]/}"
      if [ -n "$__csid" ]; then
        __ptmp=$(mktemp "$BEAMS_CONFIG_DIR/.channel.session.XXXXXX" 2>/dev/null) \
          && printf '%s\n' "$__csid" > "$__ptmp" \
          && mv -f "$__ptmp" "$BEAMS_CONFIG_DIR/channel.session" 2>/dev/null \
          || rm -f "${__ptmp:-}" 2>/dev/null
      fi
      # Opportunistic, backgrounded hygiene: drop rendezvous .port files whose
      # server is gone (curl exit 7 == connection refused == nothing listening).
      # Bounded localhost probes, once per session start, fully detached so it
      # adds no boot latency. A busy-but-alive server times out (not refused) and
      # is left alone; a live server's file only exists AFTER it has listened, so
      # this never race-deletes a still-starting server's file.
      ( __chan="${XDG_CONFIG_HOME:-$HOME/.config}/beams/channels"
        [ -d "$__chan" ] || exit 0
        for __pf in "$__chan"/*.port; do
          [ -f "$__pf" ] || continue
          IFS= read -r __pp < "$__pf" 2>/dev/null || true
          case "$__pp" in ''|*[!0-9]*) continue ;; esac
          curl -s -m 1 "http://127.0.0.1:${__pp}/health" >/dev/null 2>&1
          [ $? -eq 7 ] && rm -f "$__pf" 2>/dev/null
        done ) >/dev/null 2>&1 </dev/null &
      nohup bash "$root/lib/watch.sh" start \
        --on-message "bash $(printf '%q' "$root/channel/on-message.sh")" \
        >/dev/null 2>&1 </dev/null &
    else
      nohup bash "$root/lib/watch.sh" start >/dev/null 2>&1 </dev/null &
    fi
    disown 2>/dev/null || true
  fi

  # Emit one SessionStart payload carrying whatever applies:
  #   - sessionTitle: the Claude Code tab name — asserted whenever we're bound,
  #     so the tab always tracks the identity (the auto-/beams:name the user used
  #     to do by hand). Silent (no field) when unbound.
  #   - additionalContext: the auto-bind note and/or any unread inbox.
  #   - systemMessage: the user-visible inbox banner (only when unread arrived).
  # Nothing applicable → no output at all (idle, unbound).
  title=""
  beams::config_exists && title=$(beams::config_get '.session_name' 2>/dev/null)

  note=""
  if [ -n "$autobound" ]; then
    note="beams: this terminal had no bound identity, so it auto-bound to \"$autobound\" for this project (e.g. resuming after a Claude restart, or the same terminal you used before). You are now live on that identity's subscribed beams."
  fi
  extra=""; sysmsg=""
  if [ -n "$out" ]; then
    extra=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
    sysmsg=$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null)
  fi
  ctx=""
  if   [ -n "$note" ] && [ -n "$extra" ]; then ctx=$(printf '%s\n\n%s' "$note" "$extra")
  elif [ -n "$note" ];  then ctx="$note"
  elif [ -n "$extra" ]; then ctx="$extra"
  fi

  if [ -n "$ctx" ] || [ -n "$title" ]; then
    jq -n --arg ev SessionStart --arg ctx "$ctx" --arg t "$title" --arg sysmsg "$sysmsg" '
      ({hookSpecificOutput: (
          {hookEventName: $ev}
          + (if $ctx != "" then {additionalContext: $ctx} else {} end)
          + (if $t   != "" then {sessionTitle: $t}        else {} end)
        )}
       + (if $sysmsg != "" then {systemMessage: $sysmsg} else {} end))' 2>/dev/null || true
  fi

  # We just (re)asserted the title at SessionStart — drop any pending-retitle
  # marker so the next UserPromptSubmit doesn't redundantly set it again.
  rm -f "$BEAMS_BASE_DIR/sessions/$(beams::terminal_id)/title_pending" 2>/dev/null || true
} 2>/dev/null

exit 0
