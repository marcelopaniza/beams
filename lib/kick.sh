#!/usr/bin/env bash
# /buses:kick <bus> <name-or-uuid> [reason...] — driver-only.
# Adds the target's UUID to manifest.banned and removes their member record.
# Cooperative enforcement: other sessions' send/join refuses for banned UUIDs.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq
buses::config_require

# --from-stdin mode: identical pattern to lib/lock.sh and lib/send.sh —
# parse a heredoc payload piped from the /buses:kick slash command, where
# the quoted-delimiter heredoc has already suppressed $(...) / backtick
# expansion in the user-supplied reason text. See lib/send.sh for the
# full rationale.
if [ "${1:-}" = "--from-stdin" ]; then
  shift
  payload=$(cat; printf x)
  payload=${payload%x}
  payload=${payload%$'\n'}
  if [[ "$payload" == *$'\n'* ]]; then
    first_line=${payload%%$'\n'*}
    rest_lines=${payload#*$'\n'}
  else
    first_line="$payload"
    rest_lines=""
  fi
  read -r bus who reason_head <<< "$first_line"
  reason="${reason_head:-}"
  [ -n "$rest_lines" ] && reason="${reason}"$'\n'"$rest_lines"
  set -- "${bus:-}" "${who:-}" "${reason:-}"
fi

# Single-arg fallback for Pattern A / legacy callers. See lib/lock.sh.
[ "$#" -le 1 ] && { read -ra __buses_args <<<"${1-}"; set -- "${__buses_args[@]}"; unset __buses_args; }

bus="${1:-}"; shift || true
who="${1:-}"; shift || true
reason="$*"

[ -n "$bus" ] && [ -n "$who" ] || buses::die "usage: kick.sh <bus> <name-or-uuid> [reason...]"
buses::bus_exists "$bus" || buses::die "bus '$bus' does not exist"
buses::is_driver "$bus"  || buses::die "only the driver of '$bus' can kick"

target=$(buses::resolve_member "$bus" "$who")
[ -n "$target" ] || buses::die "no member named '$who' (or matching UUID) in bus '$bus'"

drv=$(buses::driver_uuid "$bus")
[ "$target" != "$drv" ] || buses::die "refusing to kick the driver — /buses:transfer-driver first"

if buses::is_banned "$bus" "$target"; then
  printf 'buses: %s is already banned from "%s"\n' "$target" "$bus"
  exit 0
fi

buses::manifest_set "$bus" \
  '.banned = ((.banned // []) + [$t] | unique)' \
  --arg t "$target"

members_dir=$(buses::bus_members "$bus")
rm -f "$members_dir/$target.json"

# Drop a signed notice file so the kicked session sees it on their next
# prompt. Delegated to the shared write helper.
name=$(buses::config_get '.session_name'); [ -n "$name" ] || name="(driver)"
body_text=$(printf 'You have been kicked from bus "%s" by driver %s.%s' \
  "$bus" "$name" "${reason:+ Reason: $reason}")
buses::write_message "$bus" "$target" "$body_text" "$target" "kick-notice" >/dev/null \
  || buses::die "signing kick notice failed"

printf 'buses: kicked %s from "%s"%s\n' "$target" "$bus" "${reason:+ (reason: $reason)}"
