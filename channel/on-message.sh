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

# Resolve WHICH session's channel server to wake. A long-lived watcher is a
# per-identity singleton, but it freezes the CLAUDE_CODE_SESSION_ID of whoever
# first armed it — and channel servers are per-session, so once that session
# ends every POST forever targets a dead port (the doorbell "goes unreliable").
# Prefer the identity-scoped pointer that each SessionStart refreshes to the
# current live session; fall back to our own env id for smoke tests, manual
# runs, and pre-pointer setups. The pointer lives beside the identity config
# (BEAMS_CONFIG_DIR), which the watcher exports into this hook's env.
sid=""
if [ -n "${BEAMS_CONFIG_DIR:-}" ] && [ -f "$BEAMS_CONFIG_DIR/channel.session" ]; then
  IFS= read -r sid < "$BEAMS_CONFIG_DIR/channel.session" 2>/dev/null || true
fi
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
# Identifier-safe the session id before using it in a path (defuse traversal).
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

# Liveness gate: only ring a server that actually answers. A stale rendezvous
# file (a frozen target, or a session that just died) otherwise sends this POST
# to a dead or recycled port. The /health probe needs no token and is localhost-
# cheap. curl exit 7 == connection refused == nothing is listening == the file
# is stale, so unlink it to self-heal the channels dir (rm drops the name, never
# follows a swapped symlink); on any other failure (e.g. a timeout against a
# busy-but-alive server) leave the file and just skip this POST.
curl -s -m 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1
case $? in
  0) : ;;
  7) rm -f "$port_file" 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac

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
