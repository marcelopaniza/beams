---
description: "First-time setup wizard: ask the user the right questions and walk them through joining a beam."
argument-hint: "(no arguments — interactive)"
---

# /beams:start — guided setup

Walk the user through first-time `beams` setup. Stay conversational — ask only what you need, act on each answer with the matching slash command, and don't dump this whole wizard at them. Most users are on one machine and should be done in a question or two.

---

## Step 0 — Check state (silent, no output to the user)

```bash
test -f "${BEAMS_CONFIG_DIR:-${HOME}/.config/beams/sessions/${CLAUDE_CODE_SESSION_ID}}/config.json" && echo INIT || echo NEW
```

- `INIT` → tell them "this terminal is already set up", run `/beams:status`, and ask whether they want to (a) join another beam, (b) start over (re-init), or (c) just see status and stop. Never re-init silently.
- `NEW` → Step 1.

---

## Step 1 — Offer the fast path first

Most setups are one machine running several terminals off a shared local folder. Offer that before asking anything else:

> Want me to set this up with defaults — local folder `~/beams-share`, joined to the `all` beam? I just need a name for this terminal. (Say so instead if you're **joining** a setup another machine already has, or need **multiple machines** to share one beam.)

- **They accept** → ask only for the name, then run:
  ```bash
  mkdir -p ~/beams-share
  ```
  ```
  /beams:admin init ~/beams-share
  /beams:name <their-name>
  /beams:join all
  ```
  Skip to Step 4. That's the whole setup in one question.
- **They want a different local path** → same three commands, swap the path (`mkdir -p` it first).
- **They're joining an existing setup, or need multiple machines** → Step 2.

---

## Step 2 — Shared folder (only if they skipped the fast path)

A beam is just a folder every participant can see. There are two cases:

**Creating, across machines.** The folder's *contents* must appear on every machine. Pick a transport:

- **Cloud sync** (Dropbox / iCloud Drive / Syncthing / OneDrive) — easiest if you already run one; use a subfolder inside the sync root. Recommend this if they have no preference.
- **NFS** — fast, Linux-to-Linux, needs root here. After they pick a path, give them the one-time export:
  ```bash
  echo "<path> <client-host>(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
  sudo exportfs -ra && sudo systemctl restart nfs-kernel-server
  ```
  `<client-host>` is the joining machine's hostname or IP — don't leave it as `*`.

**Joining an existing setup.** Ask for the path and how it reaches this machine (NFS / Dropbox / Syncthing). If they're unsure of the path, have them copy `shared_path` from `/beams:status` on the first machine. Then confirm it's actually mounted here before going further:

```bash
ls -la "<path>/beams" 2>&1
```

If that errors or is empty, **stop and mount/sync first**:

- NFS: `sudo mkdir -p "<path>" && sudo mount -t nfs <first-host>:<original-path> "<path>"`
- Cloud sync: confirm the client is running and the folder has appeared.

Don't continue until `ls` shows the `beams/` subfolder.

---

## Step 3 — Name this terminal and join a beam

Point this terminal at the folder and name it:

```
/beams:admin init <path-from-step-2>
```

> What should this terminal be called? Others use it to address you — e.g. `atlas-main`, `loop`, `felix-deploy`. Each terminal gets its own name, even when several share one folder. **The name also survives a Claude restart** — beams keys the identity on it (per project), so a restarted session re-binds by running `/beams:name <same-name>` again, or by answering the prompt beams shows at the next session start.

```
/beams:name <their-name>
```

Then the beam. If `/beams:list` shows existing beams, ask which to join; otherwise default to `all`:

```
/beams:join <beam-name>
```

It auto-creates if missing (the creator becomes driver). Messages addressed to this terminal — or to `all` — then arrive on the next prompt, no polling.

---

## Step 4 — Notifications, then done

> Want desktop notifications for new messages? It's a background daemon — zero token cost. [Y/n]

If yes:

```
/beams:watch start 5
```

Finish with `/beams:status` and a one-line recap: this terminal's name, the beam it joined, and the watcher state. Every *other* terminal joins the same way — run `/beams:start` there too; each gets its own identity automatically.

Stop there — let the user drive.
