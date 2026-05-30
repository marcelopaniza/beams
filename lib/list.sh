#!/usr/bin/env bash
# /buses:list — list all buses present on the shared folder, marking subscribed ones.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq
buses::config_require

root=$(buses::shared_root)
buses_root="$root/buses"
[ -d "$buses_root" ] || { printf 'buses: no buses on %s yet\n' "$buses_root"; exit 0; }

printf '%-20s %-10s %-10s %s\n' BUS SUBSCRIBED MEMBERS MESSAGES
while IFS= read -r d; do
  [ -d "$d" ] || continue
  bus=$(basename "$d")
  sub="no"; buses::is_subscribed "$bus" && sub="yes"
  members=$(find "$d/members" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  msgs=$(find "$d/messages" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' ')
  printf '%-20s %-10s %-10s %s\n' "$bus" "$sub" "$members" "$msgs"
done < <(find "$buses_root" -maxdepth 1 -mindepth 1 -type d | LC_ALL=C sort)
