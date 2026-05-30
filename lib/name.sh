#!/usr/bin/env bash
# /buses:name <friendly-name> — set this session's friendly name and refresh
# member records on all subscribed buses.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq
buses::config_require

# The matching .md command quotes "$ARGUMENTS" as a single arg for safety
# against shell metacharacters in user input. Re-split it into positionals
# here (whitespace-only; no shell interpretation). When tests call the
# script directly with already-split args, $# > 1 and we leave them alone.
[ "$#" -le 1 ] && { read -ra __buses_args <<<"${1-}"; set -- "${__buses_args[@]}"; unset __buses_args; }

new="${1:-}"
[ -n "$new" ] || buses::die "usage: name.sh <friendly-name>"
buses::valid_name "$new" || buses::die "invalid name: $new (allowed: A-Z a-z 0-9 . _ -, length 1-64)"

buses::config_set '.session_name = $v' --arg v "$new"

# Update presence in every joined bus.
while IFS= read -r bus; do
  [ -n "$bus" ] || continue
  buses::bus_exists "$bus" && buses::write_member_record "$bus"
done < <(jq -r '.buses[]?' "$BUSES_CONFIG_FILE")

printf 'buses: session name set to "%s"\n' "$new"
