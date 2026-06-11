#!/usr/bin/env bash
# Round 27 — the doorbell survives session churn: the identity-scoped live
# pointer + the on-message /health liveness gate + SessionStart port-file prune.
#
# The bug this guards against: the watcher is a long-lived, per-identity
# singleton, but channel/on-message.sh used to resolve the target server from
# the watcher's OWN frozen CLAUDE_CODE_SESSION_ID — baked in when the watcher
# first started. Channel servers are per-session and come and go, so once the
# arming session ended, every POST forever targeted that dead session's (stale)
# port: the doorbell silently went dead while still "running". The fix:
#   * SessionStart publishes the CURRENT session id to an identity-scoped
#     pointer ($BEAMS_CONFIG_DIR/channel.session); on-message.sh reads THAT
#     first and only falls back to its frozen env id.
#   * on-message.sh /health-gates the resolved port and self-heals a stale
#     rendezvous file (curl exit 7 == connection refused == unlink it).
#   * SessionStart prunes refused .port files so they don't accumulate.
# Cases:
#   A. pointer overrides a frozen/dead env id  -> wakes the pointer's session
#   B. no pointer                              -> falls back to the env id (compat)
#   C. pointer -> dead port                    -> no event, stale file unlinked
#   D. SessionStart                            -> writes the pointer + prunes refused

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
NODE="${NODE:-$(command -v node || echo /usr/bin/node)}"
TMP=$(mktemp -d /tmp/beams-test-r27.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"   # sandbox the rendezvous + identity tree
export HOME="$TMP/home"
mkdir -p "$XDG_CONFIG_HOME" "$HOME"
unset CLAUDE_CODE_SESSION_ID        # never inherit the real session's id
unset BEAMS_CONFIG_DIR              # never inherit a real binding
CHANDIR="$XDG_CONFIG_HOME/beams/channels"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

SERVERS=(); KEEPERS=(); PIPES=(); WPIDS=()
cleanup() {
  local p
  for p in "${SERVERS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  for p in "${WPIDS[@]:-}";   do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  for p in "${KEEPERS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  for p in "${PIPES[@]:-}";   do [ -n "$p" ] && rm -f "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# start_server <sid|""> <token|""> <out_file> <err_file> -> echoes server pid
start_server() {
  local sid="$1" token="$2" out="$3" err="$4"
  local pipe; pipe=$(mktemp -u "$TMP/pipe.XXXXXX"); mkfifo "$pipe"; PIPES+=("$pipe")
  ( sleep 120 ) > "$pipe" & KEEPERS+=("$!")        # hold stdin open so the server stays up
  local e=(env)
  if [ -n "$sid" ]; then e+=("CLAUDE_CODE_SESSION_ID=$sid"); else e+=(-u CLAUDE_CODE_SESSION_ID); fi
  [ -n "$token" ] && e+=("BEAMS_CHANNEL_TOKEN=$token")
  "${e[@]}" "$NODE" "$PLUGIN/channel/beams-channel.mjs" < "$pipe" > "$out" 2>"$err" &
  local pid=$!; SERVERS+=("$pid"); echo "$pid"
}

healthy() { [ "$(curl -s -m 2 "http://127.0.0.1:$1/health" 2>/dev/null || true)" = ok ]; }
count_events() { grep -c 'notifications/claude/channel' "$1" 2>/dev/null || true; }
wait_for_portfile() { local f="$1" i=0; while [ "$i" -lt 50 ]; do [ -r "$f" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

command -v curl >/dev/null 2>&1 || { echo "  (skipped — no curl on this host)"; exit 0; }
[ -x "$NODE" ] || NODE=$(command -v node || true)
[ -n "$NODE" ] || { echo "  (skipped — no node on this host)"; exit 0; }

# ---------------------------------------------------------------------------
banner "A. the identity pointer overrides a frozen/dead env id"
TOKEN="tok-$$"
start_server sess-LIVE "$TOKEN" "$TMP/LIVE.out" "$TMP/LIVE.err" >/dev/null
PF_LIVE="$CHANDIR/sess-LIVE.port"
wait_for_portfile "$PF_LIVE" || fail "no rendezvous file for sess-LIVE; err: $(cat "$TMP/LIVE.err")"
healthy "$(cat "$PF_LIVE")" || fail "sess-LIVE not healthy"

# An identity dir whose pointer names the LIVE session — but the watcher's env
# is frozen to sess-DEAD (no server, no port file: the exact failure mode).
CFG="$TMP/identity"; mkdir -p "$CFG"
printf '%s\n' sess-LIVE > "$CFG/channel.session"

PRE=$(count_events "$TMP/LIVE.out")
env CLAUDE_CODE_SESSION_ID=sess-DEAD BEAMS_CONFIG_DIR="$CFG" BEAMS_CHANNEL_TOKEN="$TOKEN" \
  BEAMS_BEAM=all BEAMS_FROM=jose BEAMS_PREVIEW="wake the live session" \
  bash "$PLUGIN/channel/on-message.sh"
sleep 0.3
POST=$(count_events "$TMP/LIVE.out")
[ "$POST" -gt "$PRE" ] || fail "pointer ignored: sess-DEAD env id won, sess-LIVE not woken (pre=$PRE post=$POST)"
grep -q '"wake the live session"' "$TMP/LIVE.out" || fail "woke sess-LIVE but lost the message content"
pass "on-message.sh followed the pointer to sess-LIVE despite a frozen sess-DEAD env id"

# ---------------------------------------------------------------------------
banner "B. with no pointer, on-message.sh falls back to the env id (compat)"
rm -f "$CFG/channel.session"        # no pointer present
PRE=$(count_events "$TMP/LIVE.out")
env CLAUDE_CODE_SESSION_ID=sess-LIVE BEAMS_CONFIG_DIR="$CFG" BEAMS_CHANNEL_TOKEN="$TOKEN" \
  BEAMS_BEAM=all BEAMS_FROM=ze BEAMS_PREVIEW="fallback path still works" \
  bash "$PLUGIN/channel/on-message.sh"
sleep 0.3
POST=$(count_events "$TMP/LIVE.out")
[ "$POST" -gt "$PRE" ] || fail "fallback broke: pointer-less run did not wake sess-LIVE (pre=$PRE post=$POST)"
pass "no pointer → resolved via CLAUDE_CODE_SESSION_ID (round-21 behavior preserved)"

# ---------------------------------------------------------------------------
banner "C. a dead target is health-gated (no event) and its stale file unlinked"
# Make a guaranteed-refused port: bind a server, learn its port, kill it.
GPID=$(start_server sess-GONE "$TOKEN" "$TMP/GONE.out" "$TMP/GONE.err")
PF_GONE="$CHANDIR/sess-GONE.port"
wait_for_portfile "$PF_GONE" || fail "no rendezvous file for sess-GONE"
DEAD_PORT=$(cat "$PF_GONE")
kill "$GPID" 2>/dev/null || true
i=0; while [ "$i" -lt 30 ]; do healthy "$DEAD_PORT" || break; sleep 0.1; i=$((i+1)); done
healthy "$DEAD_PORT" && fail "sess-GONE server still alive on $DEAD_PORT after kill"
# Re-plant a STALE rendezvous file (simulating a non-graceful exit that left it).
printf '%s\n' "$DEAD_PORT" > "$PF_GONE"
printf '%s\n' sess-GONE > "$CFG/channel.session"

PRE_LIVE=$(count_events "$TMP/LIVE.out")
env CLAUDE_CODE_SESSION_ID=sess-DEAD BEAMS_CONFIG_DIR="$CFG" BEAMS_CHANNEL_TOKEN="$TOKEN" \
  BEAMS_BEAM=all BEAMS_FROM=mallory BEAMS_PREVIEW="should reach nobody" \
  bash "$PLUGIN/channel/on-message.sh"
sleep 0.3
[ "$(count_events "$TMP/LIVE.out")" = "$PRE_LIVE" ] || fail "a dead-target POST leaked to a live server"
[ -e "$PF_GONE" ] && fail "stale rendezvous file survived a connection-refused probe (no self-heal)" || true
pass "dead target: no channel event, and the refused .port file was unlinked"

# ---------------------------------------------------------------------------
banner "D. SessionStart publishes the pointer and prunes a refused .port"
command -v jq >/dev/null 2>&1 || { echo "  (D skipped — no jq)"; green ""; green "round-27 PASS (A–C)"; exit 0; }
SHARED="$TMP/share"; mkdir -p "$SHARED"
export CLAUDE_PROJECT_DIR="$TMP/proj"; mkdir -p "$CLAUDE_PROJECT_DIR"
# Create + bind an identity 'alice' to a known session id via the real CLIs.
runas() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
runas boot-sess init "$SHARED" >/dev/null
runas boot-sess name alice      >/dev/null
ALICE_CFG=$(find "$XDG_CONFIG_HOME/beams/projects" -type d -name alice | head -1)
[ -n "$ALICE_CFG" ] || fail "could not locate alice's identity dir"
[ ! -e "$ALICE_CFG/channel.session" ] || fail "pointer existed before the hook ran"

# Plant one refused .port (to be pruned) and keep sess-LIVE's healthy one (kept).
echo "$DEAD_PORT" > "$CHANDIR/sess-STALE.port"
LIVE_KEPT="$CHANDIR/sess-LIVE.port"; [ -e "$LIVE_KEPT" ] || fail "sess-LIVE.port vanished before D"

# Fire the SessionStart hook as boot-sess WITH the doorbell armed (autowire on,
# watch-on-boot enabled). It auto-resolves alice (the single bound identity),
# writes the pointer, backgrounds the prune, and spawns a watcher we then kill.
( unset BEAMS_DISABLE_WATCH_ON_BOOT
  export CLAUDE_CODE_SESSION_ID=boot-sess CLAUDE_PLUGIN_ROOT="$PLUGIN" \
         CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" BEAMS_CHANNEL_AUTOWIRE=1 \
         BEAMS_NOTIFIER_CMD=true
  bash "$PLUGIN/hooks/check-on-start.sh" </dev/null >/dev/null 2>&1 ) || true

# Record any watcher the hook spawned so cleanup kills it.
WP=$(find "$ALICE_CFG" -name watcher.pid -exec cat {} \; 2>/dev/null | head -1 || true)
case "$WP" in ''|*[!0-9]*) : ;; *) WPIDS+=("$WP") ;; esac

# Pointer written to alice's identity dir, naming this session.
[ -f "$ALICE_CFG/channel.session" ] || fail "hook did not publish the channel.session pointer"
[ "$(cat "$ALICE_CFG/channel.session")" = boot-sess ] || \
  fail "pointer names $(cat "$ALICE_CFG/channel.session"), expected boot-sess"

# Prune is backgrounded — give it up to ~3s to drop the refused file, keep the live one.
i=0; while [ "$i" -lt 30 ]; do [ -e "$CHANDIR/sess-STALE.port" ] || break; sleep 0.1; i=$((i+1)); done
[ -e "$CHANDIR/sess-STALE.port" ] && fail "refused .port was not pruned by SessionStart" || true
[ -e "$LIVE_KEPT" ] || fail "SessionStart pruned a HEALTHY server's .port file"
pass "SessionStart published the pointer (boot-sess) and pruned only the refused .port"

green ""
green "round-27 PASS: the identity pointer beats a frozen env id; pointer-less runs stay compatible; dead targets are health-gated and self-healed; SessionStart publishes the pointer and prunes refused rendezvous files"
