#!/usr/bin/env bash
# /beams:admin unkick <beam> <name-or-uuid> — driver-only: remove a UUID from the banlist.
# Note: cannot resolve by friendly name once the member record is gone, so
# accepts a UUID directly, or a still-present name (some kick flows preserve names).

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
who="${2:-}"
[ -n "$beam" ] && [ -n "$who" ] || beams::die "usage: unkick.sh <beam> <name-or-uuid>"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"
beams::is_driver "$beam"  || beams::die "only the driver of '$beam' can unkick"

# Try member resolution first (in case they rejoined under a new record);
# otherwise treat input as a raw UUID.
target=$(beams::resolve_member "$beam" "$who")
[ -n "$target" ] || target="$who"

if ! beams::is_banned "$beam" "$target"; then
  printf 'beams: %s was not banned from "%s"\n' "$target" "$beam"
  exit 0
fi

beams::manifest_set "$beam" \
  '.banned = ((.banned // []) - [$t])' \
  --arg t "$target"

printf 'beams: lifted ban on %s in "%s"\n' "$target" "$beam"
