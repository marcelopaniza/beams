#!/usr/bin/env bash
# Round 35 — two fixes proven together:
#   1. beams::extract_body (lib/common.sh) used to treat EVERY line that is
#      exactly '---' as a frontmatter fence, even ones inside the body, so a
#      body containing a markdown rule / a pasted message dump / a fake
#      frontmatter block never matched the signature send.sh computed over
#      the real body and was dropped silently (never counted, never shown).
#      Fixed to stop treating '---' as a delimiter once the front matter has
#      closed.
#   2. The watcher daemon posted one native inbox summary per POLL, so an
#      identity coming back to a stale/absent cursor against a big backlog
#      (855 messages / 20-per-poll cap = 43 polls) forced 43 turns in a few
#      minutes. Fixed with a cooldown in lib/watcher_daemon.sh's
#      post_batch_to_inbox: a batch that itself hits the cap (a drain) must
#      wait inbox_post_min_gap (60s) after the last such full post; a
#      non-full batch (an ordinary conversation) always posts immediately.
#
# Cases:
#   A. body with a '---' line in the middle — --human, --inject and --notify
#      all deliver the body intact.
#   B. body that is ONLY '---' — same three.
#   C. body with a fake frontmatter block pasted inside it — same three, and
#      the fake block is not mistaken for real frontmatter.
#   D. an ordinary message with no dashes at all still delivers correctly
#      (the fix must not change the wire format for existing messages).
#   E. doorbell storm: a fresh identity (no prior cursor — the same shape as
#      a wiped state dir) facing a 50-message backlog under a 1s poll gets
#      far fewer native posts than polls (at most 2, not one per poll), while
#      a single new message sent after the drain still posts within one poll
#      — the cooldown holds back a drain but never a normal conversation.

set -euo pipefail
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN 2>/dev/null || true
unset BEAMS_CONFIG_DIR BEAMS_DELIVERY_CAP BEAMS_SCAN_BUDGET_SECS 2>/dev/null || true

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r35.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg" HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
export BEAMS_DISABLE_WATCH_ON_BOOT=1  # we start the watcher ourselves, by hand, in E
export BEAMS_NOTIFIER_CMD=true        # no real desktop notifications
SHARED="$TMP/share"; mkdir -p "$SHARED"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

