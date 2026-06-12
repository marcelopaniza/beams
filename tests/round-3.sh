#!/usr/bin/env bash
# Round 3: tests for per-terminal identity resolution via CLAUDE_CODE_SESSION_ID.
set -euo pipefail
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # hermetic: join/name/init must not autostart watchers in this round

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR=$(mktemp -d /tmp/beams-test3.XXXXXX)
SHARED="$TMPDIR/share"
HOME_REAL="$HOME"
FAKE_HOME="$TMPDIR/home"
PROJ="$TMPDIR/proj"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

mkdir -p "$SHARED" "$FAKE_HOME/.config" "$PROJ"

# Run a script with a synthetic Claude Code env. No BEAMS_CONFIG_DIR override —
# we want to test the auto-resolution.
run_as_term() {
  local term_id="$1"; shift
  ( unset BEAMS_CONFIG_DIR
    export CLAUDE_CODE_SESSION_ID="$term_id"
    export HOME="$FAKE_HOME"
    export XDG_CONFIG_HOME="$FAKE_HOME/.config"
    export CLAUDE_PROJECT_DIR="$PROJ"
    "$PLUGIN/lib/$1.sh" "${@:2}" )
}

banner "1. two terminals → two different config dirs (no BEAMS_CONFIG_DIR override)"
run_as_term aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa init "$SHARED" >/dev/null
run_as_term bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb init "$SHARED" >/dev/null

cfg_a="$FAKE_HOME/.config/beams/sessions/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa/config.json"
cfg_b="$FAKE_HOME/.config/beams/sessions/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb/config.json"
[ -f "$cfg_a" ] && [ -f "$cfg_b" ] || fail "expected per-terminal config files; got: $(ls -R $FAKE_HOME/.config 2>&1)"

sid_a=$(jq -r '.session_id' "$cfg_a")
sid_b=$(jq -r '.session_id' "$cfg_b")
[ "$sid_a" != "$sid_b" ] || fail "two terminals should mint distinct UUIDs; both got $sid_a"
pass "terminal A sid=$sid_a, terminal B sid=$sid_b (distinct)"

banner "2. /beams:name binds each terminal to its own durable identity; naming A does NOT touch B"
run_as_term aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa name terminal-A >/dev/null
run_as_term bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb name terminal-B >/dev/null

# Naming migrates each scratch config into a durable, name-keyed identity that
# survives a restart; the per-session dir keeps only a 'bound' pointer.
pkey=$(printf '%s' "$PROJ" | sed 's,/,-,g')
ident="$FAKE_HOME/.config/beams/projects/$pkey/identities"
ida="$ident/terminal-A/config.json"
idb="$ident/terminal-B/config.json"
[ -f "$ida" ] && [ -f "$idb" ]         || fail "naming should create durable identities; got: $(ls -R "$ident" 2>&1)"
[ ! -f "$cfg_a" ] && [ ! -f "$cfg_b" ] || fail "scratch configs should have migrated away"
[ "$(cat "$FAKE_HOME/.config/beams/sessions/aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa/bound")" = terminal-A ] || fail "A not bound to terminal-A"
[ "$(cat "$FAKE_HOME/.config/beams/sessions/bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb/bound")" = terminal-B ] || fail "B not bound to terminal-B"
name_a=$(jq -r '.session_name' "$ida")
name_b=$(jq -r '.session_name' "$idb")
[ "$name_a" = "terminal-A" ] || fail "A's name should be terminal-A, got: $name_a"
[ "$name_b" = "terminal-B" ] || fail "B's name should be terminal-B, got: $name_b"
[ "$(jq -r '.session_id' "$ida")" = "$sid_a" ] || fail "A's identity lost its original UUID"
[ "$(jq -r '.session_id' "$idb")" = "$sid_b" ] || fail "B's identity lost its original UUID"
pass "independent identities (A=$name_a, B=$name_b), UUIDs preserved, no cross-rename"

banner "3. claude_code_session_id (the creator) is recorded in each identity config"
cc_a=$(jq -r '.claude_code_session_id' "$ida")
cc_b=$(jq -r '.claude_code_session_id' "$idb")
[ "$cc_a" = "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa" ] || fail "A's recorded cc-sid wrong: $cc_a"
[ "$cc_b" = "bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb" ] || fail "B's recorded cc-sid wrong: $cc_b"
pass "claude_code_session_id is captured in each identity config"

banner "4. legacy single-config triggers hint"
mkdir -p "$FAKE_HOME/.config/beams"
echo '{"version":1,"shared_path":"/x","session_id":"legacy","session_name":"legacy","beams":[]}' \
  > "$FAKE_HOME/.config/beams/config.json"
err=$(run_as_term cccccccc-3333-3333-3333-cccccccccccc status 2>&1 || true)
echo "$err" | grep -q "legacy single-config" || fail "expected legacy hint; got: $err"
echo "$err" | grep -q "/beams:admin init"           || fail "expected init suggestion in hint"
pass "legacy hint shown when current terminal lacks a config"

