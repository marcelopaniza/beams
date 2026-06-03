#!/usr/bin/env bash
# Round 26 — actionable onboarding errors. Two dead-ends become one-step fixes:
#   E. A /beams:* command in a FRESH project (no identity here yet) used to die
#      "not initialised — run /beams:start first" with no path, leaving the user
#      (or the model) to hunt for the shared folder. It now surfaces the shared
#      folder the user's OTHER identities already use + the exact /beams:init
#      command.
#   F. /beams:send <name> where <name> is a PEER (a session), not a beam, used to
#      die "beam '<name>' does not exist on the shared folder". It now detects
#      that <name> is a session on a beam you share and shows the correct
#      "/beams:send <beam> <name> ..." form.

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r26.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"          # sandbox the whole ~/.config/beams tree
export HOME="$TMP/home"                     # keep legacy-config detection inert
mkdir -p "$XDG_CONFIG_HOME" "$HOME"
export BEAMS_DISABLE_WATCH_ON_BOOT=1
SHARED="$TMP/share"; mkdir -p "$SHARED"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# Run a lib command as a session in a project, no BEAMS_CONFIG_DIR override
# (so real per-project identity resolution + config_require are exercised).
run() {  # $1=sid $2=proj $3=lib $4..=args
  ( unset BEAMS_CONFIG_DIR TMUX TMUX_PANE TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$2"
    mkdir -p "$2"
    "$PLUGIN/lib/$3.sh" "${@:4}" )
}

# ── E. fresh project → actionable 'not initialised' with the known shared path ─
banner "E. a command in a fresh project surfaces the known shared path + init cmd"
P1="$TMP/proj-one"
run sid-1 "$P1" init "$SHARED" >/dev/null
run sid-1 "$P1" name alice     >/dev/null      # now the machine knows a shared_path
P2="$TMP/proj-two"                              # a DIFFERENT project, no identity here
# A bare beams command here must fail, but with the actionable hint (not the old
# pathless "run /beams:start first"). Capture stderr only.
err=$( run sid-2 "$P2" join someroom 2>&1 1>/dev/null ) && fail "join in a fresh project should fail" || true
printf '%s' "$err" | grep -qF "$SHARED" \
  || { printf '%s\n' "$err" | sed 's/^/    /'; fail "the hint did not surface the known shared path ($SHARED)"; }
printf '%s' "$err" | grep -q "beams:init" \
  || { printf '%s\n' "$err" | sed 's/^/    /'; fail "the hint did not show the /beams:init command"; }
pass "fresh project surfaces the known shared path + /beams:init command"

# Sanity: with NO identities anywhere, it falls back to the original message.
banner "E2. with no identities at all, the original guidance is unchanged"
TMP2=$(mktemp -d /tmp/beams-test-r26b.XXXXXX)
err2=$( unset BEAMS_CONFIG_DIR; export XDG_CONFIG_HOME="$TMP2/xdg" HOME="$TMP2/home" \
        CLAUDE_CODE_SESSION_ID=sid-x CLAUDE_PROJECT_DIR="$TMP2/proj"
        mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$TMP2/proj"
        "$PLUGIN/lib/join.sh" anyroom 2>&1 1>/dev/null ) && { rm -rf "$TMP2"; fail "join with no config should fail"; } || true
rm -rf "$TMP2"
printf '%s' "$err2" | grep -q "run /beams:start first" \
  || { printf '%s\n' "$err2" | sed 's/^/    /'; fail "no-identity case should keep the original 'run /beams:start first' guidance"; }
pass "no-identity case keeps the original guidance (no false shared-path hint)"

# ── F. send to a PEER name (not a beam) → suggests the right shared-beam form ──
banner "F. send <peer> (not a beam) suggests the correct /beams:send <beam> <peer>"
PX="$TMP/proj-x"
run sa "$PX" init "$SHARED" >/dev/null
run sa "$PX" name aaa       >/dev/null
run sa "$PX" create room    >/dev/null
run sa "$PX" join room      >/dev/null         # 'aaa' is now a member of 'room'
run sb "$PX" name bbb       >/dev/null          # sibling identity in the same project
run sb "$PX" join room      >/dev/null          # 'bbb' subscribes to 'room'
# bbb tries to message peer 'aaa' as if it were a beam: `send aaa <body>`.
err=$( run sb "$PX" send aaa hello there 2>&1 1>/dev/null ) && fail "send to a peer-name should fail (no beam 'aaa')" || true
printf '%s' "$err" | grep -q "session named 'aaa'" \
  || { printf '%s\n' "$err" | sed 's/^/    /'; fail "did not detect that 'aaa' is a peer session"; }
printf '%s' "$err" | grep -q "room" \
  || { printf '%s\n' "$err" | sed 's/^/    /'; fail "did not name the shared beam 'room'"; }
printf '%s' "$err" | grep -q "beams:send room aaa" \
  || { printf '%s\n' "$err" | sed 's/^/    /'; fail "did not show the corrected '/beams:send room aaa' command"; }
pass "send to a peer-name suggests the correct shared-beam command"

# Sanity: a genuinely missing beam (not a peer) still gets the plain error.
banner "F2. a truly unknown beam (not a peer) keeps the plain 'does not exist' error"
err3=$( run sb "$PX" send nosuchbeam hello world 2>&1 1>/dev/null ) && fail "send to a missing beam should fail" || true
printf '%s' "$err3" | grep -q "does not exist on the shared folder" \
  || { printf '%s\n' "$err3" | sed 's/^/    /'; fail "unknown non-peer beam should keep the plain error"; }
printf '%s' "$err3" | grep -qv "session named" 2>/dev/null || true
pass "an unknown non-peer beam keeps the plain 'does not exist' error"

green ""
green "round-26 PASS: a fresh project surfaces the known shared folder + /beams:init, and send-to-a-peer suggests the correct /beams:send <shared-beam> <peer> form — instead of dead-end errors"
