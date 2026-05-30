---
description: "Set or change this session's friendly name (used by other sessions to address you)."
argument-hint: "<friendly-name>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/name.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/name.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm the new name in one short line.
