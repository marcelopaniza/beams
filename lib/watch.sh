#!/usr/bin/env bash
# /buses:watch — dispatcher for the background notification daemon.
# Subcommands:
#   start [interval]   start the watcher (default: 5s, or last saved interval)
#   stop               stop a running watcher
#   restart [interval] stop then start
#   status             show running state, PID, uptime, notifier, last log lines
#   logs [n]           tail the watcher log (default 30 lines)

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq
buses::config_require

# The matching .md command quotes "$ARGUMENTS" as a single arg for safety
# against shell metacharacters in user input. Re-split it into positionals
# here (whitespace-only; no shell interpretation). When tests call the
# script directly with already-split args, $# > 1 and we leave them alone.
#
# Special case for --on-message <cmd>: the cmd is an arbitrary shell snippet
# that almost always contains spaces, quotes, etc. The naive whitespace-split
# would shred it. We cut the raw string at the FIRST occurrence of
# ` --on-message ` (or treat the whole string as cmd-after-flag if it starts
# with `--on-message `), preserving the trailing portion as one positional.
# Limitations: only one --on-message per invocation; the literal substring
# ` --on-message ` cannot appear inside the cmd (workaround: write a wrapper
# script and pass its path).
[ "$#" -le 1 ] && {
  __buses_raw="${1-}"
  __buses_marker=" --on-message "
  if [[ "$__buses_raw" == *"$__buses_marker"* ]]; then
    __buses_pre="${__buses_raw%%${__buses_marker}*}"
    __buses_cmd="${__buses_raw#*${__buses_marker}}"
    read -ra __buses_args <<<"$__buses_pre"
    set -- "${__buses_args[@]}" --on-message "$__buses_cmd"
  elif [[ "$__buses_raw" == --on-message\ * ]]; then
    __buses_cmd="${__buses_raw#--on-message }"
    set -- --on-message "$__buses_cmd"
  else
    read -ra __buses_args <<<"$__buses_raw"
    set -- "${__buses_args[@]}"
  fi
  unset __buses_args __buses_raw __buses_marker __buses_pre __buses_cmd
}

# Extract --on-message into a script-global before subcommand dispatch.
# Other positionals fall through unchanged. on_message_seen distinguishes
# "user passed --on-message with an empty value" (error) from "user didn't
# pass --on-message at all" (fine).
on_message_cmd=""
on_message_seen=0
__buses_positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --on-message)
      shift
      [ "$#" -ge 1 ] || { echo "buses: --on-message requires a command argument" >&2; exit 1; }
      on_message_cmd="$1"
      on_message_seen=1
      shift
      ;;
    *)
      __buses_positional+=("$1")
      shift
      ;;
  esac
done
set -- "${__buses_positional[@]}"
unset __buses_positional

# Empty cmd is treated as a usage error: silent-discard ("flag accepted but
# ignored") would mask typos like `--on-message ""` or `--on-message $UNSET`.
if [ "$on_message_seen" = 1 ] && [ -z "$on_message_cmd" ]; then
  echo "buses: --on-message argument cannot be empty" >&2
  exit 1
fi

sub="${1:-start}"; shift || true

# --on-message only meaningful at start / restart.
if [ "$on_message_seen" = 1 ] && [ "$sub" != "start" ] && [ "$sub" != "restart" ]; then
  buses::die "--on-message is only valid with start or restart, not '$sub'"
fi

state_dir=$(buses::state_dir)
mkdir -p "$state_dir"
pid_file="$state_dir/watcher.pid"
log_file="$state_dir/watcher.log"
interval_file="$state_dir/watcher.interval"

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

