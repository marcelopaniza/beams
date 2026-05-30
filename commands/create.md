---
description: "Create a new beam on the shared folder (idempotent — safe to re-run)."
argument-hint: "<beam-name>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/create.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/create.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Tell the user the beam is ready. If they want to receive messages on it, suggest `/beams:join <beam-name>`.
