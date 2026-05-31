#!/usr/bin/env bash
# /beams:admin <subcommand> [args] — single dispatcher for the driver-only and
# maintenance operations, kept off the everyday command surface so the slash
# menu stays small. One audited entry point: this script owns the subcommand
# allowlist and routes each verb to the very same lib the old standalone command
# called, preserving its exact argument contract:
#
#   - kick / lock        receive the payload on STDIN (--from-stdin), so the
#                        quoted-heredoc protection against $(...) / backtick
#                        expansion in user reason text is preserved end to end
#                        (see lib/send.sh + tests/round-10.sh for the rationale).
#   - everything else     receive "$ARGUMENTS" as one string and re-split it
#                        themselves (the standard Pattern A fallback in each lib).
#   - test               forwards split round numbers to tests/run-all.sh.
#
# Driver enforcement is UNCHANGED — it lives inside each target lib (is_driver),
# not in the command surface, so consolidating the commands does not loosen any
# privilege check. This script does NOT source common.sh: it must stay usable
# before init (e.g. `/beams:admin init`), and routing needs no shared state.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# The .md wrapper passes "$ARGUMENTS" as one quoted string via a quoted-delimiter
# heredoc, so $(...) / backticks in user text are never expanded by the host
# shell. Peel off the first whitespace-delimited token as the subcommand and
# forward the remainder verbatim — embedded newlines preserved — exactly as each
# lib expects. No eval, no command substitution touches the user payload here.
raw="${1-}"
raw="${raw#"${raw%%[![:space:]]*}"}"        # strip any leading whitespace
sub="${raw%%[[:space:]]*}"                   # first token = subcommand
rest="${raw#"$sub"}"                          # everything after the subcommand
rest="${rest#"${rest%%[![:space:]]*}"}"      # strip the whitespace that separated them

usage() {
  cat <<'EOF'
beams admin — driver & maintenance operations

  usage: /beams:admin <subcommand> [args]

  beam governance (driver only):
    create <beam>                        create a beam without subscribing
    kick <beam> <who> [reason...]        ban a member from a beam
    unkick <beam> <who>                  lift a ban
    lock <beam> [reason...]              restrict sending to the driver
    unlock <beam>                        clear the lock
    transfer-driver <beam> <who> [--force]   hand off the driver role
    require-signatures <beam> on|off     require signed messages

  housekeeping (driver only):
    gc <beam|all> [--older-than 90d] [--dry-run] [--force]    delete old messages
    cleanup-stale <beam> [--older-than <dur>] [--dry-run] [--force]   drop stale members

  membership / info:
    leave <beam>                         unsubscribe this terminal
    members <beam>                       list a beam's riders (alias: riders)

  setup / maintenance:
    init <path> [--force] [--profile <name>]   point this terminal at a share
    test [round-numbers...]              run the smoke suite

  Everyday commands stay top-level:
    /beams:send  /beams:read  /beams:status  /beams:join
    /beams:name  /beams:list  /beams:watch   /beams:start
EOF
}

case "$sub" in
  # STDIN contract — preserves quoted-heredoc safety for user reason text.
  kick|lock)
    exec "$here/${sub}.sh" --from-stdin <<<"$rest" ;;

  # Single-string contract — each lib re-splits "$1" itself (Pattern A fallback).
  unlock|unkick|gc|cleanup-stale|require-signatures|transfer-driver|create|leave|init|members)
    exec "$here/${sub}.sh" "$rest" ;;

  # Read-only roster, kept as an alias of members.
  riders)
    exec "$here/members.sh" "$rest" ;;

  # Smoke suite lives under tests/ and takes round numbers as separate args.
  test)
    read -ra __rounds <<<"$rest"
    exec "$here/../tests/run-all.sh" "${__rounds[@]}" ;;

  ""|help|-h|--help)
    usage ;;

  *)
    # Sanitise + cap before echoing — $sub is user input and could carry ANSI
    # escapes or a huge typo'd blob. Same idiom as bin/beams's unknown handler.
    safe_sub=$(printf '%s' "$sub" | LC_ALL=C tr -c 'A-Za-z0-9._-' '?' | cut -c1-40)
    printf 'beams: unknown admin subcommand: %s\n\n' "$safe_sub" >&2
    usage >&2
    exit 2 ;;
esac
