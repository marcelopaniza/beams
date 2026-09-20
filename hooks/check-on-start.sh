#!/usr/bin/env bash
# SessionStart hook: when a Claude Code session starts (or resumes / clears),
# surface any unread beam messages addressed to this session as context — the
# same zero-token-when-idle pull the UserPromptSubmit hook does, just at boot,
# so the session greets you already aware of the beam. Silent + ~0 tokens when
# there's nothing waiting; never blocks or fails session start.
#
# Always-on watcher + doorbell: unless this session opted out
# (react.watch_on_boot:false, or the BEAMS_DISABLE_WATCH_ON_BOOT=1 env escape
# hatch for headless/CI/tests), also (re)start the background notifier daemon
# armed with the wake-file hook (lib/on-message.sh) — so EVERY session gets
# desktop notifications AND the flag-free real-time doorbell without the user
# remembering `/beams:watch start`. The daemon is zero-token (pure polling);
# the only cost is one background process.
#
# Two doorbell transports, picked here: this hook publishes the session's inbox
# pointer (inbox.json), and when that works the daemon posts each wake batch
# straight into the session's own socket — the harness starts the turn, so we
# emit NO instruction at all. On a harness that binds no such socket we fall
# back to the wake file plus an additionalContext instruction asking the session
# to arm a Monitor on it (a hook can't start a model tool; it can only ask).
#
# A missing config (a terminal that never ran /beams:init) is normally a silent
# no-op so beams stays invisible to non-users — EXCEPT when this project has
# exactly ONE bindable durable identity (free, or already this terminal's). In
# that case the hook silently rebinds to it (e.g. resuming after a Claude
# restart) instead of ever prompting. Zero identities, two-or-more, or all-busy
# (held by another live session) → still a silent no-op; busy names are never
# stolen (use `/beams:name <n> --force` for a deliberate takeover).

set -uo pipefail