banner "5. explicit BEAMS_CONFIG_DIR override beats CLAUDE_CODE_SESSION_ID"
custom="$TMPDIR/custom"
( unset CLAUDE_CODE_SESSION_ID
  BEAMS_CONFIG_DIR="$custom" HOME="$FAKE_HOME" \
    "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null )
[ -f "$custom/config.json" ] || fail "BEAMS_CONFIG_DIR override didn't write to $custom"
pass "BEAMS_CONFIG_DIR override respected"

# Same with CLAUDE_CODE_SESSION_ID also set — override still wins.
custom2="$TMPDIR/custom2"
BEAMS_CONFIG_DIR="$custom2" CLAUDE_CODE_SESSION_ID="zzz" HOME="$FAKE_HOME" \
  "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null
[ -f "$custom2/config.json" ] || fail "override didn't win over CLAUDE_CODE_SESSION_ID"
pass "explicit override beats CLAUDE_CODE_SESSION_ID"

banner "6. no Claude env AND no terminal-pane env → per-project key"
# Must unset the terminal-pane envs (TMUX_PANE / TERM_SESSION_ID / WT_SESSION /
# WINDOWID) too, otherwise the resolver short-circuits to terminals/<pane>
# when this test is run inside tmux or iTerm.
proj="$TMPDIR/proj-1"
mkdir -p "$proj"
( unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR TMUX_PANE TERM_SESSION_ID WT_SESSION
  cd "$proj"
  export HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config"
  "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null )
expected_dir="$FAKE_HOME/.config/beams/projects/$(printf '%s' "$proj" | sed 's,/,-,g')"
[ -f "$expected_dir/config.json" ] || fail "expected per-project fallback at $expected_dir"
pass "per-project fallback used when no Claude env and no terminal-pane env"

banner "7. TMUX_PANE present, no Claude env → per-pane terminals/ key (sanitised)"
( unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR TERM_SESSION_ID WT_SESSION
  export TMUX_PANE="%42"
  export HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config"
  "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null )
# '%' is path-unsafe and gets rewritten to '_' by the resolver.
pane_dir="$FAKE_HOME/.config/beams/terminals/_42"
[ -f "$pane_dir/config.json" ] \
  || fail "expected per-pane fallback at $pane_dir; got: $(find $FAKE_HOME/.config/beams/terminals -maxdepth 2 -type f 2>&1)"
pass "TMUX_PANE drove per-pane fallback to terminals/_42"

banner "8. two distinct TMUX_PANE values → two distinct config dirs"
( unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR TERM_SESSION_ID WT_SESSION
  export TMUX_PANE="%100"
  export HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config"
  "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null )
( unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR TERM_SESSION_ID WT_SESSION
  export TMUX_PANE="%200"
  export HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config"
  "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null )
sid_p1=$(jq -r '.session_id' "$FAKE_HOME/.config/beams/terminals/_100/config.json")
sid_p2=$(jq -r '.session_id' "$FAKE_HOME/.config/beams/terminals/_200/config.json")
[ -n "$sid_p1" ] && [ -n "$sid_p2" ] || fail "missing per-pane config files: _100=$sid_p1 _200=$sid_p2"
[ "$sid_p1" != "$sid_p2" ] || fail "two TMUX_PANE values should mint distinct UUIDs; both got $sid_p1"
pass "TMUX_PANE %100 sid=$sid_p1, %200 sid=$sid_p2 (distinct)"

banner "9. traversal-prone TMUX_PANE values are rejected and fall through to per-project key"
# After tr's allowlist (A-Za-z0-9._-), '.', '..', '-flag', '.hidden', and
# '....-..' all SURVIVE — the resolver must reject them at a second-layer
# check or an attacker who controls TMUX_PANE could write outside terminals/
# (clobbering the legacy config) or quietly share identity by collapsing two
# distinct values onto the same on-disk dir.
TRAVERSAL_HOME="$TMPDIR/home9"
mkdir -p "$TRAVERSAL_HOME/.config"
proj9="$TMPDIR/proj-9"
mkdir -p "$proj9"
expected9="$TRAVERSAL_HOME/.config/beams/projects/$(printf '%s' "$proj9" | sed 's,/,-,g')"
for bad in '..' '.' '../etc' '-flag' '.hidden' '....-..'; do
  rm -rf "$TRAVERSAL_HOME/.config/beams"
  ( unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR TERM_SESSION_ID WT_SESSION
    export TMUX_PANE="$bad"
    cd "$proj9"
    export HOME="$TRAVERSAL_HOME" XDG_CONFIG_HOME="$TRAVERSAL_HOME/.config"
    "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null )
  # Sanitised value — what the on-disk dir name WOULD be if the input passed the rejection.
  sanitised=$(printf '%s' "$bad" | tr -c 'A-Za-z0-9._-' '_')
  if [ -f "$TRAVERSAL_HOME/.config/beams/terminals/$sanitised/config.json" ]; then
    fail "TMUX_PANE='$bad' (→ '$sanitised') was NOT rejected — wrote terminals/$sanitised/"
  fi
  # Must have fallen through to the per-project path.
  [ -f "$expected9/config.json" ] || fail "TMUX_PANE='$bad': expected fallback at $expected9; got: $(find $TRAVERSAL_HOME/.config/beams -maxdepth 4 -type f 2>&1)"
done
pass "rejected: .. / . / ../etc / -flag / .hidden / ....-.. (all fell through to per-project key)"

green ""
green "ALL ROUND-3 TESTS PASSED"
