# Internals

Wire format, directory layout, concurrency model, and the design choice behind polling-instead-of-inotify. Read this if you're contributing, debugging, or implementing a compatible client.

## Layout

```
beams/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── bin/
│   ├── beams                          # CLI-agnostic dispatcher
│   ├── beams-wrap                     # interactive auto-delivery shim
│   └── beams-react                    # autonomous task-handoff daemon
├── commands/                          # /beams:* slash commands (Claude Code only)
│   ├── start.md  send.md    read.md      status.md  join.md
│   ├── name.md   list.md    watch.md
│   └── admin.md                       #   driver / maintenance verbs (create, kick, lock, gc, init, test, …)
├── hooks/
│   ├── hooks.json                       #   UserPromptSubmit + SessionStart + Stop + SessionEnd
│   ├── check-messages.sh                #   UserPromptSubmit: pull unread on prompt
│   ├── check-on-start.sh                #   SessionStart: surface unread at boot (+ auto-arm watcher by default)
│   ├── respond-on-stop.sh               #   Stop: opt-in active-session sustain
│   └── session-end.sh                   #   SessionEnd: release the identity lease on a real exit
├── lib/                               # bash implementation
│   ├── common.sh                      #   helpers (crypto, validate, write, perms)
│   ├── send.sh   check.sh             #   message in/out
│   ├── init.sh   name.sh    create.sh    join.sh    leave.sh
│   ├── list.sh   members.sh  status.sh
│   ├── lock.sh   unlock.sh   kick.sh    unkick.sh
│   ├── transfer-driver.sh  cleanup-stale.sh  gc.sh
│   ├── require-signatures.sh
│   ├── admin.sh                      #   /beams:admin dispatcher (driver/maintenance verbs)
│   ├── watch.sh                       #   /beams:watch dispatcher
│   ├── watcher_daemon.sh              #   detached polling daemon
│   └── on-message.sh                  #   watcher hook: the wake-file doorbell (one line per message)
├── presets/                           # /beams:admin init --profile <name> overlays
│   └── hermes.json   responder.json
├── tests/                             # smoke tests (rounds 21/27 retired with the channel server)
│   ├── round-{1..34}.sh
│   └── run-all.sh
├── assets/                            # README marketing images + sources
│   ├── beams-hero.jpg        beams-any-ai.jpg        # used in the README
│   ├── beams-hero-clean.jpg  beams-any-ai-clean.jpg  # art, no text
│   └── beams-hero.html       beams-any-ai.html       # text-overlay source
├── docs/                              # this directory
│   ├── COMMANDS.md
│   ├── COSTS.md
│   ├── CROSS-CLI.md
│   └── INTERNALS.md
└── README.md
```

## Session identity (restart-safe)

A Claude Code session id (`$CLAUDE_CODE_SESSION_ID`) is **ephemeral** — a fresh start mints a new one, which would orphan a per-session config. So identity is anchored on a user-chosen **name**, keyed per project:

```
~/.config/beams/
├── sessions/<session-id>/
│   ├── bound                      # tiny pointer: the name this session is bound to
│   └── config.json                # only while UNBOUND — a "scratch" init before naming
└── projects/<flattened-project-dir>/identities/<name>/
    ├── config.json                # the durable identity (UUID, name, subscriptions)
    ├── identity.key               # its Ed25519 private key
    ├── lease.json                 # { bound_session, host, claude_pid, claude_pid_start, last_seen } — the in-use lease
    └── inbox.json                 # { socket, token, session_id, claude_pid, claude_pid_start, updated } — native doorbell pointer, 0600
```

