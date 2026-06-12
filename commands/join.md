---
description: "Subscribe this session to a beam. Auto-creates the beam if it doesn't exist."
argument-hint: "<beam-name>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/join.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/join.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

If the output contains a "beams doorbell" block, follow it FIRST: arm the Monitor with exactly the arguments it gives (one call — skip if this session already armed a beams doorbell monitor).

Then confirm the subscription in one line. Mention that future messages on this beam addressed to this session (or `all`) will appear automatically on the next user prompt — no polling needed — and in real time via the doorbell when it's armed.
