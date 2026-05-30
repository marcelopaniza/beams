---
description: "Driver-only: kick a member from a bus (adds to banlist + drops a notice for them)."
argument-hint: "<bus> <name-or-uuid> [reason...]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/kick.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/kick.sh" --from-stdin <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
```

Confirm in one line. Banning is cooperative: it relies on every session running this plugin — anyone with raw write access to the shared folder can bypass.