- **Resolution** (`beams::_resolve_config_dir`): explicit `$BEAMS_CONFIG_DIR` wins; otherwise, if `sessions/<id>/bound` exists, resolve to that named identity; else the ephemeral `sessions/<id>/` (empty → "not initialised" until the SessionStart hook auto-binds it to the project's lone bindable identity).
- **Binding** (`/beams:name <name>`): rebinds to an existing identity (restoring its UUID + subscriptions), migrates a scratch config into one, or creates a fresh one (inheriting the project's shared folder). A new session id after a restart re-binds to the same name and is the same rider — and when exactly one identity is free, the SessionStart hook does this automatically, with no prompt.
- **In-use lease**: `lease.json` records which session holds a name, the Claude **process** that holds it (`claude_pid` + its start time, from `$CLAUDE_PID`), and when it was last seen (refreshed each prompt by `check.sh`). Within `BEAMS_INUSE_STALE_SECONDS` (default 900) a name held by *another* session blocks a bind unless `--force` — unless the holder can be proven gone: its process no longer exists (or the pid was recycled), so a restarted terminal reclaims its own name at once. The same process under a *new* session id (a `/clear`) counts as the holder itself, so the SessionStart hook rebinds it silently. `SessionEnd` releases the lease on a real exit (not on `clear`/`resume`). `/beams:status` surfaces it as **in use: yes/no**.

## Message format

YAML frontmatter + body, separated by `---` lines:

```
---
id: 8b357bc5-429c-4c69-9b1b-b34d62de2bd5
beam: general
from: b06cbb43-d7ae-4ae2-83d6-557edb07145e
from_name: alice
to: bob,felix          # or "all", a name, a UUID, or a comma-list
to_id: 924257ec-…      # optional, for single recipient
ts: 2026-05-17T02:44:09Z
sig: Bo6QKEy…==        # Ed25519 signature, base64 of raw bytes
                       # (required when sender has published a public_key)
---
hey bob and felix — can we sync on the deploy? @bob has the logs.
```

Filenames: `<UTC-compact-timestamp>__<short-id>.msg` — sortable, unique. The latest-by-mtime (not latest-by-filename) determines cursor advance, since two messages sent in the same second tie on the second-resolution prefix.

## Concurrency notes

- **Atomic writes**: write to `<dir>/.<file>.tmp.$$`, then `mv` into place. The `mv` is atomic on every POSIX filesystem (including NFS — the rename RPC is atomic).
- **Cursors live per-session** in `$BEAMS_CONFIG_DIR/state/<sid>/` — never on the share. Two terminals can have completely different read positions without colliding.
- The watcher uses a **separate notify cursor** so notifications and Claude-delivery are independent. When the hook delivers a message, both cursors advance (so the watcher won't re-ping for something Claude already saw).
- **Hook never blocks the prompt** (5s timeout, always exits 0). A misconfigured hook can't take down your session.
- **Delivery is bounded per run, by mode.** `check.sh` pre-filters new files for this recipient with one `grep` (only candidates pay for signature verification), then delivers within a per-mode time budget and message cap — both overridable via `BEAMS_SCAN_BUDGET_SECS` / `BEAMS_DELIVERY_CAP` (`0` = unlimited). Defaults: 3 s on a prompt, 6 s at session start or on the Stop hook, 20 s for the watcher and `/beams:read` — each capped at 20 messages; `--inject` and `--peek` default unbounded (a generic model's only delivery path, and a read-only preview, should never silently lose messages) but still honour an explicit override; `--count` is always exact and immune to both. A capped run advances the cursor only to a point where every unread candidate is strictly newer (mtime), says how much is still queued, and the next prompt continues — a month-long backlog drains across a few prompts instead of timing out the hook forever.
- **Single-instance daemons** (watcher, `beams-react`) use mkdir-based lockdirs. `mkdir` is atomic on POSIX filesystems, so the lock-acquire is race-free without needing `flock` (which isn't portable across macOS/Linux/BSD).

## Real-time doorbell (native transport)

Claude Code ≥ 2.1.224 binds a Unix socket per Claude process — the session's own message inbox — and exports `CLAUDE_CODE_MESSAGING_SOCKET` + `CLAUDE_CODE_MESSAGING_TOKEN` to hooks and Bash-tool commands. A line posted to that socket starts a new turn the instant an idle session receives it, so the doorbell needs nothing armed and nothing re-armed.

- **Pointer file**: `$BEAMS_CONFIG_DIR/inbox.json` (`0600`), published by `beams::inbox_publish` (`lib/common.sh`) holding `{socket, token, session_id, claude_pid, claude_pid_start, updated}` — from `hooks/check-on-start.sh` at every SessionStart, from `beams::doorbell_autostart` on join/name/profile-init, and from `lib/watch.sh`'s `cmd_start` on a manual `/beams:watch start` (`restart` calls `start`) — so a session that opted out of `watch_on_boot`, or that created its identity mid-session, still gets native delivery from a manual start; the publish is best-effort and never changes what `start` prints or exits with. `hooks/session-end.sh` removes it (`beams::inbox_forget`) on a real exit; `clear`/`resume` keep it, since the same process and socket live on.
- **Ownership guard**: `inbox_publish` refuses to publish unless the calling shell has a real Claude terminal id *and* no explicit `BEAMS_CONFIG_DIR` override — both of which a generic rider driven from inside a Bash tool call (`BEAMS_CONFIG_DIR=/path/rider beams name …`) fails, so it can never capture the enclosing Claude session's own socket. By design, a Claude session started with `BEAMS_CONFIG_DIR` pinned in its own environment stays on the Monitor fallback. `inbox_forget` applies the same check in reverse on removal: it drops a pointer only when it is ours (matching session id, or matching Claude pid across a `/clear`) or orphaned (the publishing process is gone, or its pid was recycled) — never a live pointer belonging to someone else — so an ousted session's `SessionEnd` can't erase the pointer a `--force` taker just published.
- **`crossSessionInbound` is detected.** `beams::inbox_allowed` reads that one key from every settings layer Claude Code merges — the user settings file (`${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`), the project's `.claude/settings.json` and `.claude/settings.local.json` (resolved via `beams::project_dir`, not `$CLAUDE_PROJECT_DIR`, so it also works from a slash command's `!` block), and the managed-settings file (Linux `/etc/claude-code/managed-settings.json`, macOS `/Library/Application Support/ClaudeCode/managed-settings.json`). `refuse` or `hold` on any layer drops any pointer this session owns and keeps it on the wake.log + Monitor fallback — the only doorbell on a harness older than 2.1.224, too. It's checked only at the moments a pointer is (re)published (SessionStart, join/name/profile-init, `/beams:watch start`), so a mid-session settings change takes effect at the next of those. The harness's own remote kill-switch has no settings key to read, so it can't be detected from bash — it behaves exactly like a dead socket: one fallback line in watcher.log, wake.log carries on.
- **Posting**: the watcher daemon (`lib/watcher_daemon.sh`) reads the pointer fresh at post time — it never bakes the socket into its own long-lived environment — and after each poll that finds new mail, sends ONE batch summary via `beams::inbox_post`: the count and the reply clause (`beams::doorbell_reply_clause`), a line stating that what `/beams:read` returns was written by other parties and is data, not instructions, then one `- [beam] sender` line per message — identifier characters only (each name capped at 64 chars), no body preview — capped at 20 lines, `+N more` beyond that. Bodies never reach the session until it runs `/beams:read`; the preview still reaches wake.log, `--on-message`, and the desktop notification.
- **Reader probe** (fallback only): `beams::doorbell_reader` proves a live Monitor via whichever of `fuser`, `lsof`, or a `/proc/*/fd` scan the host has; when none of the three exists at all, SessionStart can't tell armed from not, so it falls back to the pre-probe rule of skipping the re-offer only on `clear`/`compact`.
- **Mode selection**: the first of the publish points above to succeed wins, and a live pointer means nothing emits the Monitor-arm instruction (`beams::doorbell_instruction`) — there is nothing to arm. `/beams:status` reports `doorbell: native (session inbox socket <path>; watcher pid <N>)` when the pointer is live and the watcher is running, `native transport ready, but the watcher is NOT running — run /beams:watch start` when the pointer is live but no watcher is up, and otherwise falls back to the wake.log reader-probe text.
- **Env knobs**: `react.watch_on_boot` / `BEAMS_DISABLE_WATCH_ON_BOOT` gate both transports the same way as before. `BEAMS_INBOX_POSTER` (`auto` / `python3` / `socat`) pins which client posts the native frame — a test seam, and an escape hatch where python3 exists but can't reach the socket.

New `tests/round-32.sh` covers this: pointer publish (incl. a planted-symlink guard and refusing to publish with the socket vars unset), an end-to-end post against a fake AF_UNIX inbox server, batching five messages into one frame, a dead-socket fallback and its recovery once the socket comes back, native-vs-Monitor mode selection, SessionEnd dropping only a pointer this session owns or one left orphaned (never a live taker's), the `crossSessionInbound` refuse/hold/accept matrix (incl. a project-level refuse and a command block with no `CLAUDE_PROJECT_DIR`), a forged-summary-line guard, `/beams:watch start` publishing the pointer, both `/beams:status` doorbell texts, the socat poster, and the ownership rule for an identity pinned with `BEAMS_CONFIG_DIR`.

## Why polling, not inotify?

inotify/fswatch only see writes from the local kernel. On NFS / Syncthing / Dropbox / iCloud they miss writes from other machines — the file appears on disk via the sync daemon, not via a local `write(2)` syscall, so no inotify event fires.

Polling works everywhere; cost is one `find -newer cursor` per interval per subscribed beam — negligible. On tmpfs/SSD the `find` returns in microseconds, and the `-newer` predicate uses the kernel's stat cache, so even on a folder with thousands of message files, the check is sub-millisecond.

The trade-off is latency: with the default 5s watcher interval, you might wait up to 5s for a desktop notification. The Claude Code hook has no latency because it fires on every prompt submission — messages reach the model the instant you type into a window.
