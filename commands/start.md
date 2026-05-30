---
description: "First-time setup wizard: ask the user the right questions and walk them through joining a bus."
argument-hint: "(no arguments — interactive)"
---

# /buses:start — guided setup

You are walking the user through their first-time `buses` setup. Be conversational and concise (one or two short questions at a time). Use the answers to call the existing slash commands. Do **not** dump this whole wizard at the user — work through it interactively.

---

## Step 0 — Check current state silently

First, see if this terminal is already initialised:

```bash
test -f "${BUSES_CONFIG_DIR:-${HOME}/.config/buses/sessions/${CLAUDE_CODE_SESSION_ID}}/config.json" && echo INIT || echo NEW
```

- If `INIT`: tell the user "this terminal is already set up" and run `/buses:status`. Ask if they want to (a) add another bus, (b) start over (re-init), or (c) just see status and stop. Then act accordingly. Do NOT re-init silently.
- If `NEW`: proceed to Step 1.

---

## Step 1 — Machine scope

Ask **exactly one** question, two-line max:

> Are you running buses on **just this machine**, or do you plan to coordinate with **other machines** too?
>
> A) Just this machine    B) Multiple machines, this is the **first** one    C) Multiple machines, **joining an existing** setup

Branch on the answer.

---

## Step 2 — Pick the shared folder

**Case A (single machine):**
Suggest a local folder. Default recommendation: `~/buses-share`. Tell them:
> Pick any local folder — all your terminals will see it. I'll use `~/buses-share` unless you want a different path.

Wait for confirmation or a different path. `mkdir -p` it if it doesn't exist, then proceed to Step 3.

**Case B (first of many machines):**
This is the cross-machine case. The folder needs to be visible to every machine that joins later. Explain briefly (one short paragraph), then ask which transport they want:

> Buses needs a folder whose **contents** are visible on every machine. Pick one:
>
> 1. **Cloud sync** (Dropbox, iCloud Drive, Syncthing, OneDrive) — easiest if you already have one. Path is a subfolder inside the sync root.
> 2. **NFS export** — fast, Linux-to-Linux. You'll need root on this machine to export it.
> 3. **I'll figure it out later** — set up locally for now, mount/sync when you add the next machine.

Recommend option 1 if they don't have a preference. Then ask for the absolute path.

If they pick option 2 (NFS), after the path is chosen, give them the export snippet to run (one-time, as root). Use the actual values:

```bash
echo "<their-path> *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -ra && sudo systemctl restart nfs-kernel-server
```

…and tell them to replace `*` with the joining machine's hostname/IP for security.

**Case C (joining an existing setup):**
Ask:
> What shared path did you set up on the **first** machine? And how is it reaching this one — NFS mount, Dropbox/Syncthing, something else?

If they don't know, suggest they run `/buses:status` on the other machine and report the `shared_path` value.

Then verify the path is actually present on **this** machine before initialising:

```bash
ls -la "<their-path>/buses" 2>&1
```

If the listing fails or shows nothing, **stop and help them mount/sync first**. Give the appropriate instructions based on transport:

- NFS:
  ```bash
  sudo mkdir -p "<their-path>"
  sudo mount -t nfs <atlas-host>:<original-path-on-atlas> "<their-path>"
  ```
- Dropbox/iCloud/Syncthing: confirm the sync client is running and the folder appears.

Don't proceed to Step 3 until `ls` shows files (or at least the `buses/` subdir from the other machine).

---

## Step 3 — Init this terminal

```
/buses:init <the-path-from-step-2>
```

Then ask:
> What should this terminal be called? (Used by others to address you. Examples: `atlas-main`, `loop`, `felix-deploy`, `phone-tunnel`.)

Apply:
```
/buses:name <their-pick>
```

---

## Step 4 — Bus

If `/buses:list` shows existing buses, ask which to join (or whether to create a new one). Otherwise prompt:
> What should we call the bus you join? (`all` is the conventional default for everyone on the share.)

Apply:
```
/buses:join <bus-name>
```

(It auto-creates if missing; the creator becomes the driver.)

---

## Step 5 — Watcher (optional)

> Want desktop notifications when messages arrive? (Zero token cost — it's a background bash daemon, not a Claude loop.) [Y/n]

If yes:
```
/buses:watch start 5
```

If they say no, skip and tell them they can start it later.

---

## Step 6 — Confirm and stop

Run `/buses:status` to show the final state. Mention:
- this terminal's name and the bus it joined,
- the watcher status if started,
- that on every **other** terminal they want on the bus, they should run `/buses:start` too — each terminal gets its own identity automatically (per-`CLAUDE_CODE_SESSION_ID`).

Done. Don't ask "anything else?" — let the user drive from here.
