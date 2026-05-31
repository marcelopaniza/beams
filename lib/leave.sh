#!/usr/bin/env bash
# /beams:admin leave <beam> — unsubscribe from a beam. Removes member record + cursor.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq
beams::config_require

# The matching .md command quotes "$ARGUMENTS" as a single arg for safety
# against shell metacharacters in user input. Re-split it into positionals
# here (whitespace-only; no shell interpretation). When tests call the
# script directly with already-split args, $# > 1 and we leave them alone.
[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

beam="${1:-}"
[ -n "$beam" ] || beams::die "usage: leave.sh <beam>"

if ! beams::is_subscribed "$beam"; then
  printf 'beams: not subscribed to "%s" — nothing to do\n' "$beam"
  exit 0
fi

beams::config_set '.beams |= map(select(. != $b))' --arg b "$beam"

sid=$(beams::config_get '.session_id')
members_dir=$(beams::beam_members "$beam")
[ -f "$members_dir/$sid.json" ] && rm -f "$members_dir/$sid.json"

rm -f "$(beams::cursor_file "$beam")" "$(beams::notify_cursor_file "$beam")"

printf 'beams: left "%s"\n' "$beam"
