#!/usr/bin/env bash
# /beams:kick <beam> <name-or-uuid> [reason...] — driver-only.
# Adds the target's UUID to manifest.banned and removes their member record.
# Cooperative enforcement: other sessions' send/join refuses for banned UUIDs.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq
beams::config_require

# --from-stdin mode: identical pattern to lib/lock.sh and lib/send.sh —
# parse a heredoc payload piped from the /beams:kick slash command, where
# the quoted-delimiter heredoc has already suppressed $(...) / backtick
# expansion in the user-supplied reason text. See lib/send.sh for the
# full rationale.
if [ "${1:-}" = "--from-stdin" ]; then
  shift
  payload=$(cat; printf x)
  payload=${payload%x}
  payload=${payload%$'\n'}
  if [[ "$payload" == *$'\n'* ]]; then
    first_line=${payload%%$'\n'*}
    rest_lines=${payload#*$'\n'}
  else
    first_line="$payload"
    rest_lines=""
  fi
  read -r beam who reason_head <<< "$first_line"
  reason="${reason_head:-}"
  [ -n "$rest_lines" ] && reason="${reason}"$'\n'"$rest_lines"
  set -- "${beam:-}" "${who:-}" "${reason:-}"
fi

# Single-arg fallback for Pattern A / legacy callers. See lib/lock.sh.
[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

beam="${1:-}"; shift || true
who="${1:-}"; shift || true
reason="$*"

[ -n "$beam" ] && [ -n "$who" ] || beams::die "usage: kick.sh <beam> <name-or-uuid> [reason...]"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"
beams::is_driver "$beam"  || beams::die "only the driver of '$beam' can kick"

target=$(beams::resolve_member "$beam" "$who")
[ -n "$target" ] || beams::die "no member named '$who' (or matching UUID) in beam '$beam'"

drv=$(beams::driver_uuid "$beam")
[ "$target" != "$drv" ] || beams::die "refusing to kick the driver — /beams:transfer-driver first"

if beams::is_banned "$beam" "$target"; then
  printf 'beams: %s is already banned from "%s"\n' "$target" "$beam"
  exit 0
fi

beams::manifest_set "$beam" \
  '.banned = ((.banned // []) + [$t] | unique)' \
  --arg t "$target"

members_dir=$(beams::beam_members "$beam")
rm -f "$members_dir/$target.json"

# Drop a signed notice file so the kicked session sees it on their next
# prompt. Delegated to the shared write helper.
name=$(beams::config_get '.session_name'); [ -n "$name" ] || name="(driver)"
body_text=$(printf 'You have been kicked from beam "%s" by driver %s.%s' \
  "$beam" "$name" "${reason:+ Reason: $reason}")
beams::write_message "$beam" "$target" "$body_text" "$target" "kick-notice" >/dev/null \
  || beams::die "signing kick notice failed"

printf 'beams: kicked %s from "%s"%s\n' "$target" "$beam" "${reason:+ (reason: $reason)}"
