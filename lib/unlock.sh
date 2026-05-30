#!/usr/bin/env bash
# /beams:unlock <beam> — driver-only: clear the lock on a beam.

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
[ -n "$beam" ] || beams::die "usage: unlock.sh <beam>"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"
beams::is_driver "$beam"  || beams::die "only the driver of '$beam' can unlock it"

if ! beams::is_locked "$beam"; then
  printf 'beams: beam "%s" was not locked\n' "$beam"
  exit 0
fi

beams::manifest_set "$beam" 'del(.locked)'
printf 'beams: beam "%s" unlocked\n' "$beam"
