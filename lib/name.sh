#!/usr/bin/env bash
# /beams:name <friendly-name> — set this session's friendly name and refresh
# member records on all subscribed beams.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq
beams::config_require

# The matching .md command quotes "$ARGUMENTS" as a single arg for safety
# against shell metacharacters in user input. Re-split it into positionals
# here (whitespace-only; no shell interpretation). When tests call the
# script directly with already-split args, $# > 1 and we leave them alone.
[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

new="${1:-}"
[ -n "$new" ] || beams::die "usage: name.sh <friendly-name>"
beams::valid_name "$new" || beams::die "invalid name: $new (allowed: A-Z a-z 0-9 . _ -, length 1-64)"

beams::config_set '.session_name = $v' --arg v "$new"

# Update presence in every joined beam.
while IFS= read -r beam; do
  [ -n "$beam" ] || continue
  beams::beam_exists "$beam" && beams::write_member_record "$beam"
done < <(jq -r '.beams[]?' "$BEAMS_CONFIG_FILE")

printf 'beams: session name set to "%s"\n' "$new"
