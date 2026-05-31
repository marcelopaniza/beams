#!/usr/bin/env bash
# /beams:admin transfer-driver <beam> <name-or-uuid> [--force]
#
# Driver-only by default. With --force, any subscribed member can claim
# driver — intended as an escape hatch when the current driver's machine
# is gone and the beam is "stuck."
#
# Target must be a real member of the beam (we don't transfer to a stale
# or imaginary UUID), unless --force is also set on the target check.

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
force=""
for a in "${@:3}"; do [ "$a" = "--force" ] && force=1; done

[ -n "$beam" ] && [ -n "$who" ] || beams::die "usage: transfer-driver.sh <beam> <name-or-uuid> [--force]"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"

current_drv=$(beams::driver_uuid "$beam")
my_sid=$(beams::config_get '.session_id')

# Authorisation
if [ -z "$force" ]; then
  beams::is_driver "$beam" || beams::die "only the current driver can transfer (use --force if the driver is gone)"
else
  # --force is the escape hatch for "the driver's machine is dead and the
  # beam is stuck." It deliberately requires that:
  #   1. you are subscribed to the beam (so you have skin in the game)
  #   2. the current driver has no member record, OR their last_seen is
  #      older than 7 days — i.e. they really are absent, not just AFK
  #      for a coffee break. This is cooperative enforcement (the share is
  #      a cooperative folder; a determined peer can bypass), but it's
  #      explicit so casual misuse is visible to everyone.
  if ! beams::is_subscribed "$beam"; then
    beams::die "you must be subscribed to '$beam' to take it over (--force)"
  fi
  if [ -n "$current_drv" ]; then
    drv_record="$(beams::beam_members "$beam")/$current_drv.json"
    if [ -f "$drv_record" ]; then
      # mtime check: 7 days old? GNU find supports +7; BSD find too.
      if ! find "$drv_record" -mtime +7 -print -quit 2>/dev/null | grep -q .; then
        beams::die "current driver $current_drv was active in the last 7 days — refusing --force takeover (delete their member record manually if you are SURE they are gone)"
      fi
    fi
  fi
fi

# Resolve target
target=$(beams::resolve_member "$beam" "$who")
if [ -z "$target" ]; then
  if [ -n "$force" ]; then
    # Allow raw UUID even if not a current member (in case the target hasn't
    # rejoined yet) — but make sure it looks like a UUID.
    case "$who" in
      [0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*-*) target="$who" ;;
      *) beams::die "target '$who' is not a current member; pass a full UUID with --force if intended" ;;
    esac
  else
    beams::die "target '$who' is not a current member of '$beam' (use --force + UUID to override)"
  fi
fi

if [ "$target" = "$current_drv" ]; then
  printf 'beams: %s is already the driver of "%s"\n' "$target" "$beam"
  exit 0
fi

beams::set_driver "$beam" "$target"
printf 'beams: driver of "%s" transferred:\n' "$beam"
printf '         from: %s\n' "${current_drv:-(none)}"
printf '         to:   %s\n' "$target"
