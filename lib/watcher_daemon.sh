#!/usr/bin/env bash
# Background poller for the buses plugin. Started by `lib/watch.sh start`.
# Polls every $1 seconds (default 5), fires desktop notifications for new
# messages addressed to this session. Uses the NOTIFY cursor only — does NOT
# touch the hook cursor, so the model still sees these messages when the user
# next types into Claude.
#
# Env:
#   BUSES_CONFIG_DIR           — inherited from the launching shell.
#   BUSES_NOTIFIER_CMD         — optional override: invoked as "$cmd <title> <body>".
#                                Useful for testing or piping notifications elsewhere.
#   BUSES_ON_MESSAGE_CMD       — optional shell snippet dispatched after each new
#                                message. Receives env: BUSES_BUS, BUSES_FROM,
#                                BUSES_PREVIEW. Forked async, capped at
#                                $BUSES_ON_MESSAGE_TIMEOUT seconds (default 30).
#                                Failures logged to state/on-message.log; never
#                                crash the daemon nor roll back the notify cursor.
#   BUSES_ON_MESSAGE_TIMEOUT   — seconds; default 30. Used only if `timeout` is
#                                on PATH (most modern Linux/BSD/macOS-coreutils).
#   BUSES_ON_MESSAGE_MAX_INFLIGHT
#                              — positive integer cap on concurrent dispatched
#                                children (default 8). Excess fires on a burst
#                                are logged as SKIPPED and dropped, so a sender
#                                flood cannot exhaust fds/PIDs/network.
#
# This script is never invoked directly by the user.

set -u
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=common.sh
source "$PLUGIN_ROOT/lib/common.sh"

interval="${1:-5}"
case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
[ "$interval" -ge 1 ] || interval=5

[ -f "$BUSES_CONFIG_FILE" ] || { echo "watcher: no config — exiting" >&2; exit 1; }
sid=$(buses::config_get '.session_id')
[ -n "$sid" ]               || { echo "watcher: empty session_id — exiting" >&2; exit 1; }

state_dir=$(buses::state_dir)
mkdir -p "$state_dir"

# Path to our own log file, used for in-process rotation in the loop below.
# Defined here so the loop can reference it without recomputing each pass.
pid_file="$state_dir/watcher.pid"
echo $$ > "$pid_file"

cleanup() {
  rm -f "$pid_file"
  echo "[$(buses::now_iso)] watcher stop pid=$$"
  exit 0
}
trap cleanup TERM INT HUP

# Detect notifier once, print to log so /buses:watch status can show it.
detect_notifier() {
  if [ -n "${BUSES_NOTIFIER_CMD:-}" ];      then echo "override:${BUSES_NOTIFIER_CMD}"
  elif command -v notify-send       >/dev/null 2>&1; then echo notify-send
  elif command -v terminal-notifier >/dev/null 2>&1; then echo terminal-notifier
  elif command -v osascript         >/dev/null 2>&1; then echo osascript
  elif command -v kdialog           >/dev/null 2>&1; then echo kdialog
  else echo "(none — falling back to log only)"
  fi
}
notifier=$(detect_notifier)

# --- on-message dispatch -----------------------------------------------------
# When BUSES_ON_MESSAGE_CMD is set, every new message addressed to us spawns
# `bash -c "$BUSES_ON_MESSAGE_CMD"` in the background with BUSES_BUS,
# BUSES_FROM, BUSES_PREVIEW exported. Body content reaches the cmd ONLY via env
# vars — the cmd snippet text is never templated with body bytes, so a
# malicious body (`'; rm -rf ~ #`) cannot escape into shell.
#
# Each fire is fork-and-forget: detached background subshell, output captured
# to state/on-message.log, capped at BUSES_ON_MESSAGE_TIMEOUT seconds when
# `timeout` is available. Failures (non-zero exit, timeout, missing utility)
# are logged but never crash the daemon nor affect cursor advance — the notify
# cursor has already moved by the time we get here.
#
# Defence-in-depth: although lib/check.sh's --notify mode now strips C0 + DEL
# from `from_name` and `preview` before emitting, we strip again here. This
# protects against the case where the watcher is fed by a hand-crafted file
# (peer with raw shared-folder write) that bypassed the check.sh sanitizer,
# AND against future check.sh refactors that drop the strip.
#
# Inflight cap: each new message backgrounds a `bash -c` subshell. A burst of
# N messages in one poll cycle would otherwise spawn N concurrent children
# (fd/PID exhaustion, runaway outbound traffic if the cmd hits a webhook).
# We gate on `jobs -rp | wc -l` against BUSES_ON_MESSAGE_MAX_INFLIGHT (default
# 8). Excess fires are SKIPPED (logged, not queued) — the daemon stays
# responsive; the user can tune the cap or write a queueing cmd if they need
# every message.
on_message_log="$state_dir/on-message.log"

