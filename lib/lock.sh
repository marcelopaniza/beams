#!/usr/bin/env bash
# /buses:lock <bus> [reason...] — driver-only: lock a bus so only the driver
# can send. Members can still read.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq
buses::config_require

# --from-stdin mode: the /buses:lock slash command pipes $ARGUMENTS via a
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
  read -r bus reason_head <<< "$first_line"
  reason="${reason_head:-}"
  [ -n "$rest_lines" ] && reason="${reason}"$'\n'"$rest_lines"
  set -- "${bus:-}" "${reason:-}"
fi

# Single-arg fallback for callers that pass $ARGUMENTS as one quoted string
# (Pattern A in the .md heredoc form, or legacy callers). Word-splits into
# positionals without glob expansion. Direct CLI callers arrive with $# > 1
# and skip this branch.
[ "$#" -le 1 ] && { read -ra __buses_args <<<"${1-}"; set -- "${__buses_args[@]}"; unset __buses_args; }

bus="${1:-}"; shift || true
reason="$*"

[ -n "$bus" ] || buses::die "usage: lock.sh <bus> [reason...]"
buses::bus_exists "$bus" || buses::die "bus '$bus' does not exist"
buses::is_driver "$bus"  || buses::die "only the driver of '$bus' can lock it"

sid=$(buses::config_get '.session_id')
buses::manifest_set "$bus" \
  '.locked = {by: $by, reason: $r, at: $at}' \
  --arg by "$sid" \
  --arg r  "$reason" \
  --arg at "$(buses::now_iso)"

printf 'buses: bus "%s" locked%s\n' "$bus" "${reason:+ (reason: $reason)}"
