---
description: "Driver-only: delete old messages from a beam (or 'all' beams). Default: messages older than 90 days. Supports --dry-run."
argument-hint: "<beam|all> [--older-than 90d|7d|12h] [--dry-run] [--force]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/gc.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/gc.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Echo what was removed (or what would be removed in --dry-run). If many beams were skipped because the user wasn't driver, mention that they can pass --force to GC them anyway (cooperatively — same caveats as kick/lock).
