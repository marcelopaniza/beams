#!/usr/bin/env bash
# /buses:transfer-driver <bus> <name-or-uuid> [--force]
#
# Driver-only by default. With --force, any subscribed member can claim
# driver — intended as an escape hatch when the current driver's machine
# is gone and the bus is "stuck."
#
# Target must be a real member of the bus (we don't transfer to a stale
# or imaginary UUID), unless --force is also set on the target check.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq
buses::config_require

# The matching .md command quotes "$ARGUMENTS" as a single arg for safety
# against shell metacharacters in user input. Re-split it into positionals
# here (whitespace-only; no shell interpretation). When tests call the
# script directly with already-split args, $# > 1 and we leave them alone.
[ "$#" -le 1 ] && { read -ra __buses_args <<<"${1-}"; set -- "${__buses_args[@]}"; unset __buses_args; }

bus="${1:-}"
who="${2:-}"
force=""
for a in "${@:3}"; do [ "$a" = "--force" ] && force=1; done

[ -n "$bus" ] && [ -n "$who" ] || buses::die "usage: transfer-driver.sh <bus> <name-or-uuid> [--force]"
buses::bus_exists "$bus" || buses::die "bus '$bus' does not exist"

current_drv=$(buses::driver_uuid "$bus")
my_sid=$(buses::config_get '.session_id')

# Authorisation
if [ -z "$force" ]; then
  buses::is_driver "$bus" || buses::die "only the current driver can transfer (use --force if the driver is gone)"
else
  # --force is the escape hatch for "the driver's machine is dead and the
  # bus is stuck." It deliberately requires that:
  #   1. you are subscribed to the bus (so you have skin in the game)
  #   2. the current driver has no member record, OR their last_seen is
  #      older than 7 days — i.e. they really are absent, not just AFK
  #      for a coffee break. This is cooperative enforcement (the share is
  #      a cooperative folder; a determined peer can bypass), but it's
  #      explicit so casual misuse is visible to everyone.
  if ! buses::is_subscribed "$bus"; then
    buses::die "you must be subscribed to '$bus' to take it over (--force)"
  fi
  if [ -n "$current_drv" ]; then
    drv_record="$(buses::bus_members "$bus")/$current_drv.json"
    if [ -f "$drv_record" ]; then
      # mtime check: 7 days old? GNU find supports +7; BSD find too.
      if ! find "$drv_record" -mtime +7 -print -quit 2>/dev/null | grep -q .; then
        buses::die "current driver $current_drv was active in the last 7 days — refusing --force takeover (delete their member record manually if you are SURE they are gone)"
      fi
    fi
  fi
fi

# Resolve target
target=$(buses::resolve_member "$bus" "$who")
if [ -z "$target" ]; then
  if [ -n "$force" ]; then
    # Allow raw UUID even if not a current member (in case the target hasn't
    # rejoined yet) — but make sure it looks like a UUID.
    case "$who" in
      [0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*-*) target="$who" ;;
      *) buses::die "target '$who' is not a current member; pass a full UUID with --force if intended" ;;
    esac
  else
    buses::die "target '$who' is not a current member of '$bus' (use --force + UUID to override)"
  fi
fi

if [ "$target" = "$current_drv" ]; then
  printf 'buses: %s is already the driver of "%s"\n' "$target" "$bus"
  exit 0
fi

buses::set_driver "$bus" "$target"
printf 'buses: driver of "%s" transferred:\n' "$bus"
printf '         from: %s\n' "${current_drv:-(none)}"
printf '         to:   %s\n' "$target"