# Drain the SessionStart JSON (source: startup | resume | clear | compact |
# fork). The doorbell re-offer is gated on the open-reader probe, not on the
# source — the source is read only as the fallback for a host where no probe
# method exists at all (see the wake_note block below).
__hook_in=$(cat 2>/dev/null) || __hook_in=""

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
    # "mine" for an UNBOUND session means the lease names THIS Claude process
    # (claude_pid) under a different session id — i.e. a /clear rotated the id
    # in the terminal that holds the name. That is a certain match, even when
    # the project has several identities.
    bindable=(); mine=()
    while IFS= read -r nm; do
      [ -n "$nm" ] || continue
      case "$(beams::lease_state "$(beams::identities_dir)/$nm" 2>/dev/null)" in
        free) bindable+=("$nm") ;;
        mine) bindable+=("$nm"); mine+=("$nm") ;;
      esac
    done <<< "$idnames"

    cand=""
    if [ "${#mine[@]}" -eq 1 ]; then
      cand="${mine[0]}"                  # same Claude process (post-/clear) → certain
    elif [ "${#bindable[@]}" -eq 0 ]; then
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

  # Native doorbell transport: publish this session's inbox socket + token for
  # the watcher daemon to post into (beams::inbox_publish). Done BEFORE the
  # watcher (re)start so the daemon's very first poll already finds a current
  # pointer, and OUTSIDE the watch_on_boot gate ON PURPOSE: a session that opted
  # out still gets a current pointer, which costs nothing and means a watcher
  # started later — by hand here (`/beams:watch start` publishes too) or by
  # another session — can ring this one. Non-zero = no native transport for this
  # session: no inbox socket (older Claude Code, a cross-CLI shell), or a
  # receiver whose crossSessionInbound setting refuses/holds peer messages →
  # either way we stay on the Monitor fallback below.
  __native=0
  beams::inbox_publish 2>/dev/null && __native=1

  # Default-on: bring up the notifier daemon on boot so every session gets
  # desktop notifications for new beams. Opt out per-session with
  # react.watch_on_boot:false, or globally with BEAMS_DISABLE_WATCH_ON_BOOT=1
  # (headless/CI/tests). Detached, and fully silenced so its "watcher
  # (re)started" lines never leak into the session context. Pin
  # BEAMS_CONFIG_DIR so the daemon resolves the exact same identity this hook
  # did.
  # Read the raw value, NOT beams::config_get — config_get appends `// ""`, and
  # jq's `//` treats JSON false as empty, so an explicit watch_on_boot:false
  # would collapse to "" and the `!= "false"` test would WRONGLY arm. Plain jq
  # keeps false/true/null distinct: null/absent → arm (default-on), explicit
  # false → opt out.
  __wob=$(jq -r '.react.watch_on_boot' "$BEAMS_CONFIG_FILE" 2>/dev/null)
  if [ "${BEAMS_DISABLE_WATCH_ON_BOOT:-}" != "1" ] && [ "$__wob" != "false" ]; then
    export BEAMS_CONFIG_DIR

    # Real-time doorbell, flag-free: EVERY watcher is armed with the wake-file
    # hook (lib/on-message.sh), which appends one line per new message to
    # $BEAMS_CONFIG_DIR/wake.log. The persistent Monitor this session is asked
    # to arm (additionalContext below) turns each appended line into a harness
    # event that wakes the session even when it is fully idle. Start the file
    # fresh: anything already in it predates this session start and was just
    # surfaced by the boot pull above — replaying it would double-deliver.
    # Never truncate through a peer-planted symlink (drop the name instead);
    # a FIFO/device at the path is left alone for the hook's own [ -f ] gate.
    __wake="$BEAMS_CONFIG_DIR/wake.log"
    [ -L "$__wake" ] && rm -f "$__wake" 2>/dev/null
    if [ ! -e "$__wake" ] || [ -f "$__wake" ]; then
      : > "$__wake" 2>/dev/null || true
    fi

    # `restart`, not `start`: a daemon surviving from before an upgrade (one
    # armed with the retired channel hook, or with no hook at all) would
    # otherwise keep running with a stale environment forever — start is a
    # no-op while one is alive. The bounce is safe: the notify cursor lives on
    # disk, so no message is lost or re-notified across it.
    nohup bash "$root/lib/watch.sh" restart \
      --on-message "bash $(printf '%q' "$root/lib/on-message.sh")" \
      >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
    __doorbell=1
  fi

  # Ask the session to arm the doorbell Monitor — the FALLBACK transport, so
  # only when this session has no inbox socket of its own (__native above). With
  # one, the watcher posts the wake straight into the session and the harness
  # starts the turn itself: nothing to arm, and nothing to re-arm every 30
  # minutes. Suppressed also when something already
  # tails wake.log (beams::doorbell_reader: fuser, lsof, or a /proc fd scan). An
  # open reader IS a live doorbell, whether armed earlier in this process (a
  # /clear or compact keeps the process and its monitors) or not; instructing
  # again would arm a second monitor that rings every message twice. The probe
  # replaces the old `source`-based rule (skip on clear/compact): the harness now
  # ends every monitor after at most 30 minutes, so by the time a compaction
  # fires the doorbell is usually gone — and the instruction that told the model
  # to re-arm it is exactly what the compaction just dropped from context.
  wake_note=""
  if [ "${__native:-0}" != "1" ] && [ "${__doorbell:-}" = "1" ] \
     && [ -z "$(beams::doorbell_reader 2>/dev/null)" ]; then
    # "No reader" only means "nothing armed" where a probe method exists. With
    # none (no fuser, no lsof, no readable /proc) an armed monitor is invisible,
    # and the empty probe would re-offer on every clear/compact and duplicate the
    # doorbell — so fall back to the pre-probe rule there and stay silent on
    # exactly those two sources, which keep the process and its monitors alive.
    __src=""
    if ! beams::doorbell_probe_available; then
      __src=$(printf '%s' "$__hook_in" | jq -r '.source // empty' 2>/dev/null) || __src=""
    fi
    case "$__src" in
      clear|compact) ;;
      # Exact text lives in common.sh (beams::doorbell_instruction) — shared
      # with the mid-session arm (beams::doorbell_autostart), so the two
      # emitters can't drift.
      *) wake_note=$(beams::doorbell_instruction) ;;
    esac
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
  for __piece in "$note" "$extra" "$wake_note"; do
    [ -n "$__piece" ] || continue
    if [ -n "$ctx" ]; then ctx=$(printf '%s\n\n%s' "$ctx" "$__piece"); else ctx="$__piece"; fi
  done

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
