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
│   ├── init.md   name.md    create.md    join.md    leave.md
│   ├── send.md   read.md    status.md    list.md
│   ├── members.md  riders.md   start.md   test.md
│   ├── lock.md   unlock.md   kick.md     unkick.md
│   ├── transfer-driver.md  cleanup-stale.md  gc.md
│   ├── require-signatures.md
│   └── watch.md
├── hooks/
│   ├── hooks.json                       #   UserPromptSubmit + SessionStart + Stop
│   ├── check-messages.sh                #   UserPromptSubmit: pull unread on prompt
│   ├── check-on-start.sh                #   SessionStart: surface unread at boot (+ opt-in daemon)
│   └── respond-on-stop.sh               #   Stop: opt-in active-session sustain
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
│   └── watcher_daemon.sh              #   detached polling daemon
├── channel/                           # opt-in real-time MCP "doorbell" (experimental)
│   ├── beams-channel.mjs              #   zero-dep Node MCP stdio channel server
│   ├── .mcp.json.example              #   registration example
│   ├── README.md                      #   setup + security
│   └── smoke.sh                       #   self-contained handshake/POST smoke
├── presets/                           # /beams:admin init --profile <name> overlays
│   └── hermes.json   responder.json
├── tests/                             # smoke tests, 18 rounds
│   ├── round-{1..18}.sh
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
    └── lease.json                 # { bound_session, last_seen } — the in-use lease
```

- **Resolution** (`beams::_resolve_config_dir`): explicit `$BEAMS_CONFIG_DIR` wins; otherwise, if `sessions/<id>/bound` exists, resolve to that named identity; else the ephemeral `sessions/<id>/` (empty → "not initialised" until the SessionStart hook prompts for a name).
- **Binding** (`/beams:name <name>`): rebinds to an existing identity (restoring its UUID + subscriptions), migrates a scratch config into one, or creates a fresh one (inheriting the project's shared folder). A new session id after a restart re-binds to the same name and is the same rider.
- **In-use lease**: `lease.json` records which session holds a name and when it was last seen (refreshed each prompt by `check.sh`). Within `BEAMS_INUSE_STALE_SECONDS` (default 900) a name held by *another* session blocks a bind unless `--force`; past that the lease is treated as released. `/beams:status` surfaces it as **in use: yes/no**.

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
- **Single-instance daemons** (watcher, `beams-react`) use mkdir-based lockdirs. `mkdir` is atomic on POSIX filesystems, so the lock-acquire is race-free without needing `flock` (which isn't portable across macOS/Linux/BSD).

## Why polling, not inotify?

inotify/fswatch only see writes from the local kernel. On NFS / Syncthing / Dropbox / iCloud they miss writes from other machines — the file appears on disk via the sync daemon, not via a local `write(2)` syscall, so no inotify event fires.

Polling works everywhere; cost is one `find -newer cursor` per interval per subscribed beam — negligible. On tmpfs/SSD the `find` returns in microseconds, and the `-newer` predicate uses the kernel's stat cache, so even on a folder with thousands of message files, the check is sub-millisecond.

The trade-off is latency: with the default 5s watcher interval, you might wait up to 5s for a desktop notification. The Claude Code hook has no latency because it fires on every prompt submission — messages reach the model the instant you type into a window.