is_alive() {
  [ -f "$pid_file" ] || return 1
  local p; p=$(cat "$pid_file" 2>/dev/null || echo "")
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

cmd_start() {
  local interval="${1:-}"
  if [ -z "$interval" ] && [ -f "$interval_file" ]; then
    interval=$(cat "$interval_file" 2>/dev/null || echo 5)
  fi
  [ -n "$interval" ] || interval=5
  case "$interval" in ''|*[!0-9]*) buses::die "interval must be a positive integer (seconds)" ;; esac
  [ "$interval" -ge 1 ] || buses::die "interval must be >= 1 second"

  # Mkdir-based lock around the start sequence. mkdir is atomic on every
  # POSIX filesystem we care about, so this serialises concurrent
  # /buses:watch start calls in the same $BUSES_CONFIG_DIR. Without it,
  # two terminals starting the watcher within the 0.4s sanity sleep can
  # both launch a daemon and stomp on the PID file (one daemon stays
  # orphaned and unreachable by /buses:watch stop).
  local lock_dir="$state_dir/watcher.lock"
  local i=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && buses::die "couldn't acquire watcher start lock at $lock_dir (stuck? rmdir it manually)"
    sleep 0.1
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock_dir' 2>/dev/null || true" EXIT

  if is_alive; then
    local running_interval='?'
    [ -f "$interval_file" ] && running_interval=$(cat "$interval_file" 2>/dev/null)
    printf 'buses: watcher already running (pid=%s, interval=%ss)\n' \
      "$(cat "$pid_file")" "$running_interval"
    return 0
  fi

  echo "$interval" > "$interval_file"

  # Launch detached. nohup keeps it alive after the shell exits; stdin from
  # /dev/null so it never blocks on terminal input. --on-message snippet is
  # passed via env, not argv: it stays out of `ps` listings and out of the
  # nohup-redirected log file. (Same-UID peers can still read /proc/$pid/environ
  # — that's consistent with the existing threat model where $BUSES_CONFIG_DIR
  # is already same-UID readable.)
  export BUSES_CONFIG_DIR
  if [ -n "$on_message_cmd" ]; then
    export BUSES_ON_MESSAGE_CMD="$on_message_cmd"
  else
    unset BUSES_ON_MESSAGE_CMD
  fi
  nohup bash "$PLUGIN_ROOT/lib/watcher_daemon.sh" "$interval" \
    >> "$log_file" 2>&1 < /dev/null &
  local pid=$!
  disown 2>/dev/null || true

  sleep 0.4
  if ! kill -0 "$pid" 2>/dev/null; then
    buses::err "watcher exited immediately. Last log lines:"
    tail -n 20 "$log_file" >&2 || true
    rm -f "$pid_file"
    exit 1
  fi

  if [ -n "$on_message_cmd" ]; then
    printf 'buses: watcher started (pid=%s, interval=%ss, on-message=ACTIVE, log=%s)\n' \
      "$pid" "$interval" "$log_file"
  else
    printf 'buses: watcher started (pid=%s, interval=%ss, log=%s)\n' "$pid" "$interval" "$log_file"
  fi
}

cmd_stop() {
  if ! is_alive; then
    rm -f "$pid_file"
    printf 'buses: watcher was not running\n'
    return 0
  fi
  local p; p=$(cat "$pid_file")
  kill -TERM "$p" 2>/dev/null || true
  # Give it a moment to clean up.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$p" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$p" 2>/dev/null; then
    kill -KILL "$p" 2>/dev/null || true
    sleep 0.2
  fi
  rm -f "$pid_file"
  printf 'buses: watcher stopped (was pid=%s)\n' "$p"
}

cmd_restart() {
  cmd_stop
  cmd_start "$@"
}

cmd_status() {
  if is_alive; then
    local p; p=$(cat "$pid_file")
    local interval='?'
    [ -f "$interval_file" ] && interval=$(cat "$interval_file")
    printf 'buses: watcher RUNNING\n'
    printf '  pid:      %s\n' "$p"
    printf '  interval: %ss\n' "$interval"
    printf '  pid_file: %s\n' "$pid_file"
    printf '  log_file: %s\n' "$log_file"

    # On-message status is inferred from the most recent "watcher start" line
    # in watcher.log — the daemon writes "on-message=ACTIVE (timeout=Ns,
    # inflight_cap=N)" or "on-message=off" depending on whether
    # BUSES_ON_MESSAGE_CMD was exported at boot. This sidesteps the Linux-only
    # /proc/$pid/environ readback.
    local on_msg="unknown"
    if [ -f "$log_file" ]; then
      local start_line
      start_line=$(grep 'watcher start ' "$log_file" 2>/dev/null | tail -1 || true)
      if [ -z "$start_line" ]; then
        on_msg="unknown (watcher.log empty or rotated)"
      else
        case "$start_line" in
          *on-message=ACTIVE*)
            on_msg="${start_line##*on-message=}"
            on_msg="${on_msg% pid=*}"
            ;;
          *on-message=off*)    on_msg="off" ;;
          *)                   on_msg="unknown (pre-v0.8 log line)" ;;
        esac
      fi
    fi
    printf '  on-message: %s\n' "$on_msg"

    local om_log="$state_dir/on-message.log"
    if [ -f "$om_log" ]; then
      printf '\n  recent on-message log:\n'
      tail -n 5 "$om_log" | sed 's/^/    /'
    fi

    if [ -f "$log_file" ]; then
      printf '\n  recent log:\n'
      tail -n 5 "$log_file" | sed 's/^/    /'
    fi
  else
    printf 'buses: watcher NOT RUNNING\n'
    [ -f "$log_file" ] && {
      printf '  last log (tail 5):\n'
      tail -n 5 "$log_file" | sed 's/^/    /'
    }
  fi
}

cmd_logs() {
  local n="${1:-30}"
  case "$n" in ''|*[!0-9]*) n=30 ;; esac
  if [ -f "$log_file" ]; then
    tail -n "$n" "$log_file"
  else
    printf 'buses: no watcher log at %s\n' "$log_file"
  fi
}

case "$sub" in
  start)   cmd_start   "$@" ;;
  stop)    cmd_stop ;;
  restart) cmd_restart "$@" ;;
  status)  cmd_status ;;
  logs)    cmd_logs    "$@" ;;
  *) buses::die "unknown subcommand: $sub (use: start|stop|restart|status|logs)" ;;
esac
