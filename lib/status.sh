#!/usr/bin/env bash
# /buses:status — summarise this session's config and current subscriptions.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq

if ! buses::config_exists; then
  # config_require prints the helpful legacy-detection hint if applicable
  # and exits non-zero. If there's no legacy and no config, it dies with a
  # plain "not initialised" message.
  buses::config_require
fi

shared=$(buses::config_get '.shared_path')
sid=$(buses::config_get '.session_id')
name=$(buses::config_get '.session_name'); [ -n "$name" ] || name='(unset)'
created=$(buses::config_get '.created')

cc_sid=$(buses::terminal_id)
printf 'buses: status\n'
printf '  terminal:     %s%s\n' \
  "${cc_sid:-<not set>}" \
  "$([ -n "$BUSES_CONFIG_DIR_EXPLICIT" ] && echo "  (BUSES_CONFIG_DIR override active)")"
printf '  project:      %s\n' "$(buses::project_dir)"
printf '  config:       %s\n' "$BUSES_CONFIG_FILE"
printf '  shared_path:  %s  ' "$shared"
[ -d "$shared" ] && printf '[ok]\n' || printf '[MISSING — mount the share]\n'
printf '  session_id:   %s\n' "$sid"
printf '  session_name: %s\n' "$name"
printf '  fingerprint:  %s\n' "$(buses::fingerprint || echo '(no key yet)')"
printf '  created:      %s\n' "$created"
printf '\n  subscriptions:\n'

subs=$(jq -r '.buses[]?' "$BUSES_CONFIG_FILE")
if [ -z "$subs" ]; then
  printf '    (none — /buses:join <bus> to subscribe)\n'
  exit 0
fi

# Per-bus stats — count all messages and those newer than the cursor.
# (Cursor-newer is a superset of "actually addressed to me" — it's the
# delivery queue length, not the per-recipient unread.)
while IFS= read -r bus; do
  [ -n "$bus" ] || continue
  if buses::bus_exists "$bus"; then
    mdir=$(buses::bus_messages "$bus")
    total=$(find "$mdir" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' ')
    cursor=$(buses::cursor_file "$bus")
    if [ -f "$cursor" ]; then
      unseen=$(find "$mdir" -maxdepth 1 -name '*.msg' -type f -newer "$cursor" 2>/dev/null | wc -l | tr -d ' ')
    else
      unseen=$total
    fi
    printf '    %-20s  total=%-5s  newer-than-cursor=%s\n' "$bus" "$total" "$unseen"
  else
    printf '    %-20s  [bus missing on shared folder]\n' "$bus"
  fi
done <<< "$subs"
