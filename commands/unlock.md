---
description: "Driver-only: clear the lock on a beam so everyone can send again."
argument-hint: "<beam>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/unlock.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/unlock.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm in one line.
