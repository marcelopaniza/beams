# Security policy

## Supported versions

Active development happens on `main`. Only the **latest tagged release** receives security fixes.

| Version | Supported |
|---|---|
| 0.7.x | ✅ |
| < 0.7 | ❌ — please upgrade |

## Reporting a vulnerability

Open a **private** security advisory via GitHub's "Report a vulnerability" flow (Security tab → "Advisories" → "New draft security advisory"). If you can't use GitHub, email **ai1@todapsystems.ca**. Include:

- Affected version (the version lives in `.claude-plugin/plugin.json`).
- A minimal reproduction — ideally a shell snippet.
- Expected vs observed behaviour.
- Who needs what access to exploit: a non-member of the beam, an authenticated rider, or someone with raw write access to the shared folder. That access tier directly maps to severity.

Acknowledgement within 72 hours; patch within 7 days for confirmed issues, longer for design changes.

## Threat model (short version)

The full table is in the [README's "Identity & security" section](README.md#identity--security). The headline:

- **Forge a message claiming to be from another rider** → defended by Ed25519 signatures with **trust-on-first-use (TOFU) key pinning**. Each session signs with a private key only it holds. A receiver pins a sender's public key on first contact — stored **locally**, never on the share — and from then on verifies against the pinned key, ignoring the sender's published key in the (attacker-writable) shared member record. So an attacker with raw write access to the shared folder cannot impersonate a pinned sender by substituting or removing that published key, and a pinned sender's messages must always carry a valid signature (no unsigned downgrade). The residual exposure is the **first contact**, before any key is pinned — the same assumption as SSH `known_hosts`; rotate a key by deleting its local pin. The signed canonical also covers `from_name` (wire `fmt: 2`), so a third party cannot relabel someone's signed message in transit. **Out of scope:** an attacker who controls the share *before your first contact* with a victim, and a same-UID local process (it can read your private key directly — treat keys like SSH keys).
- **Prompt-inject the model via a crafted message** → defended in the model-facing renderers (`--hook` and `--inject`): bodies XML-escaped, C0/C1 control bytes stripped, per-run nonce on `--inject` fences.
- **Path traversal via terminal-pane env vars (`TMUX_PANE` etc.)** → defended by sanitising the value and rejecting `.`, `..`, leading `-`, leading `.`, and `..` substrings.
- **Read your messages off the share as another UNIX user** → defended by `umask 077` + beam-dir mode `0700`. Defends against accidental disclosure to other local users; does **not** defend against root, filesystem snapshots, or the share host operator.
- **Replay** (drop an old signed message back onto the share) → partial: cursor prevents re-delivery to receivers who already saw it, but new subscribers will see replayed history. Sequence numbers are on the roadmap.

## Out of scope

- An insider with raw write access to the shared folder kicking/locking/transferring driver maliciously. The driver protocol is **cooperative** — defended at the social layer, not the technical one. Use filesystem ACLs if you need stronger guarantees.
- **Encrypted message bodies.** Not implemented. Bodies are signed (authenticity, integrity) but not encrypted (confidentiality). Treat the beam like a logged group chat: do not send secrets on it.
- A malicious local user with shell access on the machine. Ed25519 private keys live in `$BEAMS_CONFIG_DIR/identity.key` at mode `0600`. A user with sufficient privilege can read them. Treat them like SSH keys.

## Responsible disclosure preference

I prefer coordinated disclosure: report privately, give me a reasonable window to ship a fix (7–30 days depending on severity), and we can disclose together. If a fix isn't shipping within that window I'll tell you, and you're free to go public.

I'll credit reporters in the changelog entry unless you'd prefer anonymity.
