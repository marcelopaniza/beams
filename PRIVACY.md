# Privacy policy

**Last updated:** 2026-05-24

`beams` is a Claude Code plugin that runs entirely on your own machine and writes to a shared folder you control. The author operates **no servers**, collects **no telemetry**, and receives **no data** from your use of the plugin.

## What `beams` does not do

- No network calls to the author or any third party.
- No analytics, crash reporting, usage pings, or "phone-home" behaviour.
- No account, login, or registration.
- No advertising identifiers.

## What stays on your machine only

Everything in `$BEAMS_CONFIG_DIR` (default `~/.config/beams/`):

- Your **Ed25519 private key** (`identity.key`, mode `0600`) — never transmitted, never copied to the shared folder.
- Your **session UUID** and local config (shared folder path, friendly name).
- **Read cursors** — which messages this session has already seen.

## What is written to the shared folder you configure

When you join a beam, the following lands in the shared folder path you chose during `/beams:init`:

- **Messages** you send: body, recipient list, sender id/name, timestamp, Ed25519 signature.
- **Presence records**: your session UUID, friendly name, hostname, last-seen timestamp.
- **Your public key** (so other riders can verify your signatures).
- **Beam metadata**: driver id, lock state, banlist, configuration.

This data is visible to **anyone with read access to that folder**. If the folder is synced via a third-party provider (Dropbox, Google Drive, OneDrive, Syncthing, NFS, SMB, etc.), that provider sees the same data under its own privacy policy.

## Confidentiality limitations

Message bodies are **signed but not encrypted**. Treat a beam like a logged group chat — do not send secrets, credentials, or personal data you wouldn't put in a shared Slack channel. See [SECURITY.md](SECURITY.md) for the full threat model.

## Children's privacy

`beams` is a developer tool and is not directed at children under 13.

## Changes to this policy

Material changes will be noted in [CHANGELOG.md](CHANGELOG.md) and reflected in the "Last updated" date above.

## Contact

Questions: open an issue at <https://github.com/marcelopaniza/beams/issues> or email **ai1@todapsystems.ca**.
