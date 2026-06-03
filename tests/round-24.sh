#!/usr/bin/env bash
# Round 24 — a BOUND session must resolve its identity from ANY working dir.
#
# Regression test for the "not initialised from a subdirectory" bug. A session
# binds to a durable identity while CLAUDE_PROJECT_DIR points at the project
# root, but later a skill runs from a SUBDIRECTORY (or after a Claude restart
# with CLAUDE_PROJECT_DIR unset). The old resolver re-derived the project key
# from the volatile cwd ($PWD) on every call, looked under the wrong project,
# and every command died with "not initialised" — though the identity was right
# there on disk. (This is exactly what broke /beams:send in a live session whose
# shell cwd had drifted into a subdir.)
#
# Fix (lib/common.sh _resolve_config_dir + bind_session):
#   - bind records the project key in sessions/<id>/bound_project;
#   - resolution prefers that recorded key, then the cwd-derived key, then walks
#     cwd ancestors to the nearest project that actually holds the identity.
# This round proves:
#   (A) root cwd still resolves to the identity (the fast path is unchanged),
#   (B) the bind recorded bound_project,
#   (C) from a SUBDIRECTORY with CLAUDE_PROJECT_DIR unset, resolution still finds
#       the identity,
#   (C2) even a legacy (name-only) bind with NO recorded key recovers, via the
#       ancestor walk-up,
#   (D) from an UNRELATED cwd with CLAUDE_PROJECT_DIR unset, resolution still
#       finds it via the recorded project key,
#   (E) end-to-end: the exact command that used to fail (`name <same>`) now
#       succeeds from a subdirectory instead of dying "not initialised".

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r24.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"         # sandbox the whole ~/.config/beams tree
export HOME="$TMP/home"                    # keep legacy-config detection inert
PROJ="$TMP/proj"                           # the "project root"
SUB="$PROJ/lib/deep"                       # a subdirectory inside the project
OUTSIDE="$TMP/elsewhere"                   # a cwd with no relation to the project
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$PROJ" "$SUB" "$OUTSIDE"
export CLAUDE_PROJECT_DIR="$PROJ"          # set at bind time (the normal case)
export BEAMS_DISABLE_WATCH_ON_BOOT=1       # never spawn real daemons in the test
SHARED="$TMP/share"; mkdir -p "$SHARED"
BASE="$XDG_CONFIG_HOME/beams"
PKEY=$(printf '%s' "$PROJ" | sed 's,/,-,g')
IDENT="$BASE/projects/$PKEY/identities"
SID=sess-A
NAME=alice

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# Run a lib command as the session, project root in scope (the bind-time case).
run_root() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$SID"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }

# Resolve BEAMS_CONFIG_DIR exactly as the libs do, from cwd $1, with
# CLAUDE_PROJECT_DIR per $2 (a path, or the literal "unset").
resolve_from() {
  ( cd "$1" || exit 1
    set +eu                                # this is a resolution probe, not an assertion
    unset BEAMS_CONFIG_DIR
    if [ "$2" = unset ]; then unset CLAUDE_PROJECT_DIR; else export CLAUDE_PROJECT_DIR="$2"; fi
    export CLAUDE_CODE_SESSION_ID="$SID"
    . "$PLUGIN/lib/common.sh"
    printf '%s' "$BEAMS_CONFIG_DIR" )
}

# Run a real lib command from cwd $1 with CLAUDE_PROJECT_DIR unset (the bug
# trigger), as the bound session.
cmd_from() { ( cd "$1" || exit 1; unset BEAMS_CONFIG_DIR CLAUDE_PROJECT_DIR; export CLAUDE_CODE_SESSION_ID="$SID"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }

banner "0. bind identity '$NAME' from the project root"
run_root init "$SHARED" >/dev/null
run_root name "$NAME"    >/dev/null
[ -f "$IDENT/$NAME/config.json" ]                              || fail "identity '$NAME' was not created"
[ "$(cat "$BASE/sessions/$SID/bound" 2>/dev/null)" = "$NAME" ] || fail "bound pointer not written"
pass "identity '$NAME' bound by $SID"

banner "A. root cwd still resolves to the identity (fast path unchanged)"
A=$(resolve_from "$PROJ" "$PROJ")
[ "$A" = "$IDENT/$NAME" ] || fail "root resolution changed: got '$A', want '$IDENT/$NAME'"
pass "root cwd resolves to the identity"

banner "B. bind recorded the project key (bound_project)"
got=$(cat "$BASE/sessions/$SID/bound_project" 2>/dev/null || true)
[ "$got" = "$PKEY" ] || fail "bound_project not recorded (got '$got', want '$PKEY')"
pass "bound_project recorded as $PKEY"

banner "C. from a SUBDIRECTORY, CLAUDE_PROJECT_DIR unset → still resolves"
C=$(resolve_from "$SUB" unset)
[ "$C" = "$IDENT/$NAME" ] || fail "subdir resolution failed: got '$C', want '$IDENT/$NAME' (the not-initialised-from-subdir bug)"
pass "subdirectory cwd still resolves to the identity"

banner "C2. legacy bind (name-only, no recorded key) still recovers via walk-up"
rm -f "$BASE/sessions/$SID/bound_project"                      # simulate a pre-fix pointer
C2=$(resolve_from "$SUB" unset)
[ "$C2" = "$IDENT/$NAME" ] || fail "walk-up did not recover a legacy name-only bind from a subdir: got '$C2'"
printf '%s' "$PKEY" > "$BASE/sessions/$SID/bound_project"      # restore for D
pass "legacy name-only bind recovers from a subdirectory via walk-up"

banner "D. from an UNRELATED cwd, CLAUDE_PROJECT_DIR unset → resolves via recorded key"
D=$(resolve_from "$OUTSIDE" unset)
[ "$D" = "$IDENT/$NAME" ] || fail "unrelated-cwd resolution failed: got '$D', want '$IDENT/$NAME' (recorded project key not honoured)"
pass "unrelated cwd still resolves via the recorded project key"

banner "E. end-to-end: the command that used to fail now succeeds from a subdir"
cmd_from "$SUB" name "$NAME" >/dev/null 2>&1 \
  || fail "'name $NAME' from a subdirectory still dies 'not initialised' — the user-visible bug"
pass "a real command resolves the bound identity from a subdirectory"

green ""
green "round-24 PASS: a bound session resolves its identity from any cwd — recorded project key first, then cwd-derived, then nearest ancestor — so a subdir cwd / unset CLAUDE_PROJECT_DIR no longer means 'not initialised'"
