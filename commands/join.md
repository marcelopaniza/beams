---
description: "Subscribe this session to a bus. Auto-creates the bus if it doesn't exist."
argument-hint: "<bus-name>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/join.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/join.sh" "$(cat <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm the subscription in one line. Mention that future messages on this bus addressed to this session (or `all`) will appear automatically on the next user prompt — no polling needed.
