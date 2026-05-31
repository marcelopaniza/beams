#!/usr/bin/env bash
# /beams:admin cleanup-stale <beam> [--older-than <duration>] [--force] [--dry-run]
#
# Driver-only. Removes member records whose last_seen is older than the
# threshold. Defaults to 30 days. Refuses to remove the current driver's
# record unless --force is given.
#
# Duration syntax: <integer><unit> where unit is m (minutes), h (hours),
# d (days). Examples: 30d, 7d, 12h, 90m. Default: 30d.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq find
beams::config_require

# The matching .md command quotes "$ARGUMENTS" as a single arg for safety
# against shell metacharacters in user input. Re-split it into positionals
# here (whitespace-only; no shell interpretation). When tests call the
# script directly with already-split args, $# > 1 and we leave them alone.
[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

beam=""
older_than="30d"
force=""
dry=""

while [ $# -gt 0 ]; do
  case "$1" in
    --older-than) older_than="${2:-}"; shift 2 ;;
    --force)      force=1; shift ;;
    --dry-run)    dry=1; shift ;;
    -*)           beams::die "unknown flag: $1" ;;
    *)            [ -z "$beam" ] && beam="$1" || beams::die "unexpected arg: $1" ; shift ;;
  esac
done

[ -n "$beam" ] || beams::die "usage: cleanup-stale.sh <beam> [--older-than 30d] [--force] [--dry-run]"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"
beams::is_driver "$beam"  || beams::die "only the driver of '$beam' can run cleanup"

# Duration → find flag (shared helper).
mapfile -t find_flag < <(beams::parse_duration "$older_than") \
  || beams::die "bad --older-than: $older_than (use Nd / Nh / Nm)"
[ "${#find_flag[@]}" -eq 2 ] || beams::die "bad --older-than: $older_than"

drv=$(beams::driver_uuid "$beam")
mdir=$(beams::beam_members "$beam")
[ -d "$mdir" ] || { printf 'beams: beam "%s" has no members directory\n' "$beam"; exit 0; }

removed=0
skipped_driver=0
declare -a removed_list=()

while IFS= read -r f; do
  [ -f "$f" ] || continue
  uuid=$(basename "$f" .json)
  if [ "$uuid" = "$drv" ] && [ -z "$force" ]; then
    skipped_driver=1
    continue
  fi
  if [ -n "$dry" ]; then
    removed_list+=("WOULD-REMOVE $f")
  else
    rm -f "$f"
    removed_list+=("removed $f")
  fi
  removed=$((removed + 1))
done < <(find "$mdir" -maxdepth 1 -name '*.json' -type f "${find_flag[@]}" 2>/dev/null)

if [ "$removed" -eq 0 ]; then
  printf 'beams: nothing to clean up in "%s" (no member records older than %s)\n' "$beam" "$older_than"
else
  printf 'beams: cleanup of "%s" (--older-than %s%s)\n' "$beam" "$older_than" "${dry:+ — DRY RUN}"
  for line in "${removed_list[@]}"; do printf '  %s\n' "$line"; done
  printf 'beams: %s record(s)%s\n' "$removed" "${dry:+ would be removed}"
fi

if [ "$skipped_driver" -eq 1 ]; then
  printf 'beams: skipped the current driver record (use --force to include it)\n'
fi
