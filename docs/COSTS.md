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

### 4. Proactive hooks (v0.9.0 — boot check, opt-in sustain, opt-in real-time wake)

- **SessionStart boot check (default — runs once when a session opens or resumes).** Same `find -newer cursor` as path 1; surfaces any already-waiting messages at boot instead of waiting for your first prompt. **Cost-neutral:** it advances the same cursor, so a waiting message is delivered exactly once — at boot *instead of* on the first prompt, not in addition. 0 tokens when nothing is waiting; a silent no-op for a session that never ran `/beams:start`.
- **Stop hook (opt-in — `react.on_stop`, default off).** Off by default: a few ms of bash and **0 tokens** per turn-end (the no-op path doesn't even source `common.sh`). Turned on, if new messages arrived *while the session was working*, it hands them to Claude as the next turn's instruction — **one extra turn**, and only when a message actually arrived mid-turn. Floods batch into a single turn; `stop_hook_active` + Claude Code's 8-block cap prevent loops.
- **Channels doorbell (opt-in — `channel/`, off unless you register it).** A localhost Node bridge the watcher can `curl` to wake an *idle* Claude session in real time. **0 model tokens** to run (it's a one-way notification); when it fires, the woken session spends **one turn** reading + surfacing the message. Nothing in the bash core imports it.

## What an idle beam actually costs

Most of the time, terminals sit there waiting for you to type. They cost you **nothing**:

- No file watches (we use polling, not inotify — see [INTERNALS.md § Why polling](INTERNALS.md#why-polling-not-inotify))
- No socket connections
- No daemons (unless you explicitly started the watcher or beams-react)
- The Claude Code hook only runs *when you submit a prompt*, and it's a sub-millisecond `find` command that returns empty when there's nothing for you
- The watcher / beams-react polling loops also run `find` against the shared folder — no model calls, no network round-trips beyond what your filesystem already does

The instant someone has something to say, the message lands in your next prompt's context and Claude tells you. That's the whole pitch.
