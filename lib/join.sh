#!/usr/bin/env bash
# /beams:join <beam> — subscribe this session to a beam.
# - Creates the beam if it doesn't exist (with confirmation prompt skipped: silent autocreate).
# - Drops member record on the shared folder.
# - Starts the cursor at "now" so we don't get flooded with history.

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
[ -n "$beam" ] || beams::die "usage: join.sh <beam>"
beams::valid_name "$beam" || beams::die "invalid beam name: $beam"

if ! beams::beam_exists "$beam"; then
  "$(dirname "$0")/create.sh" "$beam" >/dev/null
fi

# Banlist gate: refuse to join if our session has been kicked.
if beams::is_banned "$beam"; then
  beams::die "you have been kicked from beam '$beam' — ask the driver to /beams:admin unkick you"
fi

# Warn (but do not block) if the beam is locked. You can still receive.
if beams::is_locked "$beam"; then
  reason=$(beams::lock_reason "$beam")
  beams::err "note: beam '$beam' is locked${reason:+ ($reason)} — you can read but cannot send"
fi

# Add to subscriptions if not already.
if ! beams::is_subscribed "$beam"; then
  beams::config_set '.beams |= (. + [$b] | unique)' --arg b "$beam"
fi

# Initialise BOTH cursors at "now" so neither hook nor watcher floods us
# with historical messages we never subscribed for.
mkdir -p "$(beams::state_dir)"
for cursor in "$(beams::cursor_file "$beam")" "$(beams::notify_cursor_file "$beam")"; do
  : > "$cursor"
  touch "$cursor"
done

beams::write_member_record "$beam"
# Re-affirm tight dir perms on the beam we just joined — covers the case where
# the beam was created by an older plugin version with looser default perms.
beams::tighten_perms "$beam"
printf 'beams: joined "%s" (history before now is hidden — use /beams:read --all to see past messages)\n' "$beam"
