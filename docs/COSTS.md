# Token cost — full breakdown

The [README's "What it costs" table](../README.md#what-it-costs) is the headline ("0 when idle"). This page is the full breakdown — what each delivery path actually spends, when, and why.

## Three delivery paths

### 1. The Claude Code hook (default — runs on every prompt you submit)

- Reads `find -newer <cursor>` on each subscribed beam (microseconds on tmpfs/SSD).
- Zero new messages addressed to you → emits empty output → **0 tokens added to the prompt**.
- N new messages → a small `📬 beams: N new message(s) from <senders>` line plus the message bodies inside a `<beams-inbox>` block (~30 tokens/message).
- Caps total hook execution at the timeout (default 5s) — never blocks your prompt.

### 2. The watcher (optional — `/beams:watch start`)

- Background bash polling loop on a separate cursor. **Never invokes Claude.**
- Fires a desktop notification via `notify-send` (or your preferred notifier).
- Auto-rotates its log at 1MB.

### 3. `beams-react` (non-Claude CLIs — autonomous task handoff)

- Background bash polling loop. **Idle cost: zero model tokens** — same `find -newer cursor` mechanism as the watcher.
- On unread > 0: one `beams-wrap <your-ai-cmd>` invocation per drain. The wrapped AI sees the inbox + a directive prompt, acts on each message (safe ops only — destructive ops are refused), and can `/beams:send` a status reply back.
- For Codex / Gemini / Ollama / any AI CLI with a one-shot mode.
- Default rate limit: 60 wrapped-AI invocations per hour (sliding window). Override with `--max-fires-per-hour N` or `$BEAMS_REACT_MAX_FIRES`.

### 4. Proactive hooks (boot check, opt-in sustain, default-on real-time wake)

- **SessionStart boot check (default — runs once when a session opens or resumes).** Same `find -newer cursor` as path 1; surfaces any already-waiting messages at boot instead of waiting for your first prompt. **Cost-neutral:** it advances the same cursor, so a waiting message is delivered exactly once — at boot *instead of* on the first prompt, not in addition. 0 tokens when nothing is waiting; a silent no-op for a session that never ran `/beams:start`. As of v0.10.x it also **auto-arms the watcher daemon by default** (desktop pings + the wake-file feed for the doorbell below): still **0 model tokens** (pure 5 s polling), the only cost is one background process per session; opt out with `react.watch_on_boot: false` or `BEAMS_DISABLE_WATCH_ON_BOOT=1`.
- **Stop hook (opt-in — `react.on_stop`, default off).** Off by default: a few ms of bash and **0 tokens** per turn-end (the no-op path doesn't even source `common.sh`). Turned on, if new messages arrived *while the session was working*, it hands them to Claude as the next turn's instruction — **one extra turn**, and only when a message actually arrived mid-turn. Floods batch into a single turn; `stop_hook_active` + Claude Code's 8-block cap prevent loops.
- **Wake-file doorbell (default-on, v0.11 — replaces the channel server).** The watcher appends one line per new message to a local wake file (`$BEAMS_CONFIG_DIR/wake.log`); the session's persistent `Monitor` task (armed once — at the session's first prompt, or on the spot when it joins/binds mid-session) turns each line into a wake of the *idle* session. **0 model tokens while idle** — the waiting is a detached `tail`, not a model loop. A delivered message costs **one turn**: the same turn that reads and surfaces it (and replies, when the session's role calls for that). Off whenever the watcher is off.

## What an idle beam actually costs

Most of the time, terminals sit there waiting for you to type. They cost you **nothing**:

- No file watches (we use polling, not inotify — see [INTERNALS.md § Why polling](INTERNALS.md#why-polling-not-inotify))
- No socket connections
- No daemons (unless you explicitly started the watcher or beams-react)
- The Claude Code hook only runs *when you submit a prompt*, and it's a sub-millisecond `find` command that returns empty when there's nothing for you
- The watcher / beams-react polling loops also run `find` against the shared folder — no model calls, no network round-trips beyond what your filesystem already does

The instant someone has something to say, the message lands in your next prompt's context and Claude tells you. That's the whole pitch.
