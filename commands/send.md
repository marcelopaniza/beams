---
description: "Send a message to a bus. Recipient can be a session name, session UUID, or 'all' to broadcast."
argument-hint: "<bus> <to|all> <message...>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/send.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/send.sh" --from-stdin <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
```

Confirm in one line which bus and recipient received the message.
