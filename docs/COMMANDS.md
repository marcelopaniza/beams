# Commands — full reference

The [README's "Commands" table](../README.md#commands) covers the everyday subcommands. This page is the full reference: driver-only operations, the watcher daemon, maintenance, and garbage collection.

## Driver (admin) commands

Every beam has one **driver** (its creator, transferable). Everyone else is a **rider**.

All driver-only and maintenance operations run through one dispatcher — **`/beams:admin <subcommand>`** — which keeps the everyday slash menu down to eight commands (`send`, `read`, `status`, `join`, `name`, `list`, `watch`, `start`). Run `/beams:admin` with no arguments to list the subcommands. The operations and their arguments are unchanged; only the prefix moved (`/beams:kick …` → `/beams:admin kick …`).

| Command | What it does |
|---|---|
| `/beams:admin lock <beam> [reason]` | Block all sends except from the driver. Riders can still read. |
| `/beams:admin unlock <beam>` | Lift the lock. |
| `/beams:admin kick <beam> <name-or-uuid> [reason]` | Ban + remove member record + drop a signed kick-notice for the target. |
| `/beams:admin unkick <beam> <name-or-uuid>` | Lift a ban. |
| `/beams:admin transfer-driver <beam> <name-or-uuid> [--force]` | Hand the wheel. `--force` requires the current driver's member record to be absent or >7 days stale. |
| `/beams:admin require-signatures <beam> on\|off` | Tighten the beam: turning ON rejects any unsigned message even from no-pubkey peers. Use after everyone migrates to v0.5+. |
| `/beams:admin cleanup-stale <beam>` | Remove inactive member records. Default threshold 30 days. |
| `/beams:admin gc <beam\|all>` | Delete old messages from a beam (or every beam). Default threshold 90 days. `--dry-run` supported. |

**Driver privileges are cooperative.** They depend on every session running this plugin and respecting the manifest. Anyone with raw write access to the share can bypass — treat lock/kick as protocol, not security. The real unforgeability comes from message signatures (see [SECURITY.md](../SECURITY.md)).

## Watcher (optional desktop pings)

| Command | What it does |
|---|---|
| `/beams:watch start [interval]` | Detached background daemon. Default 5s polling. **Zero tokens — it's a bash loop, not a model call.** |
| `/beams:watch start [interval] --on-message <shell-cmd>` | Same, plus: every new message fires `<shell-cmd>` once, in the background. v0.8.0+. |
| `/beams:watch stop` | Kill the daemon. |
| `/beams:watch restart [interval] [--on-message <shell-cmd>]` | Stop then start. `--on-message` is **not persisted** — omit on restart to clear it. |
| `/beams:watch status` | Running state, PID, log tail, current `--on-message` setting. |
| `/beams:watch logs [n]` | Tail the watcher log. |

Notifier auto-detected: `notify-send` → `terminal-notifier` → `osascript` → `kdialog` → log-only. Set `BEAMS_NOTIFIER_CMD=/path/to/script` to route pings anywhere (Slack, Discord, a bell).

### `--on-message` (v0.8.0+)

Run an arbitrary shell snippet whenever a new message addressed to this session arrives. Sits next to the desktop-notify path — both fire for the same set of new messages, in the same poll cycle.

> ⚠️ **Wrong tool for AI responder agents.** `--on-message` only exposes a 120-character preview via env vars. If you want an AI to *reason* about full message bodies and reply on the beam, you want **[`bin/beams-react`](CROSS-CLI.md#building-a-responder-agent)** instead — it polls, gates on `unread > 0`, pipes the full inbox into the wrapped AI via `bin/beams read --inject`, holds a single-instance lock, rate-limits, and ships with a refuse-destructive-ops directive. `--on-message` is for **notifications, webhooks, bells, log scribbling** — anything that doesn't need the message body, just the fact that a message arrived.

**Env vars set in the dispatched shell:**

| Var | Contents |
|---|---|
| `BEAMS_BEAM` | Beam name the message arrived on |
| `BEAMS_FROM` | Sender's friendly name |
| `BEAMS_PREVIEW` | First 120 chars of body, newlines collapsed to spaces |

**Always reference them quoted** (`"$BEAMS_PREVIEW"`) — bodies may contain spaces, glob chars, etc. The snippet itself is never templated with body bytes, so a malicious body cannot escape into shell; quoting just protects against benign breakage.

**Lifecycle.** The cmd is held only in the daemon's memory — not on disk. A `restart` without `--on-message` clears it. This is intentional: a same-UID peer with write access to `$BEAMS_CONFIG_DIR` should not be able to plant a dispatcher.

**Bounds.** Each fire runs in a detached background subshell, capped at 30 s by `timeout(1)` if available. Override with `BEAMS_ON_MESSAGE_TIMEOUT=<seconds>` on the daemon's launch env. Output (stdout + stderr) goes to `~/.config/beams/state/<sid>/on-message.log`, rotated at 1 MB. Non-zero exit and timeout are logged but never crash the daemon nor roll back the notify cursor.

**Concurrency cap.** A burst of N messages arriving in one poll cycle would otherwise background N concurrent subshells (fd / PID exhaustion, runaway outbound traffic if the recipe hits a webhook). Each dispatch checks `jobs -rp` against `BEAMS_ON_MESSAGE_MAX_INFLIGHT` (default 8); excess fires are logged as `on-message SKIPPED (inflight=N >= cap=N)` and dropped — the daemon stays responsive. Tune with `BEAMS_ON_MESSAGE_MAX_INFLIGHT=<positive int>` on the launch env, or write a queueing recipe (`echo "$BEAMS_PREVIEW" >> work-queue`) if you need every message at high rates.

**Sanitisation.** `BEAMS_BEAM` / `BEAMS_FROM` / `BEAMS_PREVIEW` are stripped of C0 control characters (NUL through US, plus DEL) before being placed in the env — both at the source (`lib/check.sh --notify`) and again in the daemon (defence in depth). This kills ANSI-escape terminal hijack and visual log forgery via crafted bodies.

**Limitations.** The literal substring ` --on-message ` (space-flag-space) cannot appear inside the snippet itself — the arg parser cuts on its first occurrence. Wrap your cmd in a script if you need that.

**Recipes:**

```bash
# Terminal bell — alert the human at the keyboard
/beams:watch start --on-message 'printf "\a"'

# ntfy.sh push to phone
/beams:watch start --on-message 'curl -s -d "$BEAMS_FROM: $BEAMS_PREVIEW" https://ntfy.sh/your-topic'

# Slack incoming webhook
/beams:watch start --on-message 'curl -s -X POST -H "Content-Type: application/json" -d "{\"text\":\"beams: $BEAMS_FROM on $BEAMS_BEAM — $BEAMS_PREVIEW\"}" "$SLACK_WEBHOOK_URL"'

# Local mail
/beams:watch start --on-message 'printf "%s\n" "$BEAMS_PREVIEW" | mail -s "beams: $BEAMS_FROM on $BEAMS_BEAM" you@example.com'

# Append to a worklog for later review
/beams:watch start --on-message 'printf "[%s] %s/%s: %s\n" "$(date -Iseconds)" "$BEAMS_BEAM" "$BEAMS_FROM" "$BEAMS_PREVIEW" >> ~/beams-worklog.txt'
```

**What `--on-message` does.** It runs a shell command once per new message — nothing more. As of 0.11 the SessionStart hook arms it automatically with `lib/on-message.sh`, the wake-file doorbell: each message appends one line to `$BEAMS_CONFIG_DIR/wake.log`, and the session's persistent Monitor task turns that line into a real-time wake of the idle session. Passing your own `--on-message` replaces the stock hook for the current daemon run only (the next session start re-arms the stock one — set `react.watch_on_boot: false` for full manual control). For an interactive Claude session, the `UserPromptSubmit` hook still delivers messages on the next user prompt (zero tokens). For an autonomous responder agent that needs full message context, see the prominent callout at the top of this section: use [`bin/beams-react`](CROSS-CLI.md#building-a-responder-agent).

## Maintenance

| Command | What it does |
|---|---|
| `/beams:admin test [round...]` | Run the smoke-test suite (~135s). Optionally pick rounds, e.g. `/beams:admin test 7 8`. |

## Garbage collection

| What | How |
|---|---|
| Old messages on the share | `/beams:admin gc <beam\|all> --older-than 90d` |
| Inactive member records | `/beams:admin cleanup-stale <beam>` |
| Watcher log | self-rotated to 1MB |
| Orphan session dirs (`~/.config/beams/sessions/<dead-id>/`) | `rm -rf` manually when you know they're gone |
