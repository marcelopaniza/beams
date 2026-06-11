---
description: "Start/stop the background watcher daemon that fires desktop notifications and feeds the real-time doorbell for new beam messages. Uses zero tokens — pure polling daemon, not a model loop."
argument-hint: "[start [interval] [--on-message <shell-cmd>] | stop | restart [interval] [--on-message <shell-cmd>] | status | logs [n]]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/lib/watch.sh:*)"]
---

```!
"${CLAUDE_PLUGIN_ROOT}/lib/watch.sh" "$(cat <<'BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a'
$ARGUMENTS
BEAMS_END_PAYLOAD_3f5a8c2d1b9e7f0a
)"
```

Report the output verbatim. If the user is starting the watcher for the first time, mention that:
- It runs detached; it survives this terminal closing.
- It uses a separate "notification cursor", so messages will STILL appear inside Claude on the next user prompt — notifications and in-conversation delivery are independent.
- On NFS / Syncthing / Dropbox the polling interval (default 5s) is the only way to detect remote writes — inotify cannot see other machines' changes.
- Session start (re)arms it automatically with the doorbell hook (`lib/on-message.sh`) — that is how a new message wakes an idle Claude session in real time.
- Stop it with `/beams:watch stop` when no longer needed.

If the user passed `--on-message <shell-cmd>`, also mention that:
- The snippet runs once per new message, in the background, capped at 30s (override with `BEAMS_ON_MESSAGE_TIMEOUT`).
- Env vars exposed: `BEAMS_BEAM`, `BEAMS_FROM`, `BEAMS_PREVIEW`. Reference them quoted (`"$BEAMS_PREVIEW"`) — never unquoted.
- The cmd is held only in the daemon's memory. A `restart` without `--on-message` clears it — and it replaces the stock doorbell hook for this daemon run; the next session start re-arms the stock one (set `react.watch_on_boot: false` for full manual control).
- Output goes to `~/.config/beams/state/on-message.log`; `/beams:watch status` shows the tail.
