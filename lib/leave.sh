#!/usr/bin/env bash
# /buses:leave <bus> — unsubscribe from a bus. Removes member record + cursor.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq
buses::config_require

# The matching .md command quotes "$ARGUMENTS" as a single arg for safety
# against shell metacharacters in user input. Re-split it into positionals
# here (whitespace-only; no shell interpretation). When tests call the
# script directly with already-split args, $# > 1 and we leave them alone.
[ "$#" -le 1 ] && { read -ra __buses_args <<<"${1-}"; set -- "${__buses_args[@]}"; unset __buses_args; }

bus="${1:-}"
[ -n "$bus" ] || buses::die "usage: leave.sh <bus>"

if ! buses::is_subscribed "$bus"; then
  printf 'buses: not subscribed to "%s" — nothing to do\n' "$bus"
  exit 0
fi

buses::config_set '.buses |= map(select(. != $b))' --arg b "$bus"

sid=$(buses::config_get '.session_id')
members_dir=$(buses::bus_members "$bus")
[ -f "$members_dir/$sid.json" ] && rm -f "$members_dir/$sid.json"

rm -f "$(buses::cursor_file "$bus")" "$(buses::notify_cursor_file "$bus")"

printf 'buses: left "%s"\n' "$bus"
