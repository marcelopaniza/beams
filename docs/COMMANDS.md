# Commands — full reference

The [README's "Commands" table](../README.md#commands) covers the everyday subcommands. This page is the full reference: driver-only operations, the watcher daemon, maintenance, and garbage collection.

## Driver (admin) commands

Every bus has one **driver** (its creator, transferable). Everyone else is a **rider**.

| Command | What it does |
|---|---|
| `/buses:lock <bus> [reason]` | Block all sends except from the driver. Riders can still read. |
| `/buses:unlock <bus>` | Lift the lock. |
| `/buses:kick <bus> <name-or-uuid> [reason]` | Ban + remove member record + drop a signed kick-notice for the target. |
| `/buses:unkick <bus> <name-or-uuid>` | Lift a ban. |
| `/buses:transfer-driver <bus> <name-or-uuid> [--force]` | Hand the wheel. `--force` requires the current driver's member record to be absent or >7 days stale. |
| `/buses:require-signatures <bus> on\|off` | Tighten the bus: turning ON rejects any unsigned message even from no-pubkey peers. Use after everyone migrates to v0.5+. |
| `/buses:cleanup-stale <bus>` | Remove inactive member records. Default threshold 30 days. |
| `/buses:gc <bus\|all>` | Delete old messages from a bus (or every bus). Default threshold 90 days. `--dry-run` supported. |

**Driver privileges are cooperative.** They depend on every session running this plugin and respecting the manifest. Anyone with raw write access to the share can bypass — treat lock/kick as protocol, not security. The real unforgeability comes from message signatures (see [SECURITY.md](../SECURITY.md)).

## Watcher (optional desktop pings)

| Command | What it does |
|---|---|
| `/buses:watch start [interval]` | Detached background daemon. Default 5s polling. **Zero tokens — it's a bash loop, not a model call.** |
| `/buses:watch start [interval] --on-message <shell-cmd>` | Same, plus: every new message fires `<shell-cmd>` once, in the background. v0.8.0+. |
| `/buses:watch stop` | Kill the daemon. |
| `/buses:watch restart [interval] [--on-message <shell-cmd>]` | Stop then start. `--on-message` is **not persisted** — omit on restart to clear it. |
| `/buses:watch status` | Running state, PID, log tail, current `--on-message` setting. |
| `/buses:watch logs [n]` | Tail the watcher log. |

Notifier auto-detected: `notify-send` → `terminal-notifier` → `osascript` → `kdialog` → log-only. Set `BUSES_NOTIFIER_CMD=/path/to/script` to route pings anywhere (Slack, Discord, a bell).

### `--on-message` (v0.8.0+)

Run an arbitrary shell snippet whenever a new message addressed to this session arrives. Sits next to the desktop-notify path — both fire for the same set of new messages, in the same poll cycle.

> ⚠️ **Wrong tool for AI responder agents.** `--on-message` only exposes a 120-character preview via env vars. If you want an AI to *reason* about full message bodies and reply on the bus, you want **[`bin/buses-react`](CROSS-CLI.md#building-a-responder-agent)** instead — it polls, gates on `unread > 0`, pipes the full inbox into the wrapped AI via `bin/buses read --inject`, holds a single-instance lock, rate-limits, and ships with a refuse-destructive-ops directive. `--on-message` is for **notifications, webhooks, bells, log scribbling** — anything that doesn't need the message body, just the fact that a message arrived.

**Env vars set in the dispatched shell:**

| Var | Contents |
|---|---|
| `BUSES_BUS` | Bus name the message arrived on |
| `BUSES_FROM` | Sender's friendly name |
| `BUSES_PREVIEW` | First 120 chars of body, newlines collapsed to spaces |

**Always reference them quoted** (`"$BUSES_PREVIEW"`) — bodies may contain spaces, glob chars, etc. The snippet itself is never templated with body bytes, so a malicious body cannot escape into shell; quoting just protects against benign breakage.

**Lifecycle.** The cmd is held only in the daemon's memory — not on disk. A `restart` without `--on-message` clears it. This is intentional: a same-UID peer with write access to `$BUSES_CONFIG_DIR` should not be able to plant a dispatcher.

**Bounds.** Each fire runs in a detached background subshell, capped at 30 s by `timeout(1)` if available. Override with `BUSES_ON_MESSAGE_TIMEOUT=<seconds>` on the daemon's launch env. Output (stdout + stderr) goes to `~/.config/buses/state/<sid>/on-message.log`, rotated at 1 MB. Non-zero exit and timeout are logged but never crash the daemon nor roll back the notify cursor.

**Concurrency cap.** A burst of N messages arriving in one poll cycle would otherwise background N concurrent subshells (fd / PID exhaustion, runaway outbound traffic if the recipe hits a webhook). Each dispatch checks `jobs -rp` against `BUSES_ON_MESSAGE_MAX_INFLIGHT` (default 8); excess fires are logged as `on-message SKIPPED (inflight=N >= cap=N)` and dropped — the daemon stays responsive. Tune with `BUSES_ON_MESSAGE_MAX_INFLIGHT=<positive int>` on the launch env, or write a queueing recipe (`echo "$BUSES_PREVIEW" >> work-queue`) if you need every message at high rates.

**Sanitisation.** `BUSES_BUS` / `BUSES_FROM` / `BUSES_PREVIEW` are stripped of C0 control characters (NUL through US, plus DEL) before being placed in the env — both at the source (`lib/check.sh --notify`) and again in the daemon (defence in depth). This kills ANSI-escape terminal hijack and visual log forgery via crafted bodies.

**Limitations.** The literal substring ` --on-message ` (space-flag-space) cannot appear inside the snippet itself — the arg parser cuts on its first occurrence. Wrap your cmd in a script if you need that.

**Recipes:**

```bash
# Terminal bell — alert the human at the keyboard
/buses:watch start --on-message 'printf "\a"'

# ntfy.sh push to phone
/buses:watch start --on-message 'curl -s -d "$BUSES_FROM: $BUSES_PREVIEW" https://ntfy.sh/your-topic'

# Slack incoming webhook
/buses:watch start --on-message 'curl -s -X POST -H "Content-Type: application/json" -d "{\"text\":\"buses: $BUSES_FROM on $BUSES_BUS — $BUSES_PREVIEW\"}" "$SLACK_WEBHOOK_URL"'

# Local mail
/buses:watch start --on-message 'printf "%s\n" "$BUSES_PREVIEW" | mail -s "buses: $BUSES_FROM on $BUSES_BUS" you@example.com'

# Append to a worklog for later review
/buses:watch start --on-message 'printf "[%s] %s/%s: %s\n" "$(date -Iseconds)" "$BUSES_BUS" "$BUSES_FROM" "$BUSES_PREVIEW" >> ~/buses-worklog.txt'
```

**What `--on-message` is NOT.** It cannot wake an idle peer Claude Code session — Claude Code has no external-wake primitive today. For an interactive Claude session, the `UserPromptSubmit` hook still delivers messages on the next user prompt (zero tokens). For an autonomous responder agent that needs full message context, see the prominent callout at the top of this section: use [`bin/buses-react`](CROSS-CLI.md#building-a-responder-agent).

## Maintenance

| Command | What it does |
|---|---|
| `/buses:test [round...]` | Run the smoke-test suite (~135s). Optionally pick rounds, e.g. `/buses:test 7 8`. |

## Garbage collection

| What | How |
|---|---|
| Old messages on the share | `/buses:gc <bus\|all> --older-than 90d` |
| Inactive member records | `/buses:cleanup-stale <bus>` |
| Watcher log | self-rotated to 1MB |
| Orphan session dirs (`~/.config/buses/sessions/<dead-id>/`) | `rm -rf` manually when you know they're gone |
