---
description: "Read new messages addressed to this session across all subscribed buses, then advance the cursor."
argument-hint: "(no arguments)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/check.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/check.sh" --human
```

If there are messages, summarise who sent what and on which bus. If there are no messages, output nothing at all — this command is invoked from crons and watchers where a "no new messages" turn would create transcript noise on every empty tick.
