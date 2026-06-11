#!/usr/bin/env bash
# beams watcher --on-message hook — the real-time doorbell, flag-free edition.
#
# Run once per new beam message by the watcher daemon (lib/watcher_daemon.sh),
# which exports BEAMS_CONFIG_DIR, BEAMS_BEAM, BEAMS_FROM, and BEAMS_PREVIEW.
# It appends ONE line describing the message to the identity's wake file:
#
#   $BEAMS_CONFIG_DIR/wake.log
#
# An open Claude Code session tails that file with a persistent Monitor task
# (the SessionStart hook asks the session to arm it on its first prompt — see
# hooks/check-on-start.sh). The harness turns each appended line into an event
# that re-invokes the session even when it is fully idle; the woken session
# then runs /beams:read.
#
#   watcher daemon --> this hook --> wake.log --> Monitor event --> Claude wakes
#
# This replaces the channel-server transport (a per-session MCP HTTP bridge
# that only worked under --dangerously-load-development-channels): no dev
# flags, no server, no ports, no tokens — the only moving part is a one-line
# append. Every failure here is silent and non-fatal: the watcher already
# fired its desktop notification, and the message is still surfaced the
# normal way on the session's next prompt.

set -u

dir="${BEAMS_CONFIG_DIR:-}"
[ -n "$dir" ] && [ -d "$dir" ] || exit 0
wake="$dir/wake.log"

# Write ONLY to a regular file. A same-UID peer who plants wake.log as a
# symlink could redirect the append to a victim file; planting a FIFO would
# make both `wc -c <` and the `>>` open below block until a reader shows up,
# burning this dispatch's whole timeout slot (the round-22 hang, reborn).
# `[ -L ]` catches the symlink; `[ -e ] && ! [ -f ]` catches FIFOs/devices.
if [ -L "$wake" ]; then exit 0; fi
if [ -e "$wake" ] && [ ! -f "$wake" ]; then exit 0; fi

# Defence-in-depth sanitize. The daemon already strips C0 + DEL before
# exporting, but manual runs and future refactors may not — and one stray
# newline would split this message into two Monitor events (or let a crafted
# body forge a fake second "message" line). Strip bytes, then cap the preview
# so a huge body can't bloat the wake file or the woken session's context.
beam=$(printf '%s'    "${BEAMS_BEAM:-}"    | LC_ALL=C tr -d '\000-\037\177')
from=$(printf '%s'    "${BEAMS_FROM:-}"    | LC_ALL=C tr -d '\000-\037\177')
preview=$(printf '%s' "${BEAMS_PREVIEW:-}" | LC_ALL=C tr -d '\000-\037\177')
preview=${preview:0:160}
[ -n "$beam" ] || exit 0

# Self-cap: truncate-then-append past 1MB so a weeks-long session can't grow
# the file unboundedly. The reading `tail -F` follows a truncation cleanly.
if [ -f "$wake" ] && [ "$(wc -c < "$wake" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  : > "$wake"
fi

# One message, one line. A single O_APPEND write this small (<4KB) is atomic,
# so concurrent dispatches (daemon-capped at 8) never interleave bytes.
printf 'beams: new message on "%s" from %s — %s (run /beams:read to fetch it)\n' \
  "$beam" "$from" "$preview" >> "$wake"
