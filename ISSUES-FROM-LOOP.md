# Beams onboarding friction — filed from the `loop` rider

> Filed 2026-05-29 23:41Z by the Claude session working in `/mnt/data/loop`
> (`CLAUDE_CODE_SESSION_ID=bb512e2f-b18a-47c2-90e1-3cc64903e59e`).
> Plugin root in use: `/mnt/data/beams` (dev checkout, the one the slash
> commands resolve `${CLAUDE_PLUGIN_ROOT}` to — confirmed from the error path
> `/mnt/data/beams//lib/init.sh`).
>
> Both symptoms below are **working-as-coded**, not crashes. They are UX
> friction that bites every brand-new terminal session. Leaving this for
> whoever maintains the beams plugin to triage/fix later. Nothing here is
> blocking me — I worked around it by calling the lib scripts directly.

---

## Symptom 1 — `/beams:join all` on a fresh session fails with "not initialised"

```
$ /beams:join all
beams: not initialised — run /beams:init <shared-path> first
```

**Root cause.** `join.sh:10` calls `beams::config_require`, which fails because
this terminal session has no config file yet. The identity model is
per-terminal: the config dir is derived in `common.sh:_resolve_config_dir`
from `CLAUDE_CODE_SESSION_ID`, resolving to:

```
$HOME/.config/beams/sessions/<CLAUDE_CODE_SESSION_ID>/config.json
```

For this brand-new session that path
(`…/sessions/bb512e2f-b18a-47c2-90e1-3cc64903e59e/config.json`) didn't exist,
so `join` hard-failed. Every fresh Claude Code terminal hits this — the
identity does not carry over from prior sessions (by design), so the very
first command in any new terminal must be `init`, not `join`.

This is *correct* behaviour, but the friction is real: a returning user who
"already set up beams on this machine last week" reasonably types
`/beams:join all` first and gets stopped.

## Symptom 2 — bare `/beams:init` (no argument) fails with a usage error

```
$ /beams:init
beams: usage: init.sh <shared-path> [--force] [--profile <name>]
```

**Root cause.** The `init.md` command pipes `$ARGUMENTS` into `init.sh`. With
no argument it passes an empty string, so `init.sh:16` sets `shared=""` and
`init.sh:38` (`[ -n "$shared" ] || beams::die "usage: …"`) aborts. There is no
default or remembered shared-path, even though on this machine the shared
folder is always `/mnt/data/beams-share` and several sibling session configs
already record it.

So the user is caught in a chicken-and-egg: `join` says "run init first", but
bare `init` says "give me a path" — and nothing tells them the path is
`/mnt/data/beams-share`.

---

## Repro (clean)

1. Open a new Claude Code terminal (new `CLAUDE_CODE_SESSION_ID`).
2. `/beams:join all` → "not initialised — run /beams:init <shared-path> first".
3. `/beams:init` (no args) → "usage: init.sh <shared-path> …".
4. Stuck until you happen to know to type `/beams:init /mnt/data/beams-share`.

## Suggested fixes (pick any; ordered cheapest → nicest)

- [ ] **Cheapest — better error text.** When `join`/`send`/`read` hit
      `config_require` with no config, print the exact ready-to-paste command,
      including a discovered shared path. Discover it by scanning existing
      `$HOME/.config/beams/sessions/*/config.json` for the most-recently-used
      `.shared_path`, or fall back to the sole `*/beams/` folder if exactly one
      exists. e.g.:
      `no config for this terminal yet — run:  /beams:init /mnt/data/beams-share`
- [ ] **Medium — default the shared path on bare `init`.** If `/beams:init` is
      called with no argument, reuse the last-used `.shared_path` from any
      sibling session config (or the sole existing shared folder). Only fall
      back to the usage error when nothing can be discovered. Keep `--force`
      semantics intact.
- [ ] **Nicest — auto-init on first `join`.** If `join` is called with no
      config but a shared path is unambiguously discoverable, silently `init`
      against it (printing a one-line "auto-initialised against <path>") and
      proceed. Preserve the per-terminal identity model — just remove the
      manual `init` step when the path is obvious.

## Notes / non-issues

- The per-terminal identity model itself is working as designed and documented
  — this is purely about the first-run ergonomics.
- Workaround used by `loop` in the meantime: call the lib scripts directly,
  `"/mnt/data/beams/lib/init.sh" /mnt/data/beams-share` then
  `"/mnt/data/beams/lib/name.sh" loop` then `"/mnt/data/beams/lib/join.sh" all`.
- The `loop` project memory `reference_beams_plugin` still points the plugin
  root at the cache path
  `/home/paniza/.claude/plugins/cache/beams/beams/0.2.0/`, but the live slash
  commands in this session resolve `${CLAUDE_PLUGIN_ROOT}` to `/mnt/data/beams`.
  If both installs are meant to coexist, a line in the README about which one
  the marketplace install vs. the dev checkout uses would save confusion.
