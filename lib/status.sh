#!/usr/bin/env bash
# /beams:status — summarise this session's config and current subscriptions.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq

if ! beams::config_exists; then
  # config_require prints the helpful legacy-detection hint if applicable
  # and exits non-zero. If there's no legacy and no config, it dies with a
  # plain "not initialised" message.
  beams::config_require
fi

shared=$(beams::config_get '.shared_path')
sid=$(beams::config_get '.session_id')
name=$(beams::config_get '.session_name'); [ -n "$name" ] || name='(unset)'
created=$(beams::config_get '.created')

cc_sid=$(beams::terminal_id)
printf 'beams: status\n'
printf '  terminal:     %s%s\n' \
  "${cc_sid:-<not set>}" \
  "$([ -n "$BEAMS_CONFIG_DIR_EXPLICIT" ] && echo "  (BEAMS_CONFIG_DIR override active)")"
printf '  project:      %s\n' "$(beams::project_dir)"
printf '  config:       %s\n' "$BEAMS_CONFIG_FILE"
printf '  shared_path:  %s  ' "$shared"
[ -d "$shared" ] && printf '[ok]\n' || printf '[MISSING — mount the share]\n'
printf '  session_id:   %s\n' "$sid"
printf '  session_name: %s\n' "$name"
printf '  fingerprint:  %s\n' "$(beams::fingerprint || echo '(no key yet)')"
printf '  created:      %s\n' "$created"
printf '\n  subscriptions:\n'

subs=$(jq -r '.beams[]?' "$BEAMS_CONFIG_FILE")
if [ -z "$subs" ]; then
  printf '    (none — /beams:join <beam> to subscribe)\n'
  exit 0
fi

# Per-beam stats — count all messages and those newer than the cursor.
# (Cursor-newer is a superset of "actually addressed to me" — it's the
# delivery queue length, not the per-recipient unread.)
while IFS= read -r beam; do
  [ -n "$beam" ] || continue
  if beams::beam_exists "$beam"; then
    mdir=$(beams::beam_messages "$beam")
    total=$(find "$mdir" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' ')
    cursor=$(beams::cursor_file "$beam")
    if [ -f "$cursor" ]; then
      unseen=$(find "$mdir" -maxdepth 1 -name '*.msg' -type f -newer "$cursor" 2>/dev/null | wc -l | tr -d ' ')
    else
      unseen=$total
    fi
    printf '    %-20s  total=%-5s  newer-than-cursor=%s\n' "$beam" "$total" "$unseen"
  else
    printf '    %-20s  [beam missing on shared folder]\n' "$beam"
  fi
done <<< "$subs"
