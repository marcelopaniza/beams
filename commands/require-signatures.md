---
description: "Driver-only: require all messages on a bus to be cryptographically signed. Turn on once every rider has a published pubkey."
argument-hint: "<bus> on|off"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/require-signatures.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/require-signatures.sh" "$(cat <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm in one line. If turning ON: remind the user that any rider whose `members/<uuid>.json` lacks a `public_key` field will be silently muted until they next run `/buses:join` on the same bus (which publishes their pubkey).
