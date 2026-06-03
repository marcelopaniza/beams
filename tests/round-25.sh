#!/usr/bin/env bash
# Round 25 — disambiguation auto-bind by terminal anchor + automatic tab-title
# (sessionTitle), the v0.10.x "join smoother" work.
#
# Two user-visible promises:
#   (1) A fresh (unbound) session in a project with SEVERAL bindable identities
#       auto-binds SILENTLY only when it is 100% sure which one this is — i.e.
#       this exact terminal (a tmux/screen pane) bound one here before. The pane
#       id is recorded at bind time under projects/<p>/anchors/. With no matching
#       anchor it must NOT guess: it surfaces the list (covered in round-16); WITH
#       a matching anchor it rebinds to the right one with zero prompts.
#   (2) Whenever a session is bound, beams sets the Claude Code tab title to the
#       identity, so the user never types /rename by hand:
#         - SessionStart asserts sessionTitle on start/resume/auto-bind;
#         - a mid-session /beams:name leaves a marker that the next
#           UserPromptSubmit turns into a sessionTitle (the harness only renames a
#           live session from a hook, so a lib can't call /rename itself).
#
# Subtests:
#   A. multiple bindable + matching terminal anchor → silent auto-bind the RIGHT
#      one (+ tab title set).
#   B. multiple bindable + anchor present but NOT recorded → surface the list,
#      never guess, never bind.
#   C. a bound, idle SessionStart still asserts the tab title (no re-delivery).
#   D. a mid-session /beams:name retitles the tab on the NEXT UserPromptSubmit,
#      exactly once (marker is one-shot).

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r25.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg"          # sandbox the whole ~/.config/beams tree
export HOME="$TMP/home"                     # keep legacy-config detection inert
mkdir -p "$XDG_CONFIG_HOME" "$HOME"
export BEAMS_DISABLE_WATCH_ON_BOOT=1        # never spawn real daemons in the test
SHARED="$TMP/share"; mkdir -p "$SHARED"
BASE="$XDG_CONFIG_HOME/beams"
FAKE_TMUX="/tmp/fake-tmux-sock,4242,0"      # a stable, fake $TMUX (socket,serverpid,sess)

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

idents_of() { printf '%s/projects/%s/identities' \
  "$BASE" "$(printf '%s' "$1" | sed 's,/,-,g')"; }

# Bind an identity with NO terminal anchor (plain terminal — records nothing).
mk_plain() {  # $1=sid $2=name $3=proj
  ( unset BEAMS_CONFIG_DIR TMUX TMUX_PANE TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$3"
    mkdir -p "$3"
    "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null
    "$PLUGIN/lib/name.sh" "$2"      >/dev/null )
}
# Bind an identity FROM a specific tmux pane (records the terminal→identity anchor).
mk_anchored() {  # $1=sid $2=name $3=proj $4=pane
  ( unset BEAMS_CONFIG_DIR TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$3"
    export TMUX="$FAKE_TMUX" TMUX_PANE="$4"
    mkdir -p "$3"
    "$PLUGIN/lib/init.sh" "$SHARED" >/dev/null
    "$PLUGIN/lib/name.sh" "$2"      >/dev/null )
}
# Fire SessionStart as a fresh unbound session sitting in a specific tmux pane.
boot_anchored() {  # $1=sid $2=proj $3=pane
  ( unset BEAMS_CONFIG_DIR TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN"
    export TMUX="$FAKE_TMUX" TMUX_PANE="$3"
    printf '%s' '{"source":"startup"}' | "$PLUGIN/hooks/check-on-start.sh" )
}
# Fire SessionStart as a given (already-bound) session, no anchor, no unread.
boot_bound() {  # $1=sid $2=proj
  ( unset BEAMS_CONFIG_DIR TMUX TMUX_PANE TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN"
    printf '%s' '{"source":"startup"}' | "$PLUGIN/hooks/check-on-start.sh" )
}
# Fire UserPromptSubmit as a given session.
prompt_hook() {  # $1=sid $2=proj
  ( unset BEAMS_CONFIG_DIR TMUX TMUX_PANE TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN"
    printf '%s' '{}' | "$PLUGIN/hooks/check-messages.sh" )
}
# Run a lib command mid-"session" (e.g. /beams:name) as a session, no anchor.
run_as() {  # $1=sid $2=proj $3=lib $4..=args
  ( unset BEAMS_CONFIG_DIR TMUX TMUX_PANE TERM_SESSION_ID WT_SESSION STY WINDOW
    export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$2"
    mkdir -p "$2"
    "$PLUGIN/lib/$3.sh" "${@:4}" )
}

