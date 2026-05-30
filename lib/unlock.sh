#!/usr/bin/env bash
# /buses:unlock <bus> — driver-only: clear the lock on a bus.

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
[ -n "$bus" ] || buses::die "usage: unlock.sh <bus>"
buses::bus_exists "$bus" || buses::die "bus '$bus' does not exist"
buses::is_driver "$bus"  || buses::die "only the driver of '$bus' can unlock it"

if ! buses::is_locked "$bus"; then
  printf 'buses: bus "%s" was not locked\n' "$bus"
  exit 0
fi

buses::manifest_set "$bus" 'del(.locked)'
printf 'buses: bus "%s" unlocked\n' "$bus"
