---
description: "Driver-only: remove member records that haven't checked in recently. Default threshold 30 days. Use --dry-run to preview."
argument-hint: "<beam> [--older-than 30d|7d|12h|90m] [--dry-run] [--force]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/cleanup-stale.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/cleanup-stale.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Echo what was removed (or what would be removed in --dry-run). If the driver's own record was skipped, mention it once.
