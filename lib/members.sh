#!/usr/bin/env bash
# /buses:members <bus> — list members of a bus, marking the driver and any
# banned UUIDs. Also prints a header line if the bus is locked.

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
[ -n "$bus" ] || buses::die "usage: members.sh <bus>"
buses::bus_exists "$bus" || buses::die "bus '$bus' does not exist"

drv=$(buses::driver_uuid "$bus")
mf=$(buses::manifest_file "$bus")
banned=()
if [ -f "$mf" ]; then
  while IFS= read -r b; do
    [ -n "$b" ] && banned+=("$b")
  done < <(jq -r '.banned[]? // empty' "$mf" 2>/dev/null)
fi

if buses::is_locked "$bus"; then
  reason=$(buses::lock_reason "$bus")
  printf '[bus locked%s]\n' "${reason:+ — $reason}"
fi

mdir=$(buses::bus_members "$bus")
if [ ! -d "$mdir" ] || [ -z "$(ls -A "$mdir" 2>/dev/null)" ]; then
  printf 'buses: no active members in %s\n' "$bus"
else
  printf '%-38s %-20s %-20s %-22s %s\n' SESSION_ID NAME HOST LAST_SEEN ROLE
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    jq -r '"\(.id)\t\(.name // "-")\t\(.host // "-")\t\(.last_seen // "-")"' "$f" 2>/dev/null \
      | awk -F'\t' -v drv="$drv" '{
        role = (drv != "" && $1 == drv) ? "driver" : "rider"
        printf "%-38s %-20s %-20s %-22s %s\n", $1, $2, $3, $4, role
      }'
  done < <(find "$mdir" -maxdepth 1 -name '*.json' -type f | LC_ALL=C sort)
fi

# Banned UUIDs may no longer have a member record — surface them separately.
if [ "${#banned[@]}" -gt 0 ]; then
  printf '\nbanned:\n'
  for b in "${banned[@]}"; do printf '  %s\n' "$b"; done
fi
