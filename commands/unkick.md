---
description: "Driver-only: lift a ban on a member, allowing them to rejoin and send."
argument-hint: "<beam> <name-or-uuid>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/unkick.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/unkick.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm in one line.
