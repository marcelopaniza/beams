#!/usr/bin/env bash
# /beams:create <beam> — create a new beam on the shared folder.
# Idempotent: succeeds quietly if it already exists.

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
[ -n "$beam" ] || beams::die "usage: create.sh <beam>"
beams::valid_name "$beam" || beams::die "invalid beam name: $beam"

dir=$(beams::beam_dir "$beam")
created=no
if [ ! -d "$dir" ]; then
  mkdir -p "$dir/messages" "$dir/members" || beams::die "cannot create $dir (shared path writable?)"
  jq -n \
    --arg n "$beam" \
    --arg c "$(beams::now_iso)" \
    --arg by "$(beams::config_get '.session_id')" \
    '{name: $n, created: $c, created_by: $by, driver: $by}' > "$dir/manifest.json"
  created=yes
fi
# Idempotent: re-affirm 0700 perms whether we just created or it already existed.
# Cheap defense for older shares that pre-date the umask change.
beams::tighten_perms "$beam"

printf 'beams: beam "%s" %s at %s\n' "$beam" \
  "$([ "$created" = yes ] && echo created || echo "already existed")" "$dir"
