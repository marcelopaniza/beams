#!/usr/bin/env bash
# /beams:require-signatures <beam> on|off
#
# Driver-only. Set the per-beam `require_signatures` flag in the manifest.
# When ON: msg_validate rejects any message from a sender whose member
# record lacks a `public_key` field — closing the migration window where
# unsigned messages from no-pubkey-published senders are accepted.
#
# Use this once every active rider in a beam has run a /beams:join under
# v0.5+ (so their pubkey is published). After that, unsigned messages from
# pretend identities created on the share can no longer slip through.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq
beams::config_require

[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

beam="${1:-}"
mode="${2:-}"
[ -n "$beam" ] && [ -n "$mode" ] || beams::die "usage: require-signatures.sh <beam> on|off"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"
beams::is_driver "$beam"  || beams::die "only the driver of '$beam' can change the signature policy"

case "$mode" in
  on|true|1)  val=true  ;;
  off|false|0) val=false ;;
  *) beams::die "mode must be 'on' or 'off' (got: $mode)" ;;
esac

beams::manifest_set "$beam" '.require_signatures = $v' --argjson v "$val"
if [ "$val" = "true" ]; then
  printf 'beams: beam "%s" now REQUIRES signed messages — riders without published pubkeys will be silently dropped.\n' "$beam"
else
  printf 'beams: beam "%s" — signature requirement disabled. Unsigned messages from no-pubkey peers will be accepted (migration mode).\n' "$beam"
fi