SRV=""
cleanup() {
  local f
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true
  for f in "$XDG_CONFIG_HOME"/beams/projects/*/identities/*/state/*/watcher.pid; do
    [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

run_as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }

have_python3=0
command -v python3 >/dev/null 2>&1 && have_python3=1

# ---------------------------------------------------------------------------
banner "A-D. beams::extract_body no longer treats an in-body '---' as a fence"

BEAM="r35-body"
CFG_SENDER="$TMP/cfg-sender"
CFG_HUMAN="$TMP/cfg-human"
CFG_INJECT="$TMP/cfg-inject"
CFG_NOTIFY="$TMP/cfg-notify"

run_as "$CFG_SENDER" init "$SHARED" >/dev/null
run_as "$CFG_SENDER" name r35sender >/dev/null
run_as "$CFG_SENDER" join "$BEAM"   >/dev/null
run_as "$CFG_HUMAN"  init "$SHARED" >/dev/null
run_as "$CFG_HUMAN"  name r35human  >/dev/null
run_as "$CFG_HUMAN"  join "$BEAM"   >/dev/null
run_as "$CFG_INJECT" init "$SHARED" >/dev/null
run_as "$CFG_INJECT" name r35inject >/dev/null
run_as "$CFG_INJECT" join "$BEAM"   >/dev/null
run_as "$CFG_NOTIFY" init "$SHARED" >/dev/null
run_as "$CFG_NOTIFY" name r35notify >/dev/null
run_as "$CFG_NOTIFY" join "$BEAM"   >/dev/null

# check_case <label> <body> — one fresh send, checked through all three
# body-rendering modes via three dedicated reader identities (each has its
# own per-beam cursor, so the three reads never interfere with each other).
check_case() {
  local label="$1" body="$2" out n expect_preview got_preview

  run_as "$CFG_SENDER" send "$BEAM" all "$body" >/dev/null

  out=$(run_as "$CFG_HUMAN" check --human)
  printf '%s' "$out" | grep -q '1 new beam message(s)' \
    || fail "$label: --human did not see exactly 1 message: $out"
  [[ "$out" == *"$body"* ]] \
    || fail "$label: --human body did not come through intact: $out"

  out=$(run_as "$CFG_INJECT" check --inject)
  printf '%s' "$out" | grep -q 'You have 1 new beam message(s)' \
    || fail "$label: --inject did not see exactly 1 message: $out"
  [[ "$out" == *"$body"* ]] \
    || fail "$label: --inject body did not come through intact: $out"

  out=$(run_as "$CFG_NOTIFY" check --notify)
  [ -n "$out" ] || fail "$label: --notify produced no output at all"
  n=$(printf '%s\n' "$out" | wc -l)
  [ "$n" -eq 1 ] || fail "$label: --notify emitted $n lines, want 1: $out"
  expect_preview=$(printf '%s' "$body" | tr '\n' ' ' \
                    | LC_ALL=C tr -d '\000-\011\013-\037\177' | cut -c1-120)
  got_preview=$(printf '%s' "$out" | cut -f3)
  [ "$got_preview" = "$expect_preview" ] \
    || fail "$label: --notify preview mismatch: got [$got_preview] want [$expect_preview]"

  pass "$label: --human, --inject and --notify all deliver the body intact"
}

check_case "A (in-body ---)"      $'before the rule\n---\nafter the rule'
check_case "B (body is only ---)" $'---'
check_case "C (fake frontmatter)" $'quoting an old message:\n---\nfrom: spoofed-eve\nto: someone-else\n---\nend of quote'
check_case "D (ordinary message)" 'a perfectly ordinary message, no dashes here'

# ---------------------------------------------------------------------------
banner "E. doorbell storm: 50-message backlog under a 1s poll gets far fewer native posts than polls"

if [ "$have_python3" = 0 ]; then
  green "  SKIP: no python3 on this host — the native post degrades to the wake.log fallback (round 28 covers that path)"
else
  SOCK="$TMP/inbox-flooded.sock"; RECV="$TMP/received-flooded.log"
  # Fake AF_UNIX session inbox — same listener shape as tests/round-32.sh.
  cat > "$TMP/fake-inbox.py" <<'PY'
import os, socket, sys
path, out = sys.argv[1], sys.argv[2]
try:
    os.unlink(path)
except OSError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(16)
while True:
    c, _ = s.accept()
    buf = b''
    try:
        while True:
            d = c.recv(65536)
            if not d:
                break
            buf += d
    finally:
        c.close()
    if buf and not buf.endswith(b'\n'):
        buf += b'\n'
    with open(out, 'ab') as f:
        f.write(buf)
        f.flush()
PY
  : > "$RECV"
  python3 "$TMP/fake-inbox.py" "$SOCK" "$RECV" & SRV=$!
  i=0; while [ "$i" -lt 50 ] && [ ! -S "$SOCK" ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$SOCK" ] || fail "fake inbox server never bound $SOCK"

  frames() { grep -F '"type":"user"' "$RECV" 2>/dev/null || true; }
  wait_frames() {   # wait_frames <want> — poll up to ~12s
    local want="$1" i=0
    while [ "$i" -lt 60 ]; do
      [ "$(frames | wc -l)" -ge "$want" ] && return 0
      sleep 0.2; i=$((i + 1))
    done
    return 1
  }

  TOK="r35-token-do-not-log"
  boot() {
    ( unset BEAMS_CONFIG_DIR
      export CLAUDE_CODE_SESSION_ID="flooded-sess" CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PID="$$" \
             CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" CLAUDE_CODE_MESSAGING_TOKEN="$TOK"
      printf '{"source":"startup"}' | bash "$PLUGIN/hooks/check-on-start.sh" 2>/dev/null ) || true
  }
  runas() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="flooded-sess"; "$PLUGIN/lib/$1.sh" "${@:2}" ); }

  runas init "$SHARED"  >/dev/null
  runas name flooded    >/dev/null
  runas join r35-storm  >/dev/null
  FLOODED=$(find "$XDG_CONFIG_HOME/beams/projects" -type d -name flooded | head -1)
  [ -n "$FLOODED" ] || fail "flooded identity was not created"

  CFG_DAVE="$TMP/cfg-dave2"
  run_as "$CFG_DAVE" init "$SHARED"  >/dev/null
  run_as "$CFG_DAVE" name dave2      >/dev/null
  run_as "$CFG_DAVE" join r35-storm  >/dev/null

  # Publish the pointer (outside the watch_on_boot gate) BEFORE the backlog
  # exists: check-on-start.sh's own SessionStart pull (--hook) advances BOTH
  # the hook AND notify cursors, so publishing it against an empty beam keeps
  # that pull a no-op and leaves the notify cursor untouched — otherwise it
  # would silently pre-drain part of the backlog and the watcher would never
  # see enough of it in one poll to hit the cap twice.
  boot >/dev/null
  [ -f "$FLOODED/inbox.json" ] || fail "boot did not publish flooded's inbox pointer"

  # 50 messages, fully written to disk BEFORE any watcher exists — a fresh
  # identity with no prior cursor sees this exact shape (a stale/wiped cursor
  # against a big backlog), same as the field report's 855-message case.
  for i in $(seq 1 50); do
    run_as "$CFG_DAVE" send r35-storm flooded "backlog message $i" >/dev/null
  done

  ( export BEAMS_CONFIG_DIR="$FLOODED"; "$PLUGIN/lib/watch.sh" start 1 >/dev/null )

  # The drain needs 3 polls at cap 20 (20 + 20 + 10). Nothing in
  # post_batch_to_inbox retries a suppressed batch later, so once the count
  # stops growing it is final — watching for ~15s (well past the ~3s a
  # healthy drain needs) proves the same thing sitting out the full 60s
  # cooldown window would, without the test taking a full minute.
  i=0
  while [ "$i" -lt 30 ]; do
    n="$(frames | wc -l)"
    [ "$n" -le 2 ] \
      || fail "the 50-message backlog produced $n native posts already — cooldown did not suppress the drain (want at most 2)"
    sleep 0.5; i=$((i + 1))
  done
  n="$(frames | wc -l)"
  [ "$n" -ge 1 ] || fail "the 50-message backlog produced no native post at all"
  pass "50-message backlog under a 1s poll produced $n native post(s) while draining (at most 2, not one per poll)"

  # A single new message after the drain must NOT be held by the drain's
  # cooldown — the fix exempts every non-full (ordinary-conversation) batch.
  run_as "$CFG_DAVE" send r35-storm flooded "one more, after the drain" >/dev/null
  wait_frames "$((n + 1))" \
    || fail "a single new message after the drain did not post within a few polls — the cooldown wrongly held a non-full batch"
  pass "a single new message after the drain posted within one poll, unaffected by the drain's cooldown"

  ( export BEAMS_CONFIG_DIR="$FLOODED"; "$PLUGIN/lib/watch.sh" stop >/dev/null 2>&1 ) || true
fi

green ""
if [ "$have_python3" = 1 ]; then
  green "round-35 PASS: extract_body preserves in-body '---' lines (plain, alone, or a fake frontmatter block) across --human/--inject/--notify with no regression for ordinary messages, and the watcher's drain cooldown caps native posts for a 50-message backlog while still posting a fresh conversational message within one poll"
else
  green "round-35 PASS (E skipped — no python3 on this host): extract_body preserves in-body '---' lines (plain, alone, or a fake frontmatter block) across --human/--inject/--notify with no regression for ordinary messages"
fi
