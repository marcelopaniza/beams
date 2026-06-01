#!/usr/bin/env bash
# Round 19 — the in-use lease must be heartbeated ONLY by interactive session
# activity, never by the background watcher daemon.
#
# Regression test for the orphan-watcher bug: a watcher (check.sh --notify)
# spawned by a since-dead Claude session kept re-stamping that session's lease
# on every poll (~5s). The lone identity therefore never went stale, so the
# SessionStart auto-bind hook always saw it "busy" and could never reclaim it —
# every new session in the project landed on "not initialised" forever.
#
# Fix: check.sh runs the lease heartbeat for every mode EXCEPT --notify (the
# detached daemon path), since that caller outlives its session. This round
# proves:
#   (A) check.sh --notify does NOT bump the lease's last_seen,
#   (B) interactive modes (--hook / --count / --human) DO,
#   (C) end-to-end: --notify polling by a "dead" holder cannot keep the lease
#       warm, so a fresh unbound session auto-binds (reclaims) the lone identity.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r19.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"        # sandbox the whole ~/.config/beams tree
export HOME="$TMP/home"                   # keep legacy-config detection inert
export CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
# We drive check.sh directly; never spawn real daemons during the boot test.
export BEAMS_DISABLE_WATCH_ON_BOOT=1
SHARED="$TMP/share"; mkdir -p "$SHARED"
BASE="$XDG_CONFIG_HOME/beams"
PKEY=$(printf '%s' "$CLAUDE_PROJECT_DIR" | sed 's,/,-,g')
IDENT="$BASE/projects/$PKEY/identities"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# Run a lib as a specific Claude Code session id, with NO BEAMS_CONFIG_DIR
# override, so real session/bind resolution is exercised (same as round-18).
run()  { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
# Fire the SessionStart hook as a given (unbound) session id.
boot() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN"; bash "$PLUGIN/hooks/check-on-start.sh" </dev/null ); }

LEASE="$IDENT/watch-id/lease.json"
seen()     { jq -r '.last_seen' "$LEASE"; }                                          # current heartbeat epoch
set_seen() { local t; t=$(mktemp); jq --argjson v "$1" '.last_seen=$v' "$LEASE" > "$t" && mv "$t" "$LEASE"; }

banner "0. bind identity 'watch-id' (holder = sess-W) with a subscription"
run sess-W init "$SHARED" >/dev/null
run sess-W name watch-id  >/dev/null
run sess-W join roomA     >/dev/null
[ -f "$LEASE" ]                                  || fail "no lease after bind"
[ "$(jq -r .bound_session "$LEASE")" = sess-W ]  || fail "lease holder != sess-W"
pass "identity 'watch-id' bound by sess-W with a fresh lease"

banner "A. check.sh --notify (the watcher path) must NOT refresh the lease"
set_seen 1000                                    # pretend the last heartbeat was long ago
run sess-W check --notify >/dev/null 2>&1 || true
a=$(seen)
[ "$a" = 1000 ] || fail "--notify bumped last_seen ($a != 1000): the watcher is heartbeating the lease (the bug)"
pass "--notify left last_seen untouched (the daemon is not a liveness heartbeat)"

banner "B. interactive checks (--hook, --count, --human) MUST refresh the lease"
for m in --hook --count --human; do
  set_seen 1000
  run sess-W check "$m" >/dev/null 2>&1 || true
  v=$(seen)
  [[ "$v" =~ ^[0-9]+$ ]] || fail "$m: last_seen is not numeric ($v)"
  [ "$v" -gt 1000 ]      || fail "$m did NOT refresh last_seen ($v) — a live session must heartbeat its lease"
done
pass "interactive modes refresh last_seen (a live session keeps its lease warm)"

banner "C. end-to-end: orphan --notify polling can't keep a dead lease warm; a new session reclaims it"
# Simulate the production bug: sess-W is gone (no more interactive activity), but
# its detached watcher keeps polling check.sh --notify. Age the lease far past the
# stale window, then run several --notify cycles as the orphan. With the fix they
# are no-ops, so the lease stays stale and the lone identity stays reclaimable.
set_seen 1                                       # epoch 1 = ancient (>> the default 900s stale window)
for i in 1 2 3; do run sess-W check --notify >/dev/null 2>&1 || true; done
[ "$(seen)" = 1 ] || fail "--notify cycles re-warmed a stale lease (now $(seen)) — the orphan-watcher bug is back"
# A fresh, unbound session boots: 'watch-id' is the lone identity and its lease is
# stale (the orphan never refreshed it) → auto-bind must silently reclaim it.
bout=$(boot fresh-sess)
printf '%s' "$bout" | jq -e '.hookSpecificOutput.additionalContext | test("auto-bound to \"watch-id\"")' >/dev/null \
  || fail "SessionStart did NOT reclaim the stale lone identity (it still looks busy): $bout"
[ "$(cat "$BASE/sessions/fresh-sess/bound" 2>/dev/null)" = watch-id ] \
  || fail "auto-bind didn't write fresh-sess's bound pointer"
pass "orphan --notify polling left the lease stale; a fresh session auto-bound (reclaimed) it"

green ""
green "round-19 PASS: the lease heartbeat is interactive-only — the background watcher (--notify) never keeps a dead session's lease warm, so SessionStart auto-bind can always reclaim a lone identity"
