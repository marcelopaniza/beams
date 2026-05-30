#!/usr/bin/env bash
# /beams:lock <beam> [reason...] — driver-only: lock a beam so only the driver
# can send. Members can still read.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq
beams::config_require

# --from-stdin mode: the /beams:lock slash command pipes $ARGUMENTS via a
# quoted-delimiter heredoc so the host shell does NOT expand $(...) or
# backticks inside the user-supplied reason text. Parse the payload here,
# where no further bash evaluation can occur. See lib/send.sh for full
# rationale and tests/round-10.sh for the security regression that
# motivated the pattern.
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
  read -r beam reason_head <<< "$first_line"
  reason="${reason_head:-}"
  [ -n "$rest_lines" ] && reason="${reason}"$'\n'"$rest_lines"
  set -- "${beam:-}" "${reason:-}"
fi

# Single-arg fallback for callers that pass $ARGUMENTS as one quoted string
# (Pattern A in the .md heredoc form, or legacy callers). Word-splits into
# positionals without glob expansion. Direct CLI callers arrive with $# > 1
# and skip this branch.
[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

beam="${1:-}"; shift || true
reason="$*"

[ -n "$beam" ] || beams::die "usage: lock.sh <beam> [reason...]"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist"
beams::is_driver "$beam"  || beams::die "only the driver of '$beam' can lock it"

sid=$(beams::config_get '.session_id')
beams::manifest_set "$beam" \
  '.locked = {by: $by, reason: $r, at: $at}' \
  --arg by "$sid" \
  --arg r  "$reason" \
  --arg at "$(beams::now_iso)"

printf 'beams: beam "%s" locked%s\n' "$beam" "${reason:+ (reason: $reason)}"
