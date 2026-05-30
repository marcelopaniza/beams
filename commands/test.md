---
description: "Run the buses smoke test suite (~60s wall clock). Pass round numbers to limit, e.g. /buses:test 3 7."
argument-hint: "[round-numbers...]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/tests/run-all.sh:*)"]
---

```!
read -ra __test_rounds <<<"$(cat <<'BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BUSES_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
"${CLAUDE_PLUGIN_ROOT}/tests/run-all.sh" "${__test_rounds[@]}"
```

Report the outcome in one line ("ALL N rounds passed" or "X round(s) failed: …"). If any round failed, surface the captured tail; otherwise stop.
