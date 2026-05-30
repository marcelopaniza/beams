# Token cost — full breakdown

The [README's "What it costs" table](../README.md#what-it-costs) is the headline ("0 when idle"). This page is the full breakdown — what each delivery path actually spends, when, and why.

## Three delivery paths

### 1. The Claude Code hook (default — runs on every prompt you submit)

- Reads `find -newer <cursor>` on each subscribed bus (microseconds on tmpfs/SSD).
- Zero new messages addressed to you → emits empty output → **0 tokens added to the prompt**.
- N new messages → a small `📬 buses: N new message(s) from <senders>` line plus the message bodies inside a `<buses-inbox>` block (~30 tokens/message).
- Caps total hook execution at the timeout (default 5s) — never blocks your prompt.

### 2. The watcher (optional — `/buses:watch start`)

- Background bash polling loop on a separate cursor. **Never invokes Claude.**
- Fires a desktop notification via `notify-send` (or your preferred notifier).
- Auto-rotates its log at 1MB.

### 3. `buses-react` (non-Claude CLIs — autonomous task handoff)

- Background bash polling loop. **Idle cost: zero model tokens** — same `find -newer cursor` mechanism as the watcher.
- On unread > 0: one `buses-wrap <your-ai-cmd>` invocation per drain. The wrapped AI sees the inbox + a directive prompt, acts on each message (safe ops only — destructive ops are refused), and can `/buses:send` a status reply back.
- For Codex / Gemini / Ollama / any AI CLI with a one-shot mode.
- Default rate limit: 60 wrapped-AI invocations per hour (sliding window). Override with `--max-fires-per-hour N` or `$BUSES_REACT_MAX_FIRES`.

## What an idle bus actually costs

Most of the time, terminals sit there waiting for you to type. They cost you **nothing**:

- No file watches (we use polling, not inotify — see [INTERNALS.md § Why polling](INTERNALS.md#why-polling-not-inotify))
- No socket connections
- No daemons (unless you explicitly started the watcher or buses-react)
- The Claude Code hook only runs *when you submit a prompt*, and it's a sub-millisecond `find` command that returns empty when there's nothing for you
- The watcher / buses-react polling loops also run `find` against the shared folder — no model calls, no network round-trips beyond what your filesystem already does

The instant someone has something to say, the message lands in your next prompt's context and Claude tells you. That's the whole pitch.
