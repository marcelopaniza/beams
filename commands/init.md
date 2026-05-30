---
description: "Initialise beams on this machine: set the shared folder path and generate a session UUID."
argument-hint: "<shared-folder-path> [--force] [--profile <name>]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/init.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/init.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Report the output above to the user in one or two lines. If initialisation succeeded, remind them they can run `/beams:name <friendly-name>` next, then `/beams:create <beam>` or `/beams:join <beam>`.
