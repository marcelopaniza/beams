---
description: "List the riders of a beam (also available as /beams:riders) — session id, name, host, last seen, role."
argument-hint: "<beam-name>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/members.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/members.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Echo the table. The driver is marked in the ROLE column; everyone else is a rider. If a rider name appears more than once, mention to the user that they may want to disambiguate by UUID when sending.
