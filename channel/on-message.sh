#!/usr/bin/env bash
# beams channel — watcher --on-message hook.
#
# Run once per new beam message by the watcher daemon, which exports BEAMS_BEAM,
# BEAMS_FROM, and BEAMS_PREVIEW. It POSTs the message to THIS Claude session's
# channel server so an already-open, idle session wakes via a <channel> event.
#
# It finds the server's HTTP port from the per-session rendezvous file the
# server publishes (keyed by CLAUDE_CODE_SESSION_ID — the one env var the server
# and the watcher reliably share). The token is resolved the same way the server
# resolves it: BEAMS_CHANNEL_TOKEN, else the contents of BEAMS_CHANNEL_TOKEN_FILE.
#
# Every failure is silent and non-fatal: no curl, no session id, no rendezvous
# file, or a dead port all just mean "no live session to wake right now" — the
# watcher still fired its desktop notification, and the message is still
# surfaced the normal way on the session's next prompt. The watcher caps and
# times out this hook, so a hang here can't stall delivery.

set -u

command -v curl >/dev/null 2>&1 || exit 0

# Identifier-safe the session id before using it in a path (defuse traversal).
sid="${CLAUDE_CODE_SESSION_ID:-}"
sid="${sid//[^A-Za-z0-9_-]/}"
[ -n "$sid" ] || exit 0

port_file="${XDG_CONFIG_HOME:-$HOME/.config}/beams/channels/${sid}.port"
# Must be a regular file: `[ -f ]` is false for a FIFO, so a same-UID peer who
# swaps the port file for a named pipe can't make the read below block forever
# (which would burn this hook's entire timeout slot). Read one line via
# redirection (bounded) rather than `cat` (which would slurp an attacker-grown
# huge file).
[ -f "$port_file" ] || exit 0
# `read` returns nonzero on a final line with no trailing newline even though it
# DID populate $port — so `|| true`, never `|| exit 0` (which would bail before
# POSTing). The digit check below is the real validation.
IFS= read -r port < "$port_file" 2>/dev/null || true
case "$port" in ''|*[!0-9]*) exit 0 ;; esac

# Same token resolution as the server (loadToken): env var wins, then file.
tok="${BEAMS_CHANNEL_TOKEN:-}"
if [ -z "$tok" ] && [ -n "${BEAMS_CHANNEL_TOKEN_FILE:-}" ] && [ -f "${BEAMS_CHANNEL_TOKEN_FILE}" ]; then
  IFS= read -r tok < "${BEAMS_CHANNEL_TOKEN_FILE}" 2>/dev/null || true
fi

curl -s -m 5 -X POST \
  -H "x-beams-token: $tok" \
  -H "x-beams-beam: ${BEAMS_BEAM:-}" \
  -H "x-beams-from: ${BEAMS_FROM:-}" \
  --data-binary "${BEAMS_PREVIEW:-}" \
  "http://127.0.0.1:${port}/" >/dev/null 2>&1 || true