om_timeout="${BUSES_ON_MESSAGE_TIMEOUT:-30}"
case "$om_timeout" in ''|*[!0-9]*) om_timeout=30 ;; esac
[ "$om_timeout" -ge 1 ] || om_timeout=30

om_inflight_max="${BUSES_ON_MESSAGE_MAX_INFLIGHT:-8}"
case "$om_inflight_max" in ''|*[!0-9]*) om_inflight_max=8 ;; esac
[ "$om_inflight_max" -ge 1 ] || om_inflight_max=8

have_timeout=0
command -v timeout >/dev/null 2>&1 && have_timeout=1

# Refuse to write through a symlink at on_message_log. Same hardening as v0.7.3
# applied to the hook stash: a same-UID peer pre-planting the path as a
# symlink to a victim-owned file (`~/.ssh/authorized_keys`, etc.) would
# otherwise have us append attacker-influenced bytes there. We re-check each
# loop iteration (cheap) so a post-startup plant is also caught.
on_message_safe=1
on_message_check_symlink() {
  if [ -L "$on_message_log" ]; then
    if [ "$on_message_safe" = 1 ]; then
      echo "[$(buses::now_iso)] WARN: on-message.log is a symlink — refusing to follow; on-message dispatch DISABLED this run"
    fi
    on_message_safe=0
    return 1
  fi
  return 0
}
on_message_check_symlink || true

dispatch_on_message() {
  local bus="$1" from="$2" preview="$3"

  # Per-loop symlink re-check (handles attacker planting after startup).
  on_message_check_symlink || return 0

  # Inflight cap. `jobs -rp` lists PIDs of running background jobs in this
  # shell; at this point in the loop the only background jobs are previously
  # dispatched on-message children (the per-iteration `sleep` is started
  # AFTER this loop completes). Each finished child is auto-reaped by bash
  # via SIGCHLD, so the count is accurate.
  local inflight
  inflight=$(jobs -rp 2>/dev/null | wc -l)
  inflight="${inflight//[[:space:]]/}"
  if [ "${inflight:-0}" -ge "$om_inflight_max" ]; then
    printf '[%s] on-message SKIPPED (inflight=%s >= cap=%s) bus=%s from=%s\n' \
      "$(buses::now_iso)" "$inflight" "$om_inflight_max" "$bus" "$from" \
      >>"$on_message_log"
    return 0
  fi

  # Defence-in-depth: strip C0 + DEL from every value reaching the env. Tabs,
  # newlines, ESC etc. would otherwise leak into terminals that print the
  # values raw, and into on-message.log forensic readouts. NULs would also be
  # silently dropped by execve, but strip explicitly so the cmd sees consistent
  # bytes whether or not the kernel intervenes.
  bus=$(printf '%s'     "$bus"     | LC_ALL=C tr -d '\000-\037\177')
  from=$(printf '%s'    "$from"    | LC_ALL=C tr -d '\000-\037\177')
  preview=$(printf '%s' "$preview" | LC_ALL=C tr -d '\000-\037\177')

  (
    export BUSES_BUS="$bus" BUSES_FROM="$from" BUSES_PREVIEW="$preview"
    if [ "$have_timeout" = 1 ]; then
      timeout "$om_timeout" bash -c "$BUSES_ON_MESSAGE_CMD" </dev/null \
        >>"$on_message_log" 2>&1
    else
      bash -c "$BUSES_ON_MESSAGE_CMD" </dev/null \
        >>"$on_message_log" 2>&1
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '[%s] on-message exit=%s bus=%s from=%s\n' \
        "$(buses::now_iso)" "$rc" "$bus" "$from" >>"$on_message_log"
    fi
  ) &
}

