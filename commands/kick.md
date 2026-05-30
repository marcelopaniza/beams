---
description: "Driver-only: kick a member from a beam (adds to banlist + drops a notice for them)."
argument-hint: "<beam> <name-or-uuid> [reason...]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/kick.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/kick.sh" --from-stdin <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
```

Confirm in one line. Banning is cooperative: it relies on every session running this plugin — anyone with raw write access to the shared folder can bypass.
