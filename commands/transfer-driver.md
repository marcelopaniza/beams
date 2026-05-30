---
description: "Driver-only: transfer driver privileges to another member. Use --force to take over a beam whose driver is gone."
argument-hint: "<beam> <name-or-uuid> [--force]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/transfer-driver.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/transfer-driver.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm in one line: who's the new driver. If --force was used, mention briefly that the beam has been taken over (a one-off action, not a hostile one — the share is cooperative).
