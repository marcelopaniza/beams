# beams channel

**Experimental, opt-in.** Real-time bridge that pushes beam messages into an
already-open Claude Code session so Claude wakes and reacts, without you
having to type anything.

## What this is

One-line architecture:

```
watcher daemon  --on-message-->  curl localhost  -->  beams-channel.mjs  -->  <channel> event  -->  Claude wakes
```

`beams-channel.mjs` is an MCP stdio server.  Claude Code spawns it as a
subprocess at startup.  When the beams watcher fires its `--on-message` hook
for a new message, the hook POSTs to the server's local HTTP listener.  The
server emits a `notifications/claude/channel` JSON-RPC notification over
stdout, which Claude Code wraps in a `<channel source="beams" ...>` tag and
delivers as a new turn.

Events only arrive while the session is **open**.  If Claude Code isn't
running, nothing queues — the watcher's curl POST just returns a connection
error (or nothing if the server isn't up), and you see the message the normal
way next time you open a session.

## Prerequisites

- **Node.js 18+** (`node --version`).  The server uses only Node built-ins; no
  `npm install` required.
- **Claude Code v2.1.80+**.  Channels landed in that release.
- **Anthropic auth** — a claude.ai account or an Anthropic Console API key.
  Channels are not available on Amazon Bedrock, Google Vertex AI, or
  Microsoft Foundry.
- **Research preview caveat** — the `--channels` protocol contract may change.
  The `notifications/claude/channel` wire format is stable for now, but treat
  this as beta infrastructure.  Pin your Claude Code version if stability
  matters.

## Setup

### 1. Register the server with Claude Code

Copy the example MCP config into your project:

```bash
cp channel/.mcp.json.example .mcp.json
```

Or, to register it user-wide (so it works from any project directory), merge
the `beams` entry into `~/.claude.json` using the **absolute** path:

```json
{
  "mcpServers": {
    "beams": {
      "command": "node",
      "args": ["/absolute/path/to/channel/beams-channel.mjs"]
    }
  }
}
```

A relative path works fine for the project-level `.mcp.json`; the absolute
path is required for `~/.claude.json` because Claude Code may launch the
server from a different working directory.

### 2. Set a shared token

The server guards its HTTP listener with a bearer token.  Set it **before**
launching `claude`, so the spawned server process and the watcher's
`--on-message` hook inherit the same value from the shell environment:

```bash
export BEAMS_CHANNEL_TOKEN=$(openssl rand -hex 16)
```

Alternatively, point `BEAMS_CHANNEL_TOKEN_FILE` at a path.  If the file is
missing the server generates a random token, writes it there at mode 0600,
and logs the path (never the value) to stderr.

If you set neither variable, the server accepts POSTs from localhost without
authentication and logs a one-time warning.  That is only acceptable for
local development where you trust every process running as your UID.

### 3. Launch Claude Code with the development flag

Community-marketplace plugins are not on Anthropic's channel allowlist.
Until the beams channel is officially listed, you must pass
`--dangerously-load-development-channels` to bypass the allowlist check for
this specific server entry:

```bash
claude --dangerously-load-development-channels server:beams
```

The `server:beams` argument names the MCP server entry as registered in your
`.mcp.json` or `~/.claude.json`.  This flag bypasses the allowlist only — it
does not disable org policy (`channelsEnabled`), and it does not affect other
`--channels` entries.  The server itself is localhost-only; no external
network exposure is involved.

### 4. Wire the watcher to the channel — automatic

You don't have to do anything here.  When a session is launched with a channel
token set (step 2), the beams **SessionStart hook starts the watcher with its
`--on-message` hook already pointed at the channel** — no manual
`/beams:watch start --on-message ...`.  The hook it installs is
`channel/on-message.sh`, which POSTs each new message to *this session's*
channel server.

It finds the right server on its own.  Each session's server binds its **own
OS-assigned port** (no more fixed 8799, so any number of sessions coexist) and
publishes that port to a per-session rendezvous file:

```
${XDG_CONFIG_HOME:-~/.config}/beams/channels/<CLAUDE_CODE_SESSION_ID>.port
```

`on-message.sh` reads that file to learn where to POST, and resolves the token
from `BEAMS_CHANNEL_TOKEN` (or `BEAMS_CHANNEL_TOKEN_FILE`).  The watcher exports
three variables per message that the hook forwards:

| Variable | Contents |
|---|---|
| `BEAMS_BEAM` | Beam name the message arrived on |
| `BEAMS_FROM` | Sender's friendly name |
| `BEAMS_PREVIEW` | First 120 chars of the message body |

**Token-less / dev setups.**  If you run the server without a token, set
`BEAMS_CHANNEL_AUTOWIRE=1` before launching `claude` — otherwise the hook can't
tell the channel is in use (a present token is its signal) and leaves the
watcher notify-only.

**Manual / advanced.**  To wire it yourself (custom watcher, fixed port), pass
the installed hook as your `--on-message`:

```
/beams:watch start --on-message 'bash /absolute/path/to/channel/on-message.sh'
```

## Security

**Localhost-only bind** — the HTTP listener binds to `127.0.0.1`, never
`0.0.0.0`.  No external network exposure, no firewall rule required.

**Token gate** — beams' threat model treats same-UID local processes as
potentially hostile (a malicious dependency running as your user can reach
localhost).  A shared token in `x-beams-token` is required by default.  The
comparison uses `crypto.timingSafeEqual` to resist timing attacks.  If no
token is configured, the server accepts localhost POSTs and warns once on
stderr.

**Content sanitization** — message bodies are stripped of C0 control
characters (0x00–0x1f), DEL (0x7f), and C1 controls (0x80–0x9f) before being
forwarded to Claude.  This guards against prompt-injection via crafted message
bodies and terminal-hijack sequences.  The meta values (`beam`, `from`) are
additionally restricted to `[A-Za-z0-9_]` only, matching the Channels spec's
identifier constraint.

**This is a prompt-injection surface** — anyone who can POST to the channel
server can put text in front of Claude.  The token guards that.  The beam
messages themselves are already Ed25519-signed and validated by beams before
the watcher ever fires `--on-message`, so the content you POST is attacker-
controlled only if the beams layer is already compromised.

## Verify it works

After launching Claude Code with the development flag, in a separate terminal.
The server's port is OS-assigned, so read it from the rendezvous file first
(one `.port` file per open session):

```bash
# Find your session's port (list the dir if you have more than one session)
PORT=$(cat "${XDG_CONFIG_HOME:-$HOME/.config}"/beams/channels/*.port | head -1)

# Health check — should print "ok"
curl -s "http://127.0.0.1:$PORT/health"

# Send a test event — Claude should wake and surface the message
curl -X POST \
  -H "x-beams-token: $BEAMS_CHANNEL_TOKEN" \
  -H "x-beams-beam: test" \
  -H "x-beams-from: smoke" \
  --data-binary "hello from the channel smoke test" \
  "http://127.0.0.1:$PORT/"
```

Watch your Claude Code terminal — it should show a `<channel source="beams"
beam="test" from="smoke">` event and Claude will surface the message.

By default the server takes an OS-assigned free port per session (published to
the rendezvous file above), so several sessions never collide.  To **pin** a
fixed port instead, set `BEAMS_CHANNEL_PORT` before launching `claude` (the
spawned server inherits it) — but then only one session can use that port:

```bash
export BEAMS_CHANNEL_PORT=9100
claude --dangerously-load-development-channels server:beams
```
