#!/usr/bin/env bash
# Write a single message file into a beam, atomically.
# Usage: send.sh <beam> <to> <body...>
#
# <to> can be:
#   all                       broadcast to every subscriber
#   <name|uuid>               single direct recipient
#   <name1>,<name2>,<uuid3>   comma-separated list of direct recipients
#
# The body may also contain @<name> mentions. A receiver matches if its
# name or short UUID appears in `to` OR is @-tagged in the body.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq
beams::config_require

# --from-stdin mode: the /beams:send slash command pipes $ARGUMENTS via a
# heredoc with a single-quoted delimiter, so the host shell does NOT expand
# $(...) or backticks inside the user's message body. We parse the payload
# here, where no further bash evaluation can occur, then fall through to the
# regular flow with beam/to/body set as positional args.
#
# Why this matters: the previous slash-command shape was
#   "${CLAUDE_PLUGIN_ROOT}/lib/send.sh" "$ARGUMENTS"
# Claude Code substitutes $ARGUMENTS into the .md template BEFORE bash
# parses it, so the resulting bash source had the body sitting inside
# double quotes — where command substitution and backticks still fire. A
# body like `hi $(touch /tmp/x)` therefore executed the touch on the
# SENDER's machine while the message was being sent. See tests/round-10.sh.
if [ "${1:-}" = "--from-stdin" ]; then
  shift
  # Slurp stdin preserving exact bytes (the `printf x; ${var%x}` dance
  # avoids the trailing-newline strip that command substitution does).
  payload=$(cat; printf x)
  payload=${payload%x}
  # The closing heredoc line adds exactly one trailing newline; remove it
  # so the body is byte-equal to what the user typed.
  payload=${payload%$'\n'}

  # beam + to live on the first physical line; body is the rest of that
  # line plus every subsequent line. read -r preserves backslashes.
  if [[ "$payload" == *$'\n'* ]]; then
    first_line=${payload%%$'\n'*}
    rest_lines=${payload#*$'\n'}
  else
    first_line="$payload"
    rest_lines=""
  fi
  read -r beam to body_head <<< "$first_line"
  body="${body_head:-}"
  [ -n "$rest_lines" ] && body="${body}"$'\n'"$rest_lines"

  set -- "${beam:-}" "${to:-}" "${body:-}"
fi

# Legacy single-string callers (older slash-command shape, ad-hoc shell
# invocations): collapse a single positional arg into whitespace-split
# tokens. Direct CLI / bin/beams callers (and the --from-stdin branch
# above) all arrive with $# > 1, so this is a no-op for them.
[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

beam="${1:-}"; shift || true
to="${1:-}";  shift || true
body="$*"

[ -n "$beam" ]  || beams::die "usage: send.sh <beam> <to> <body...>"
[ -n "$to" ]   || beams::die "missing <to> (use 'all' to broadcast)"
[ -n "$body" ] || beams::die "empty message body"

beams::valid_name "$beam" || beams::die "invalid beam name: $beam"
beams::beam_exists "$beam" || beams::die "beam '$beam' does not exist on the shared folder"

# Banlist gate: refuse if our session has been kicked from this beam.
if beams::is_banned "$beam"; then
  beams::die "you have been kicked from beam '$beam' — ask the driver to /beams:unkick you"
fi

# Lock gate: refuse if locked, unless we are the driver.
if beams::is_locked "$beam" && ! beams::is_driver "$beam"; then
  reason=$(beams::lock_reason "$beam")
  beams::die "beam '$beam' is locked${reason:+ ($reason)} — only the driver can send"
fi

# Normalise the `to` field: split on commas, trim whitespace, drop empties.
# Whatever the user typed (a single name, "all", or "loop,felix") is preserved
# verbatim in the frontmatter — check.sh does the splitting at receive time.
to_normalised=$(printf '%s' "$to" \
  | tr ',' '\n' \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$' \
  | paste -sd ',' -)
[ -n "$to_normalised" ] || beams::die "no valid recipients after normalising '$to'"

# Single-recipient back-compat: only when there's exactly one non-'all' name.
# Look up its UUID so receivers with name collisions can still disambiguate.
to_id=""
if [[ "$to_normalised" != *,* ]] && [ "$to_normalised" != "all" ]; then
  members_dir=$(beams::beam_members "$beam")
  if [ -d "$members_dir" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      mname=$(jq -r '.name // ""' "$f" 2>/dev/null)
      mid_candidate=$(jq -r '.id // ""' "$f" 2>/dev/null)
      if [ "$mname" = "$to_normalised" ] || [ "$mid_candidate" = "$to_normalised" ]; then
        to_id="$mid_candidate"
        break
      fi
    done < <(find "$members_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
  fi
fi

# Delegate file build + sign + atomic write to the shared helper.
result=$(beams::write_message "$beam" "$to_normalised" "$body" "$to_id") \
  || beams::die "send failed (check openssl install)"
fname="${result% *}"
mid="${result##* }"

# Refresh our presence (best effort).
beams::write_member_record "$beam" >/dev/null 2>&1 || true

# Echo back any @-mentions in the body as a usability cue.
mentions=$(printf '%s' "$body" | { grep -oE '@[A-Za-z0-9._-]+' || true; } \
                                | sort -u | paste -sd ' ' -)
printf 'sent: %s/%s  to=%s%s  (id=%s)\n' \
  "$beam" "$fname" "$to_normalised" "${mentions:+  mentions=$mentions}" "$mid"
