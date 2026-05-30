---
description: "Initialise buses on this machine: set the shared folder path and generate a session UUID."
argument-hint: "<shared-folder-path> [--force] [--profile <name>]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/init.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/init.sh" "$(cat <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Report the output above to the user in one or two lines. If initialisation succeeded, remind them they can run `/buses:name <friendly-name>` next, then `/buses:create <bus>` or `/buses:join <bus>`.
