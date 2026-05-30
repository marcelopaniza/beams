---
description: "Driver-only: require all messages on a beam to be cryptographically signed. Turn on once every rider has a published pubkey."
argument-hint: "<beam> on|off"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/require-signatures.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/require-signatures.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Confirm in one line. If turning ON: remind the user that any rider whose `members/<uuid>.json` lacks a `public_key` field will be silently muted until they next run `/beams:join` on the same beam (which publishes their pubkey).
