#!/usr/bin/env bash
# /beams:list — list all beams present on the shared folder, marking subscribed ones.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq
beams::config_require

root=$(beams::shared_root)
beams_root="$root/beams"
[ -d "$beams_root" ] || { printf 'beams: no beams on %s yet\n' "$beams_root"; exit 0; }

printf '%-20s %-10s %-10s %s\n' BEAM SUBSCRIBED MEMBERS MESSAGES
while IFS= read -r d; do
  [ -d "$d" ] || continue
  beam=$(basename "$d")
  sub="no"; beams::is_subscribed "$beam" && sub="yes"
  members=$(find "$d/members" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  msgs=$(find "$d/messages" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' ')
  printf '%-20s %-10s %-10s %s\n' "$beam" "$sub" "$members" "$msgs"
done < <(find "$beams_root" -maxdepth 1 -mindepth 1 -type d | LC_ALL=C sort)
