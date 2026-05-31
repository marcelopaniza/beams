#!/usr/bin/env bash
# /beams:admin members <beam> — list members of a beam, marking the driver and any
# banned UUIDs. Also prints a header line if the beam is locked.

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
[ -n "$beam" ] || beams::die "usage: members.sh <beam>"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"

drv=$(beams::driver_uuid "$beam")
mf=$(beams::manifest_file "$beam")
banned=()
if [ -f "$mf" ]; then
  while IFS= read -r b; do
    [ -n "$b" ] && banned+=("$b")
  done < <(jq -r '.banned[]? // empty' "$mf" 2>/dev/null)
fi

if beams::is_locked "$beam"; then
  reason=$(beams::lock_reason "$beam")
  printf '[beam locked%s]\n' "${reason:+ — $reason}"
fi

mdir=$(beams::beam_members "$beam")
if [ ! -d "$mdir" ] || [ -z "$(ls -A "$mdir" 2>/dev/null)" ]; then
  printf 'beams: no active members in %s\n' "$beam"
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