notify() {
  local bus="$1" from="$2" preview="$3"
  # Strip every control character from preview before handing it to any
  # notifier, particularly to osascript -e which interprets a newline as a
  # statement terminator (would let a crafted message body break out of the
  # quoted notification string and execute AppleScript). Also strip CRs and
  # other low ASCII for safety across all notifiers.
  preview=$(printf '%s' "$preview" | tr -d '\000-\037')
  local title="buses: ${from} on ${bus}"
  if [ -n "${BUSES_NOTIFIER_CMD:-}" ]; then
    # Intentionally invoked as a single command (no word-splitting): set
    # BUSES_NOTIFIER_CMD to the absolute path of one executable, not a
    # shell snippet. Documented in README.
    "$BUSES_NOTIFIER_CMD" "$title" "$preview" 2>/dev/null || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send -a buses -u low "$title" "$preview" 2>/dev/null || true
  elif command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title buses -subtitle "${from} on ${bus}" -message "$preview" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    local body_esc sub_esc
    body_esc=$(printf '%s' "$preview"               | sed 's/\\/\\\\/g; s/"/\\"/g')
    sub_esc=$(printf '%s' "${from} on ${bus}"       | sed 's/\\/\\\\/g; s/"/\\"/g')
    osascript -e "display notification \"$body_esc\" with title \"buses\" subtitle \"$sub_esc\"" 2>/dev/null || true
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --title "$title" --passivepopup "$preview" 8 2>/dev/null || true
  else
    : # logged below
  fi
  echo "[$(buses::now_iso)] notify bus=$bus from=$from"
}

on_message_marker="off"
[ -n "${BUSES_ON_MESSAGE_CMD:-}" ] && \
  on_message_marker="ACTIVE (timeout=${om_timeout}s, inflight_cap=${om_inflight_max})"
echo "[$(buses::now_iso)] watcher start sid=$sid interval=${interval}s notifier=$notifier on-message=$on_message_marker pid=$$"

while true; do
  # If config disappears, exit gracefully (user uninstalled, reset, etc).
  if [ ! -f "$BUSES_CONFIG_FILE" ]; then
    echo "[$(buses::now_iso)] watcher: config gone — exiting"
    cleanup
  fi

  # If share is temporarily unmounted, back off without crashing.
  if [ -d "$(buses::shared_root)" ]; then
    out=$("$PLUGIN_ROOT/lib/check.sh" --notify 2>/dev/null || true)
    if [ -n "$out" ]; then
      while IFS=$'\t' read -r bus from preview; do
        [ -n "$bus" ] || continue
        notify "$bus" "$from" "$preview"
        [ -n "${BUSES_ON_MESSAGE_CMD:-}" ] && \
          dispatch_on_message "$bus" "$from" "$preview"
      done <<< "$out"
    fi
  fi

  # Cap watcher.log + on-message.log at ~1MB by truncating-and-restarting
  # whenever they grow past the threshold. Cheap (one stat per poll); never
  # bounds total run time. Done from inside the loop so they track the logs
  # we're already writing to, no matter where they live.
  log_self="${state_dir}/watcher.log"
  if [ -f "$log_self" ] && [ "$(wc -c < "$log_self" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    : > "$log_self"
    echo "[$(buses::now_iso)] watcher.log rotated (exceeded 1MB)"
  fi
  # Skip rotation if on_message_log was replaced with a symlink — rotation's
  # `: > "$file"` follows symlinks and would truncate the attacker's chosen
  # victim file. on_message_check_symlink (per-dispatch) has already disabled
  # dispatch in this case; here we just refuse the truncate too.
  if [ -f "$on_message_log" ] && [ ! -L "$on_message_log" ] && \
     [ "$(wc -c < "$on_message_log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    : > "$on_message_log"
    echo "[$(buses::now_iso)] on-message.log rotated (exceeded 1MB)"
  fi

  # Background sleep so SIGTERM can interrupt the wait — bare `sleep` would
  # block trap delivery until the interval expired.
  sleep "$interval" &
  wait $!
done
