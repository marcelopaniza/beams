#!/usr/bin/env bash
# /beams:name <friendly-name> [--force] — name this terminal and bind it to a
# durable, name-keyed identity so it survives a Claude restart (a fresh session
# id no longer orphans the config). On a session that already owns its config
# this just renames; on a fresh/unbound session it rebinds to the existing
# identity of that name (restoring its UUID + subscriptions) or creates a new
# one. --force takes over a name another live session still holds (see the lease).

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq

# The matching .md command quotes "$ARGUMENTS" as a single arg for safety
# against shell metacharacters. Re-split into positionals (whitespace only).
[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

force=""; new=""
for a in "$@"; do
  case "$a" in
    --force) force="--force" ;;
    *) [ -z "$new" ] && new="$a" ;;
  esac
done
[ -n "$new" ] || beams::die "usage: name.sh <friendly-name> [--force]"

# Plain-rename fast path (preserves prior behaviour, keeps the lib testable):
#   - an explicit BEAMS_CONFIG_DIR override pins the identity directly, OR
#   - this session is already bound to exactly this name.
# Otherwise fall through to the bind machinery (unbound / name switch / lease).
if [ -n "$BEAMS_CONFIG_DIR_EXPLICIT" ] \
   || { beams::config_exists && [ -n "$(beams::bound_name)" ] && [ "$(beams::bound_name)" = "$(beams::_safe_key "$new")" ]; }; then
  beams::config_require
  beams::valid_name "$new" || beams::die "invalid name: $new (allowed: A-Z a-z 0-9 . _ -, length 1-64)"
  beams::config_set '.session_name = $v' --arg v "$new"
  # Update presence in every joined beam.
  while IFS= read -r beam; do
    [ -n "$beam" ] || continue
    beams::beam_exists "$beam" && beams::write_member_record "$beam"
  done < <(jq -r '.beams[]?' "$BEAMS_CONFIG_FILE")
  beams::lease_refresh
  printf 'beams: session name set to "%s"\n' "$new"
  exit 0
fi

# Unbound, switching identity, or fresh → bind (handles rebind / create / migrate).
beams::bind_session $force "$new"
