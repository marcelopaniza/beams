#!/usr/bin/env bash
# Round 16: proactive delivery hooks (v0.9.0).
#
# Verifies the SessionStart + Stop hooks added in v0.9.0:
#   1. SessionStart hook surfaces unread as additionalContext (hookEventName
#      "SessionStart").
#   2. It advances the cursor, so it's silent on the next start.
#   3. It's a silent no-op for a session with no beams config.
#   4. The Stop hook does NOTHING by default (react.on_stop unset/false).
#   5. With react.on_stop=true the Stop hook emits {"decision":"block",reason}
#      carrying the inbox when a message arrived.
#   6. The stop_hook_active guard short-circuits (no re-block) AND does not
#      consume the message (a later non-active fire still delivers it).
#   7. Fresh configs default watch_on_boot=true (always-armed) + on_stop=false;
#      the `responder` preset additionally turns on_stop on.
#   8. SessionStart brings up the notifier daemon when watch_on_boot is on
#      (now the default).
#
# And the SessionStart policy for an unbound session (a fresh session id after a
# restart): auto-bind only when CERTAIN which identity this is, else ask.
#   9.  exactly one bindable (free) identity → silently rebind to it, no prompt.
#   10. the lone identity is busy (held by another live session) → silent.
#   11. two-or-more bindable + no terminal-anchor match → surface the list so the
#       model can ask (never guesses). Anchor-matched auto-bind: see round-25.
#
# The watcher auto-arms on boot by default now, so the suite exports
# BEAMS_DISABLE_WATCH_ON_BOOT=1 to stay daemon-free (portable under CI); only
# check 8 re-enables it, starts one watcher, and the cleanup trap kills it.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test-r16.XXXXXX)
# Sandbox the whole beams home + project key so this round neither reads nor
# writes the real ~/.config/beams. Without this, the SessionStart unbound-
# identity path (subtest 3 + the auto-bind checks below) would resolve to the
# developer's live identities dir and see their real identities. Mirrors the
# isolation rounds 3 & 18 already do.
export HOME="$TMPDIR/home"
export XDG_CONFIG_HOME="$TMPDIR/xdg"
export CLAUDE_PROJECT_DIR="$TMPDIR/proj"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$CLAUDE_PROJECT_DIR"

