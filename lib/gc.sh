#!/usr/bin/env bash
# /beams:gc <beam|all> [--older-than 90d] [--dry-run] [--force]
#
# Driver-only (per-beam). Removes message files older than the threshold from
# a beam's messages/ directory. Default threshold: 90 days. Pass `all` as the
# beam name to GC every beam on the share (must be driver of each — beams where
# you aren't driver are skipped with a notice unless --force).
#
# Duration syntax: <integer><unit> where unit is m (minutes), h (hours),
# d (days). Examples: 90d, 7d, 12h, 30m.

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
older_than="90d"
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

[ -n "$beam" ] || beams::die "usage: gc.sh <beam|all> [--older-than 90d] [--dry-run] [--force]"

# Duration → find flag (shared helper).
mapfile -t find_flag < <(beams::parse_duration "$older_than") \
  || beams::die "bad --older-than: $older_than (use Nd / Nh / Nm)"
[ "${#find_flag[@]}" -eq 2 ] || beams::die "bad --older-than: $older_than"

# Build list of beams to act on.
beams_root="$(beams::shared_root)/beams"
to_process=()
if [ "$beam" = "all" ]; then
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    to_process+=("$(basename "$d")")
  done < <(find "$beams_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | LC_ALL=C sort)
else
  beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"
  to_process=("$beam")
fi

[ "${#to_process[@]}" -gt 0 ] || { printf 'beams: nothing to gc\n'; exit 0; }

total_removed=0
for b in "${to_process[@]}"; do
  if ! beams::is_driver "$b" && [ -z "$force" ]; then
    printf 'beams: skipping "%s" (you are not the driver — pass --force to gc anyway)\n' "$b"
    continue
  fi
  mdir=$(beams::beam_messages "$b")
  [ -d "$mdir" ] || continue
  count=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ -n "$dry" ]; then
      printf '  WOULD-REMOVE %s\n' "$f"
    else
      rm -f "$f"
      printf '  removed       %s\n' "$f"
    fi
    count=$((count + 1))
  done < <(find "$mdir" -maxdepth 1 -name '*.msg' -type f "${find_flag[@]}" 2>/dev/null | LC_ALL=C sort)
  if [ "$count" -gt 0 ]; then
    printf 'beams: beam "%s" — %s message(s)%s\n' "$b" "$count" "${dry:+ would be removed}"
  fi
  total_removed=$((total_removed + count))
done

if [ "$total_removed" -eq 0 ]; then
  printf 'beams: nothing older than %s on any beam processed\n' "$older_than"
else
  printf 'beams: %s message(s) total%s\n' "$total_removed" "${dry:+ would be removed}"
fi
