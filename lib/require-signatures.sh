#!/usr/bin/env bash
# /buses:require-signatures <bus> on|off
#
# Driver-only. Set the per-bus `require_signatures` flag in the manifest.
# When ON: msg_validate rejects any message from a sender whose member
# record lacks a `public_key` field — closing the migration window where
# unsigned messages from no-pubkey-published senders are accepted.
#
# Use this once every active rider in a bus has run a /buses:join under
# v0.5+ (so their pubkey is published). After that, unsigned messages from
# pretend identities created on the share can no longer slip through.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq
buses::config_require

[ "$#" -le 1 ] && { read -ra __buses_args <<<"${1-}"; set -- "${__buses_args[@]}"; unset __buses_args; }

bus="${1:-}"
mode="${2:-}"
[ -n "$bus" ] && [ -n "$mode" ] || buses::die "usage: require-signatures.sh <bus> on|off"
buses::bus_exists "$bus" || buses::die "bus '$bus' does not exist"
buses::is_driver "$bus"  || buses::die "only the driver of '$bus' can change the signature policy"

case "$mode" in
  on|true|1)  val=true  ;;
  off|false|0) val=false ;;
  *) buses::die "mode must be 'on' or 'off' (got: $mode)" ;;
esac

buses::manifest_set "$bus" '.require_signatures = $v' --argjson v "$val"
if [ "$val" = "true" ]; then
  printf 'buses: bus "%s" now REQUIRES signed messages — riders without published pubkeys will be silently dropped.\n' "$bus"
else
  printf 'buses: bus "%s" — signature requirement disabled. Unsigned messages from no-pubkey peers will be accepted (migration mode).\n' "$bus"
fi
