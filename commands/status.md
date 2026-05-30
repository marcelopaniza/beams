---
description: "Show this session's beams config: shared path, session id/name, subscriptions, unread counts."
argument-hint: "(no arguments)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/status.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/status.sh"
```

Echo the table verbatim so the user can see counts. Add a one-line interpretation only if something looks wrong (missing share, no subscriptions, etc.).
