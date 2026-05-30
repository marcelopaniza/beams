---
description: "Unsubscribe this session from a beam and remove its presence record."
argument-hint: "<beam-name>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/leave.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/leave.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm in one line.
