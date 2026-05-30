---
description: "Send a message to a beam. Recipient can be a session name, session UUID, or 'all' to broadcast."
argument-hint: "<beam> <to|all> <message...>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/send.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/send.sh" --from-stdin <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
```

Confirm in one line which beam and recipient received the message.