# The watcher auto-arms on boot by default now. Suppress it across the suite so
# subtests don't spawn notifier daemons (or fire real notify-send popups);
# subtest 8 re-enables it for the one invocation that tests the autostart.
export BEAMS_DISABLE_WATCH_ON_BOOT=1
SHARED="$TMPDIR/share"
CFG_A="$TMPDIR/cfg-a"        # alice — recipient, runs the hooks
CFG_B="$TMPDIR/cfg-b"        # bob   — sender
CFG_C="$TMPDIR/cfg-c"        # carol — responder-preset session
CFG_NONE="$TMPDIR/cfg-none"  # never initialised

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() {
  # Kill any watcher the responder-preset path may have spawned.
  for cfg in "$CFG_A" "$CFG_B" "$CFG_C"; do
    for f in "$cfg"/state/*/watcher.pid; do
      [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
    done
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

run_as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
as_a() { run_as "$CFG_A" "$@"; }
as_b() { run_as "$CFG_B" "$@"; }

# Run a hook script with a given identity + stdin JSON, exactly as Claude Code
# would: CLAUDE_PLUGIN_ROOT set, the hook payload on stdin.
hook() {
  # $1 = config dir, $2 = hook script basename, $3 = stdin JSON (may be empty)
  ( export CLAUDE_PLUGIN_ROOT="$PLUGIN" BEAMS_CONFIG_DIR="$1"
    printf '%s' "${3:-}" | "$PLUGIN/hooks/$2" )
}

mkdir -p "$SHARED"

banner "init alice (recipient) + bob (sender) on beam r16-beam"
as_a init "$SHARED" >/dev/null
as_b init "$SHARED" >/dev/null
as_a name alice >/dev/null
as_b name bob   >/dev/null
as_b create r16-beam >/dev/null
as_b join   r16-beam >/dev/null
as_a join   r16-beam >/dev/null
pass "alice + bob subscribed"

# ── 1. SessionStart surfaces unread ────────────────────────────────────────
banner "SessionStart hook surfaces unread as additionalContext"
as_b send r16-beam alice "boot-check-msg-one" >/dev/null
out=$(hook "$CFG_A" check-on-start.sh '{"hook_event_name":"SessionStart","source":"startup"}')
[ -n "$out" ] || fail "SessionStart produced no output for a waiting message"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "hookEventName is not SessionStart"; }
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("boot-check-msg-one")' >/dev/null \
  || fail "additionalContext missing the message body"
pass "SessionStart injected the message"

# ── 2. cursor advanced → no re-delivery, but the tab title IS (re)asserted ──
# A bound session now always carries sessionTitle so the Claude Code tab tracks
# the identity (the /rename the user used to type). With nothing waiting there
# must still be NO additionalContext (nothing re-delivered).
banner "SessionStart re-delivers nothing once read, but sets the tab title"
out=$(hook "$CFG_A" check-on-start.sh '{"source":"startup"}')
echo "$out" | jq -e '.hookSpecificOutput.sessionTitle == "alice"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "idle SessionStart didn't set the tab title to the bound identity"; }
echo "$out" | jq -e '(.hookSpecificOutput.additionalContext // "") == ""' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "idle SessionStart re-delivered an already-seen message"; }
pass "SessionStart re-delivers nothing but (re)asserts the tab title"

# ── 3. no config → silent no-op ────────────────────────────────────────────
banner "SessionStart no-ops for a session with no beams config"
out=$(hook "$CFG_NONE" check-on-start.sh '{"source":"startup"}')
[ -z "$out" ] || { echo "$out" | sed 's/^/    /'; fail "SessionStart emitted for a non-beams session"; }
pass "SessionStart silent without config"

# ── 4. Stop hook off by default ────────────────────────────────────────────
banner "Stop hook does nothing when react.on_stop is unset (default)"
sleep 1
as_b send r16-beam alice "stop-msg-default-off" >/dev/null
out=$(hook "$CFG_A" respond-on-stop.sh '{"stop_hook_active":false}')
[ -z "$out" ] || { echo "$out" | sed 's/^/    /'; fail "Stop hook fired without opt-in"; }
pass "Stop hook inert by default"

# ── 5. opt in → Stop delivers a block ──────────────────────────────────────
banner "react.on_stop=true → Stop hook emits decision:block carrying the inbox"
# Flip the flag the way a user (or the responder preset) would.
tmp=$(mktemp); jq '.react.on_stop = true' "$CFG_A/config.json" > "$tmp" && mv "$tmp" "$CFG_A/config.json"
out=$(hook "$CFG_A" respond-on-stop.sh '{"stop_hook_active":false}')
[ -n "$out" ] || fail "Stop hook produced nothing after opt-in (a message was waiting)"
echo "$out" | jq -e '.decision == "block"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "Stop output is not decision:block"; }
echo "$out" | jq -e '.reason | contains("stop-msg-default-off")' >/dev/null \
  || fail "Stop reason missing the waiting message body"
pass "Stop hook delivered block + inbox"

# ── 6. loop guard + non-consumption ────────────────────────────────────────
banner "stop_hook_active guard short-circuits without consuming the message"
sleep 1
as_b send r16-beam alice "guard-msg" >/dev/null
out=$(hook "$CFG_A" respond-on-stop.sh '{"stop_hook_active":true}')
[ -z "$out" ] || { echo "$out" | sed 's/^/    /'; fail "Stop hook blocked despite stop_hook_active=true"; }
# The guarded fire must NOT have advanced the cursor: a normal fire still gets it.
out=$(hook "$CFG_A" respond-on-stop.sh '{"stop_hook_active":false}')
echo "$out" | jq -e '.reason | contains("guard-msg")' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "guarded fire consumed the message (cursor advanced wrongly)"; }
pass "guard short-circuits and preserves the message"

# ── 7. react defaults + responder preset ───────────────────────────────────
banner "fresh config defaults watcher ON + on_stop OFF; responder preset also enables on_stop"
jq -e '.react.watch_on_boot == true and .react.on_stop == false' "$CFG_B/config.json" >/dev/null \
  || fail "fresh config should default watch_on_boot=true, on_stop=false"
( export BEAMS_CONFIG_DIR="$CFG_C"; "$PLUGIN/lib/init.sh" "$SHARED" --profile responder >/dev/null )
jq -e '.role == "responder" and .react.watch_on_boot == true and .react.on_stop == true' "$CFG_C/config.json" >/dev/null \
  || { jq '.' "$CFG_C/config.json" | sed 's/^/    /'; fail "responder preset did not enable react flags"; }
pass "react defaults + responder preset correct"

# ── 8. watch_on_boot=true → SessionStart autostarts the notifier daemon ─────
banner "react.watch_on_boot=true → SessionStart brings up the watcher (once)"
# CFG_C was initialised with --profile responder above (watch_on_boot=true), so
# firing its SessionStart hook must bring up the background notifier daemon.
# Re-enable autostart for just this invocation (the suite disables it globally).
( unset BEAMS_DISABLE_WATCH_ON_BOOT; hook "$CFG_C" check-on-start.sh '{"source":"startup"}' ) >/dev/null 2>&1
wpid=""
for _ in $(seq 1 15); do
  for f in "$CFG_C"/state/*/watcher.pid; do
    [ -f "$f" ] && wpid=$(cat "$f" 2>/dev/null) || true
  done
  [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && break
  sleep 0.3
done
{ [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; } \
  || fail "watch_on_boot did not bring up a live watcher daemon"
pass "watch_on_boot autostarted the watcher (pid $wpid)"

# ── 8b. react.watch_on_boot:false MUST opt out (regression) ─────────────────
# config_get appends `// ""` and jq's `//` collapses JSON false → "", so the
# hook must read the raw value to honour an explicit false. Otherwise the
# documented per-session opt-out is silently dead and the watcher always arms.
banner "watch_on_boot:false suppresses the boot watcher (opt-out works)"
tmp=$(mktemp); jq '.react.watch_on_boot = false' "$CFG_B/config.json" > "$tmp" && mv "$tmp" "$CFG_B/config.json"
( unset BEAMS_DISABLE_WATCH_ON_BOOT; hook "$CFG_B" check-on-start.sh '{"source":"startup"}' ) >/dev/null 2>&1
sleep 1.5
optout_pid=""
for f in "$CFG_B"/state/*/watcher.pid; do [ -f "$f" ] && optout_pid=$(cat "$f" 2>/dev/null) || true; done
if [ -n "$optout_pid" ] && kill -0 "$optout_pid" 2>/dev/null; then
  kill "$optout_pid" 2>/dev/null || true
  fail "watch_on_boot:false did NOT suppress the watcher (opt-out broken): pid $optout_pid"
fi
pass "watch_on_boot:false suppressed the boot watcher"

# ── 9-11. SessionStart "auto-bind, never ask" for an unbound session ────────
# These use NO BEAMS_CONFIG_DIR override (so name.sh runs the real bind
# machinery and creates durable, name-keyed identities) and a fresh
# CLAUDE_CODE_SESSION_ID per session (so each is genuinely unbound until the
# hook decides). Each case gets its own project dir → its own identities dir,
# so the cases don't contaminate each other.
# These subtests are about the count-based / ambiguous paths, NOT the terminal
# anchor — so unset every anchor signal in the subshells. Otherwise a developer
# running the suite inside tmux would have $TMUX_PANE leak in: mk_identity would
# record an anchor and boot_unbound would match it, turning the "ambiguous →
# list" case into a silent auto-bind and breaking subtest 11 nondeterministically.
mk_identity() {  # $1=session-id  $2=name  $3=project-dir  → creates a durable identity
  ( unset BEAMS_CONFIG_DIR TMUX TMUX_PANE TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$3"
    mkdir -p "$3"
    "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null
    "$PLUGIN/lib/name.sh" "$2"      >/dev/null )
}
idents_of() { printf '%s/beams/projects/%s/identities' \
  "$XDG_CONFIG_HOME" "$(printf '%s' "$1" | sed 's,/,-,g')"; }
boot_unbound() {  # $1=fresh-session-id  $2=project-dir  → prints the hook's stdout
  ( unset BEAMS_CONFIG_DIR TMUX TMUX_PANE TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN"
    printf '%s' '{"source":"startup"}' | "$PLUGIN/hooks/check-on-start.sh" )
}

banner "SessionStart auto-binds (never asks) when exactly one free identity exists"
P_ONE="$TMPDIR/proj-autobind"
mk_identity sid-solo solo "$P_ONE"
rm -f "$(idents_of "$P_ONE")/solo/lease.json"   # release the lease → 'solo' is free
out=$(boot_unbound sid-fresh1 "$P_ONE")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("auto-bound to \"solo\"")' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "did not auto-bind to the lone free identity"; }
echo "$out" | jq -e '.hookSpecificOutput.sessionTitle == "solo"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "auto-bind did not set the Claude Code tab title"; }
[ "$(cat "$XDG_CONFIG_HOME/beams/sessions/sid-fresh1/bound" 2>/dev/null)" = "solo" ] \
  || fail "auto-bind did not write the bound pointer for the new session"
pass "auto-bound silently to the lone free identity (and titled the tab)"

banner "SessionStart stays silent when the lone identity is busy (held elsewhere)"
P_BUSY="$TMPDIR/proj-busy"
mk_identity sid-busy held "$P_BUSY"             # lease just claimed by sid-busy → busy
# 'sid-busy' must look alive for the lease to read busy — a gone same-host holder
# is reclaimable now (round-20). Force it live via the test seam.
export BEAMS_FAKE_LIVE_SESSIONS=sid-busy
out=$(boot_unbound sid-fresh2 "$P_BUSY")
unset BEAMS_FAKE_LIVE_SESSIONS
[ -z "$out" ] || { echo "$out" | sed 's/^/    /'; fail "auto-bound (or prompted) for a busy identity — must never steal it"; }
pass "silent for a busy identity (not stolen)"

banner "SessionStart surfaces the choice when several identities are bindable (ambiguous)"
P_MULTI="$TMPDIR/proj-multi"
mk_identity sid-a aaa "$P_MULTI"
mk_identity sid-b bbb "$P_MULTI"
rm -f "$(idents_of "$P_MULTI")/aaa/lease.json" "$(idents_of "$P_MULTI")/bbb/lease.json"
out=$(boot_unbound sid-fresh3 "$P_MULTI")
# No terminal anchor (the subshell unsets them) → can't know which one this is,
# so list both and let the model ask — never guess, never auto-bind.
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("aaa") and test("bbb")' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "did not surface both bindable identities for the user to pick"; }
echo "$out" | jq -e '(.hookSpecificOutput.sessionTitle // "") == ""' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "titled the tab while still unbound (must not)"; }
[ -z "$(cat "$XDG_CONFIG_HOME/beams/sessions/sid-fresh3/bound" 2>/dev/null)" ] \
  || fail "must NOT auto-bind when the choice is ambiguous and unanchored"
pass "surfaced the ambiguous choice instead of guessing"

banner "round 16 complete"
green "ALL ROUND-16 CHECKS PASSED"