# ── A. matching terminal anchor → silent auto-bind the RIGHT identity ────────
banner "A. several identities, but THIS terminal bound one before → auto-bind it"
PA="$TMP/proj-a"
mk_plain    sid-a aaa "$PA"               # 'aaa' has no anchor
mk_anchored sid-b bbb "$PA" '%7'          # 'bbb' bound from pane %7 → anchor recorded
[ -d "$(dirname "$(idents_of "$PA")")/anchors" ] \
  || fail "bind from a tmux pane did not create the anchors/ registry"
rm -f "$(idents_of "$PA")/aaa/lease.json" "$(idents_of "$PA")/bbb/lease.json"  # both free
out=$(boot_anchored sid-fresh-a "$PA" '%7')   # a fresh session, SAME pane %7
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("auto-bound to \"bbb\"")' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "did not anchor-match → should have auto-bound to bbb"; }
echo "$out" | jq -e '.hookSpecificOutput.sessionTitle == "bbb"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "anchor auto-bind did not set the tab title"; }
[ "$(cat "$BASE/sessions/sid-fresh-a/bound" 2>/dev/null)" = bbb ] \
  || fail "anchor auto-bind did not write the bound pointer to bbb"
pass "matching anchor silently rebinds the right identity (bbb) + titles the tab"

# ── B. anchor present but NOT recorded → surface the list, never guess ───────
banner "B. several identities, anchor with no record → list, never auto-bind"
PB="$TMP/proj-b"
mk_plain sid-c aaa "$PB"
mk_plain sid-d bbb "$PB"
rm -f "$(idents_of "$PB")/aaa/lease.json" "$(idents_of "$PB")/bbb/lease.json"
out=$(boot_anchored sid-fresh-b "$PB" '%99')  # pane %99 — never bound anything here
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("aaa") and test("bbb")' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "unmatched anchor should surface BOTH identities, not guess"; }
[ -z "$(cat "$BASE/sessions/sid-fresh-b/bound" 2>/dev/null)" ] \
  || fail "must NOT auto-bind on an unmatched anchor"
pass "an unmatched anchor surfaces the choice (no guess, no bind)"

# ── C. a bound, idle SessionStart still asserts the tab title ────────────────
banner "C. bound session, nothing waiting → SessionStart sets the tab title"
PC="$TMP/proj-c"
mk_plain sid-e ccc "$PC"
out=$(boot_bound sid-e "$PC")
echo "$out" | jq -e '.hookSpecificOutput.sessionTitle == "ccc"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "bound idle SessionStart did not set the tab title"; }
echo "$out" | jq -e '(.hookSpecificOutput.additionalContext // "") == ""' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "bound idle SessionStart should carry no additionalContext"; }
pass "bound idle SessionStart titles the tab and delivers nothing else"

# ── D. a mid-session /beams:name retitles on the next UserPromptSubmit ───────
banner "D. mid-session /beams:name → next prompt sets the tab title (once)"
# sid-f is a brand-new (unbound) session; naming it binds a fresh identity, which
# leaves the one-shot title marker for the next UserPromptSubmit to consume.
run_as sid-f "$PC" name eee >/dev/null
[ -f "$BASE/sessions/sid-f/title_pending" ] \
  || fail "a mid-session bind did not leave the title-retitle marker"
out=$(prompt_hook sid-f "$PC")
echo "$out" | jq -e '.hookSpecificOutput.sessionTitle == "eee"' >/dev/null \
  || { echo "$out" | sed 's/^/    /'; fail "next UserPromptSubmit did not set the tab title after a mid-session bind"; }
[ ! -f "$BASE/sessions/sid-f/title_pending" ] \
  || fail "the title marker must be consumed (one-shot) after it fires"
out2=$(prompt_hook sid-f "$PC")
[ -z "$out2" ] || { echo "$out2" | sed 's/^/    /'; fail "the title was re-emitted on a later idle prompt (marker not one-shot)"; }
pass "mid-session bind retitles the tab on the next prompt, exactly once"

green ""
green "round-25 PASS: a fresh session anchor-matches its terminal to silently rebind the right identity (else surfaces the list), and beams keeps the Claude Code tab titled to the bound identity — no manual /rename"
