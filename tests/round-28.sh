#!/usr/bin/env bash
# Round 28 — the flag-free real-time doorbell: lib/on-message.sh appends one
# wake line per new message to $BEAMS_CONFIG_DIR/wake.log, and the SessionStart
# hook (a) (re)arms the watcher with that hook unconditionally and (b) asks the
# session to arm a persistent Monitor on the wake file (the additionalContext
# instruction). This transport replaces the channel server (rounds 21/27,
# retired): no dev flags, no ports, no tokens.
# Cases:
#   A. a dispatch appends ONE formatted line; a second dispatch appends, not clobbers
#   B. missing/nonexistent BEAMS_CONFIG_DIR → silent no-op, nothing created
#   C. wake.log planted as a symlink → refused; victim file untouched
#   D. control chars stripped, >160-char preview capped, empty beam → no line
#   E. a >1MB wake.log self-caps (truncate-then-append)
#   F. SessionStart: truncates stale wake.log, restarts the watcher with the
#      hook armed (on-message=ACTIVE), and emits the Monitor-arm instruction
#   F2. a responder-role config flips the instruction's reply clause to an
#      autonomous-reply grant (still walled off from destructive asks)
#   G. SessionStart with source=compact/clear → NO arm instruction (monitors
#      survive in-process; TaskList can't probe them, so never re-instruct)
#   H. BEAMS_DISABLE_WATCH_ON_BOOT=1 → no watcher, no arm instruction
#   I. end to end: real send → watcher poll → dispatch → wake.log line

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r28.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg" HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR
export BEAMS_NOTIFIER_CMD=true        # no real desktop notifications
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # F/G unset this inside their own subshell
SHARED="$TMP/share"; mkdir -p "$SHARED"
CFG_B="$TMP/cfg-b"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() {
  local f
  for f in "$XDG_CONFIG_HOME"/beams/projects/*/identities/*/state/*/watcher.pid \
           "$CFG_B"/state/*/watcher.pid; do
    [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

runas()  { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
run_as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
om()     { env BEAMS_CONFIG_DIR="$1" BEAMS_BEAM="$2" BEAMS_FROM="$3" BEAMS_PREVIEW="$4" \
             bash "$PLUGIN/lib/on-message.sh"; }

# ---------------------------------------------------------------------------
banner "A. one dispatch, one formatted line; appends never clobber"
CFG="$TMP/cfg"; mkdir -p "$CFG"
om "$CFG" all jose "wake up neo"
[ -f "$CFG/wake.log" ] || fail "wake.log was not created"
grep -qF 'beams: new message on "all" from jose — wake up neo (run /beams:read to fetch it)' \
  "$CFG/wake.log" || fail "wake line malformed: $(cat "$CFG/wake.log")"
[ "$(wc -l < "$CFG/wake.log")" = 1 ] || fail "expected exactly 1 line"
om "$CFG" all ze "second message"
[ "$(wc -l < "$CFG/wake.log")" = 2 ] || fail "second dispatch clobbered instead of appending"
grep -qF 'from ze — second message' "$CFG/wake.log" || fail "second line missing"
pass "one line per message, append semantics"

# ---------------------------------------------------------------------------
banner "B. missing / nonexistent BEAMS_CONFIG_DIR → silent no-op"
env -u BEAMS_CONFIG_DIR BEAMS_BEAM=all BEAMS_FROM=x BEAMS_PREVIEW=y \
  bash "$PLUGIN/lib/on-message.sh" || fail "unset BEAMS_CONFIG_DIR: expected rc=0"
om "$TMP/does-not-exist" all x y || fail "nonexistent dir: expected rc=0"
[ ! -e "$TMP/does-not-exist" ] || fail "hook created the missing config dir"
pass "no config dir → exit 0, nothing created"

# ---------------------------------------------------------------------------
banner "C. a symlinked wake.log is refused (victim untouched)"
CFGC="$TMP/cfg-c"; mkdir -p "$CFGC"
VICTIM="$TMP/victim"; echo original > "$VICTIM"
ln -s "$VICTIM" "$CFGC/wake.log"
om "$CFGC" all mallory "redirect me" || fail "symlink case: expected rc=0"
[ "$(cat "$VICTIM")" = original ] || fail "hook wrote THROUGH the planted symlink"
[ -L "$CFGC/wake.log" ] || fail "hook replaced the symlink (should leave it alone)"
pass "symlink refused; victim file untouched"

# ---------------------------------------------------------------------------
banner "D. sanitization: control chars stripped, preview capped, empty beam dropped"
CFGD="$TMP/cfg-d"; mkdir -p "$CFGD"
HOSTILE=$'PRE\nFAKE-second-line\x1b[2K\x07\x09\x7fPOST'
om "$CFGD" all eve "$HOSTILE"
[ "$(wc -l < "$CFGD/wake.log")" = 1 ] || fail "newline in preview split the wake line"
# Grep for the literal control BYTES — a hex-dump substring check false-positives
# across byte boundaries (e.g. " r" = 20 72 reads as "...2072..." ⊃ "07").
for cb in $'\x1b' $'\x07' $'\x09' $'\x7f'; do
  LC_ALL=C grep -qF -- "$cb" "$CFGD/wake.log" \
    && fail "control byte 0x$(printf '%02x' "'$cb") survived into wake.log" || true
done
grep -q 'PRE.*POST' "$CFGD/wake.log" || fail "visible text lost — strip too aggressive"
LONG=$(printf 'x%.0s' $(seq 1 300))
om "$CFGD" all eve "$LONG"
grep -E 'x{160}' "$CFGD/wake.log" >/dev/null || fail "preview truncated below 160 chars"
grep -E 'x{161}' "$CFGD/wake.log" >/dev/null && fail "preview not capped at 160 chars" || true
n_before=$(wc -l < "$CFGD/wake.log")
om "$CFGD" "" eve "no beam name"
[ "$(wc -l < "$CFGD/wake.log")" = "$n_before" ] || fail "empty beam still appended a line"
pass "C0+DEL stripped, 160-char preview cap, empty beam dropped"

# ---------------------------------------------------------------------------
banner "E. a >1MB wake.log self-caps (truncate-then-append)"
CFGE="$TMP/cfg-e"; mkdir -p "$CFGE"
head -c 1100000 /dev/zero | tr '\0' 'a' > "$CFGE/wake.log"
om "$CFGE" all bulk "after the cap"
[ "$(wc -l < "$CFGE/wake.log")" = 1 ] || fail "oversized wake.log was not truncated"
[ "$(wc -c < "$CFGE/wake.log")" -lt 4096 ] || fail "wake.log still oversized after cap"
grep -qF 'after the cap' "$CFGE/wake.log" || fail "post-cap line missing"
pass "1MB cap: truncated, then the fresh line appended"

# ---------------------------------------------------------------------------
banner "F. SessionStart truncates wake.log, arms the watcher, asks for the Monitor"
runas boot-sess init "$SHARED" >/dev/null
runas boot-sess name alice      >/dev/null
ALICE_CFG=$(find "$XDG_CONFIG_HOME/beams/projects" -type d -name alice | head -1)
[ -n "$ALICE_CFG" ] || fail "could not locate alice's identity dir"
printf 'stale line from a previous session\n' > "$ALICE_CFG/wake.log"

out=$( unset BEAMS_DISABLE_WATCH_ON_BOOT
       export CLAUDE_CODE_SESSION_ID=boot-sess CLAUDE_PLUGIN_ROOT="$PLUGIN"
       printf '{"source":"startup"}' | bash "$PLUGIN/hooks/check-on-start.sh" 2>/dev/null ) || true

ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null) || ctx=""
printf '%s' "$ctx" | grep -q  'beams doorbell'            || fail "arm instruction missing from additionalContext: $out"
printf '%s' "$ctx" | grep -q  'Monitor'                   || fail "arm instruction does not name the Monitor tool"
printf '%s' "$ctx" | grep -qF "$ALICE_CFG/wake.log"       || fail "arm instruction missing the wake.log path"
printf '%s' "$ctx" | grep -qF "tail -n 0 -F"              || fail "arm instruction missing the tail command"
printf '%s' "$ctx" | grep -q  'persistent: true'          || fail "arm instruction missing persistent: true"
printf '%s' "$ctx" | grep -q  'only if this session'      || fail "default (non-responder) reply clause missing"
[ ! -s "$ALICE_CFG/wake.log" ] || fail "stale wake.log was not truncated at session start"

# The restart is backgrounded — wait for the daemon, then check the hook is armed.
i=0
while [ "$i" -lt 50 ]; do
  st=$(run_as "$ALICE_CFG" watch status 2>/dev/null || true)
  printf '%s' "$st" | grep -qE 'on-message:[[:space:]]+ACTIVE' && break
  sleep 0.3; i=$((i+1))
done
printf '%s' "$st" | grep -qE 'on-message:[[:space:]]+ACTIVE' \
  || { red "  watch status:"; printf '%s\n' "$st" | sed 's/^/    /'; fail "watcher not armed with the wake hook"; }
wpid=$(cat "$ALICE_CFG"/state/*/watcher.pid 2>/dev/null | head -1) || wpid=""
if [ -n "$wpid" ] && [ -r "/proc/$wpid/environ" ]; then
  tr '\0' '\n' < "/proc/$wpid/environ" | grep -qF "lib/on-message.sh" \
    || fail "daemon env does not reference lib/on-message.sh"
fi
pass "wake.log truncated; watcher restarted with the hook; Monitor instruction emitted"

# ---------------------------------------------------------------------------
banner "F2. responder role → the instruction grants autonomous replies"
jq '.role = "responder"' "$ALICE_CFG/config.json" > "$ALICE_CFG/config.json.tmp" \
  && mv "$ALICE_CFG/config.json.tmp" "$ALICE_CFG/config.json"
out=$( unset BEAMS_DISABLE_WATCH_ON_BOOT
       export CLAUDE_CODE_SESSION_ID=boot-sess CLAUDE_PLUGIN_ROOT="$PLUGIN"
       printf '{"source":"startup"}' | bash "$PLUGIN/hooks/check-on-start.sh" 2>/dev/null ) || true
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null) || ctx=""
printf '%s' "$ctx" | grep -q 'RESPONDER' || fail "responder role did not grant autonomous replies"
printf '%s' "$ctx" | grep -q 'destructive' || fail "responder grant lost its destructive-action wall"
jq 'del(.role)' "$ALICE_CFG/config.json" > "$ALICE_CFG/config.json.tmp" \
  && mv "$ALICE_CFG/config.json.tmp" "$ALICE_CFG/config.json"
pass "responder role grants autonomous replies (with the destructive-ask wall)"

# ---------------------------------------------------------------------------
banner "G. source=compact/clear → no arm instruction (monitors survive in-process)"
for src in compact clear; do
  out=$( unset BEAMS_DISABLE_WATCH_ON_BOOT
         export CLAUDE_CODE_SESSION_ID=boot-sess CLAUDE_PLUGIN_ROOT="$PLUGIN"
         printf '{"source":"%s"}' "$src" | bash "$PLUGIN/hooks/check-on-start.sh" 2>/dev/null ) || true
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null) || ctx=""
  printf '%s' "$ctx" | grep -q 'beams doorbell' && fail "$src re-emitted the arm instruction" || true
done
pass "compact + clear: instruction suppressed (no duplicate doorbells)"

# G queued TWO async watcher bounces (compact + clear). Waiting for any one
# new pid is raceable — a still-in-flight restart can spawn a daemon right
# after our stop, which H would mis-read as "opt-out started a watcher".
# Drain instead: keep stopping whatever live daemon appears until the
# population stays quiet for 2 consecutive seconds (or 30s cap). (The cat is
# `|| p=""`-guarded: mid-bounce the pid file does not exist, and an unmatched
# glob + pipefail would otherwise kill the whole script under set -e.)
quiet=0; t=0
while [ "$quiet" -lt 4 ] && [ "$t" -lt 60 ]; do
  p=$(cat "$ALICE_CFG"/state/*/watcher.pid 2>/dev/null | head -1) || p=""
  case "$p" in ''|*[!0-9]*) p="" ;; esac
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    run_as "$ALICE_CFG" watch stop >/dev/null 2>&1 || true
    quiet=0
  else
    quiet=$((quiet+1))
  fi
  sleep 0.5; t=$((t+1))
done

# ---------------------------------------------------------------------------
banner "H. BEAMS_DISABLE_WATCH_ON_BOOT=1 → no watcher, no instruction"
out=$( export CLAUDE_CODE_SESSION_ID=boot-sess CLAUDE_PLUGIN_ROOT="$PLUGIN" BEAMS_DISABLE_WATCH_ON_BOOT=1
       printf '{"source":"startup"}' | bash "$PLUGIN/hooks/check-on-start.sh" 2>/dev/null ) || true
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null) || ctx=""
printf '%s' "$ctx" | grep -q 'beams doorbell' && fail "opt-out still emitted the arm instruction" || true
sleep 1
p=$(cat "$ALICE_CFG"/state/*/watcher.pid 2>/dev/null | head -1) || p=""
if [ -n "$p" ]; then
  case "$p" in
    (*[!0-9]*) : ;;
    (*) kill -0 "$p" 2>/dev/null && fail "opt-out still started a watcher (pid=$p)" || true ;;
  esac
fi
pass "opt-out: silent, watcher-less"

# ---------------------------------------------------------------------------
banner "I. end to end: real send → watcher poll → wake.log line"
run_as "$CFG_B" init "$SHARED" >/dev/null
run_as "$CFG_B" name bob       >/dev/null
run_as "$CFG_B" join r28-beam  >/dev/null
runas boot-sess join r28-beam  >/dev/null
( export BEAMS_CONFIG_DIR="$ALICE_CFG"
  "$PLUGIN/lib/watch.sh" "start 1 --on-message bash $PLUGIN/lib/on-message.sh" ) >/dev/null
sleep 1
run_as "$CFG_B" send r28-beam alice "doorbell end to end" >/dev/null
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  grep -qF 'from bob — doorbell end to end' "$ALICE_CFG/wake.log" 2>/dev/null && { ok=1; break; }
done
if [ "$ok" != 1 ]; then
  red "  wake.log:";        cat "$ALICE_CFG/wake.log" 2>/dev/null | sed 's/^/    /' || true
  red "  watcher.log tail:"; tail -n 20 "$ALICE_CFG"/state/*/watcher.log 2>/dev/null | sed 's/^/    /' || true
  red "  on-message.log:";   tail -n 20 "$ALICE_CFG"/state/*/on-message.log 2>/dev/null | sed 's/^/    /' || true
  fail "no wake line landed for a real send"
fi
run_as "$ALICE_CFG" watch stop >/dev/null 2>&1 || true
pass "real send produced a wake line within the poll window"

green ""
green "round-28 PASS: the wake-file doorbell appends sanitized one-line events; SessionStart truncates, re-arms the watcher, and instructs the Monitor; opt-outs stay silent; end-to-end send→wake works"
