#!/usr/bin/env bash
# Round 30 — bounded delivery: an identity coming back to a busy beam must not
# blow through the hook timeouts, and must never lose or duplicate a message.
#
# Background: check.sh used to signature-verify EVERY file newer than the
# cursor (openssl, ~75 ms each) before looking at who it was for, and only
# advanced the cursor after the whole scan. A live identity with 855 unread
# files on the fleet beam took 1m44s per scan, so the 5 s / 10 s hooks were
# killed on every prompt, made zero progress, and the session went deaf.
# Now: a one-grep recipient pre-filter, a per-run delivery cap + time budget,
# and a bounded cursor advance — the cursor is a PAIR (mtime + the names
# consumed at exactly that mtime), so a run may stop anywhere in the beam's
# (mtime, name) order and resume there.
# Cases:
#   A. pre-filter is exact: to-tokens (single, comma-list, all), @-mentions,
#      no substring matches (alicex / malice), own sends excluded, and
#      --count agrees with --human
#   B. BEAMS_DELIVERY_CAP=2 over 5 addressed messages: three runs deliver
#      2 + 2 + 1 in order with a "more queued" note on the capped runs, a
#      fourth run is silent — no loss, no duplicate
#   C. hook fast path is keyed to the BOUND identity: the mtime stash lands
#      under projects/…/identities/<name>/state, an unchanged beam is a silent
#      no-op, a new message still gets through, and a stale lease forces the
#      slow path (heartbeat refreshed)
#   D. the systemMessage sender list is "a, b, c" (paste -d cycling bug)
#   E. a capped backlog DRAINS through the prompt hook across consecutive
#      prompts — a partial run must not leave the mtime fast path short-
#      circuiting the rest of the queue (F2)
#   F. a capped hook/human run never drags the watcher's NOTIFY cursor
#      backwards: after the watcher drained a beam, the next poll stays
#      empty (F3)
#   G. 60 messages sharing ONE mtime (rsync/tar/FAT restore) still obey the
#      budget and the cap: ≤5 per run, drained across runs, nothing lost,
#      nothing duplicated, --count exact throughout (F4)
#   H. a message from someone else whose BODY quotes `from: <our sid>` is
#      delivered and counted — the sender-exclusion filter reads the header
#      only (F5)
#   I. an ESC byte in a sender name never reaches the systemMessage (F10)
#   J. the overflow hint never understates a backlog it did not measure (F13)
#   K. a run the budget stopped before the first match still reports the
#      backlog instead of going silent (F17)
#   L. a message that lands between the scan's listing and the cursor advance
#      is delivered on the next run, never swallowed by the advance (F18)

set -euo pipefail

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r30.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg" HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
unset CLAUDE_CODE_SESSION_ID BEAMS_CONFIG_DIR CLAUDE_PID BEAMS_DELIVERY_CAP BEAMS_SCAN_BUDGET_SECS
export BEAMS_DISABLE_WATCH_ON_BOOT=1
SHARED="$TMP/share"; mkdir -p "$SHARED"
CFG_A="$TMP/cfg-alice"; CFG_B="$TMP/cfg-bob"; CFG_C="$TMP/cfg-carol"
BASE="$XDG_CONFIG_HOME/beams"
PKEY=$(printf '%s' "$CLAUDE_PROJECT_DIR" | sed 's,/,-,g')

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

run_as() { ( export BEAMS_CONFIG_DIR="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
as_a() { run_as "$CFG_A" "$@"; }
as_b() { run_as "$CFG_B" "$@"; }
as_c() { run_as "$CFG_C" "$@"; }
# Session-id resolution (bound identity), no BEAMS_CONFIG_DIR override.
runas() { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1"; "$PLUGIN/lib/$2.sh" "${@:3}" ); }
# hook <session-id> [delivery-cap] — the real UserPromptSubmit entry point.
hook()  { ( unset BEAMS_CONFIG_DIR; export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN"
            if [ -n "${2:-}" ]; then export BEAMS_DELIVERY_CAP="$2"; fi
            printf '{"hook_event_name":"UserPromptSubmit"}' | bash "$PLUGIN/hooks/check-messages.sh" ); }

as_a init "$SHARED" >/dev/null; as_b init "$SHARED" >/dev/null; as_c init "$SHARED" >/dev/null
as_a name alice >/dev/null; as_b name bob >/dev/null; as_c name carol >/dev/null
as_b join r30 >/dev/null; as_a join r30 >/dev/null; as_c join r30 >/dev/null

# ---------------------------------------------------------------------------
banner "A. recipient pre-filter is exact (superset in, precise match out)"
for i in $(seq 1 30); do as_b send r30 carol "noise-$i for carol only" >/dev/null; done
as_b send r30 alice        "direct-1"            >/dev/null
as_b send r30 alice        "direct-2"            >/dev/null
as_b send r30 all          "broadcast-1"         >/dev/null
as_b send r30 "carol,alice" "list-1"             >/dev/null
as_b send r30 carol        "mention-1 @alice look" >/dev/null
as_b send r30 alicex       "substring-trap-1"    >/dev/null
as_b send r30 carol        "malice@alicex no @alicetoo"  >/dev/null
as_a send r30 all          "self-1 (must not come back to me)" >/dev/null
[ "$(as_a check --count)" = 5 ] || fail "--count expected 5 (2 direct + all + list + mention), got $(as_a check --count)"
out=$(as_a check --human)
for want in direct-1 direct-2 broadcast-1 list-1 mention-1; do
  printf '%s' "$out" | grep -qF "$want" || fail "missing '$want' in: $out"
done
for nope in noise- substring-trap self-1 malice@alicex; do
  printf '%s' "$out" | grep -qF "$nope" && fail "'$nope' leaked through the pre-filter" || true
done
printf '%s' "$out" | grep -q 'delivery capped' && fail "5 messages must not hit the default cap" || true
[ "$(as_a check --count)" = 0 ] || fail "cursor did not advance after --human"
pass "5 addressed delivered; 30 noise + substring traps + own send skipped; --count agrees"

# ---------------------------------------------------------------------------
banner "B. delivery cap: 2+2+1 across runs, in order, no loss, no duplicate"
for i in 1 2 3 4 5; do
  as_b send r30 alice "capped-$i" >/dev/null
  sleep 1.05    # distinct mtimes (the safe-stop rule needs a strict boundary)
done
r1=$(BEAMS_DELIVERY_CAP=2 as_a check --human)
printf '%s' "$r1" | grep -qF capped-1 && printf '%s' "$r1" | grep -qF capped-2 || fail "run 1 should deliver capped-1 + capped-2: $r1"
printf '%s' "$r1" | grep -qF capped-3 && fail "run 1 delivered past the cap" || true
printf '%s' "$r1" | grep -q 'about 3 more' || fail "run 1 missing the 'about 3 more' note: $r1"
r2=$(BEAMS_DELIVERY_CAP=2 as_a check --human)
printf '%s' "$r2" | grep -qF capped-3 && printf '%s' "$r2" | grep -qF capped-4 || fail "run 2 should deliver capped-3 + capped-4: $r2"
printf '%s' "$r2" | grep -qF capped-2 && fail "run 2 re-delivered capped-2 (duplicate)" || true
printf '%s' "$r2" | grep -q 'about 1 more' || fail "run 2 missing the 'about 1 more' note: $r2"
r3=$(BEAMS_DELIVERY_CAP=2 as_a check --human)
printf '%s' "$r3" | grep -qF capped-5 || fail "run 3 should deliver capped-5: $r3"
printf '%s' "$r3" | grep -q 'delivery capped' && fail "run 3 (last message) must not claim more are queued" || true
r4=$(BEAMS_DELIVERY_CAP=2 as_a check --human)
[ -z "$r4" ] || fail "run 4 should be silent: $r4"
pass "cap honoured with a safe partial cursor: 2+2+1, then silence"

# ---------------------------------------------------------------------------
banner "C. hook fast path follows the BOUND identity (and the lease guard)"
runas s30 init "$SHARED" >/dev/null
runas s30 name hooked    >/dev/null
runas s30 join r30       >/dev/null
IDDIR="$BASE/projects/$PKEY/identities/hooked"
[ -f "$IDDIR/config.json" ] || fail "bound identity not at $IDDIR"
as_b send r30 hooked "hook-msg-1" >/dev/null
out=$(hook s30)
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("hook-msg-2")' >/dev/null 2>&1 \
  && fail "hook-msg-2 delivered before it was sent?!" || true
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("hook-msg-1")' >/dev/null \
  || fail "hook did not deliver hook-msg-1: $out"
# A snapshot taken in the same second the beam was last written is "hot" and
# deliberately not cached; step into the next second so the quiet prompt below
# is the one that writes the cache.
sleep 1.1
out=$(hook s30)
[ -z "$out" ] || fail "unchanged beam: hook should be a silent no-op, got: $out"
[ -f "$IDDIR/state/hook-mtime-stash" ] || fail "mtime stash not under the bound identity (fast path still keyed to the legacy path?)"
[ ! -e "$BASE/state/hook-mtime-stash" ] || fail "a stash landed at the legacy ~/.config/beams/state path"
out=$(hook s30)
[ -z "$out" ] || fail "cached beam: hook should be a silent no-op, got: $out"
as_b send r30 hooked "hook-msg-2" >/dev/null
out=$(hook s30)
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("hook-msg-2")' >/dev/null \
  || fail "fast path censored a new message: $out"
# Same-second race: a message that lands in the second the cache was written
# must still get through on the very next prompt (hot snapshots are refused).
# "Same second, typically" is not good enough — when the intervening hook run
# crosses a second boundary the hot-snapshot path is never exercised and the
# case passes for the wrong reason. So start each attempt at the top of a
# second and only accept the attempt whose send → hook → send all landed inside
# it; anything else is drained and retried. `printf -v '%(%s)T'` is a builtin,
# so the spin costs no forks.
same_second=0; attempt=0
while [ "$attempt" -lt 8 ]; do
  attempt=$((attempt + 1))
  printf -v _s0 '%(%s)T' -1
  while :; do
    printf -v _sec '%(%s)T' -1
    if [ "$_sec" != "$_s0" ]; then break; fi
    sleep 0.02
  done
  as_b send r30 hooked "hook-msg-3-$attempt" >/dev/null
  hook s30 >/dev/null                            # delivers 3; snapshot is hot → not cached
  as_b send r30 hooked "hook-msg-4-$attempt" >/dev/null
  printf -v _s2 '%(%s)T' -1
  if [ "$_s2" = "$_sec" ]; then same_second=1; break; fi
  hook s30 >/dev/null                            # crossed a second → drain and retry
done
[ "$same_second" = 1 ] || fail "could not land send → hook → send inside one second in 8 attempts"
out=$(hook s30)
printf '%s' "$out" | jq -e --arg m "hook-msg-4-$attempt" \
  '.hookSpecificOutput.additionalContext | contains($m)' >/dev/null \
  || fail "same-second message skipped by a hot cache: $out"
# Stale lease → the fast path must yield to the slow path (which heartbeats).
# Plant an ancient last_seen (a same-second refresh would otherwise tie) and
# age the file itself, which is what the guard looks at.
tmpl=$(mktemp); jq '.last_seen = 1' "$IDDIR/lease.json" > "$tmpl" && mv "$tmpl" "$IDDIR/lease.json"
touch -d '-10 minutes' "$IDDIR/lease.json"
hook s30 >/dev/null
after=$(jq -r .last_seen "$IDDIR/lease.json")
[ "$after" -gt 1 ] || fail "stale lease was not refreshed (fast path skipped the heartbeat)"
pass "stash under identities/<name>/state; no-op when quiet; new mail (even same-second) delivered; stale lease heartbeated"

# ---------------------------------------------------------------------------
banner "D. systemMessage sender list reads 'a, b, c'"
as_b send r30 hooked "from-bob" >/dev/null
as_c send r30 hooked "from-carol" >/dev/null
as_a send r30 hooked "from-alice" >/dev/null
out=$(hook s30)
sm=$(printf '%s' "$out" | jq -r '.systemMessage')
printf '%s' "$sm" | grep -Eq 'from [a-z]+, [a-z]+, [a-z]+$' || fail "sender list not comma-joined: $sm"
pass "three senders → '$sm'"

# ---------------------------------------------------------------------------
banner "E. a capped backlog drains through the PROMPT HOOK, prompt after prompt"
# A partial run advances only this identity's cursor files — no beam directory
# mtime changes — so the hook's mtime fast path used to report "nothing new" on
# every following prompt: prompt 1 delivered 2 of 6 and promised the rest "on
# your next prompts", prompts 2-4 delivered nothing at all, and only the 5 min
# lease guard ever unstuck it (an identity with no lease.json never drained).
MARKER="$IDDIR/state/partial-delivery"
for i in 1 2 3 4 5 6; do as_b send r30 hooked "drain-$i" >/dev/null; done
sleep 1.1          # let the beam dir mtime settle so each stash write is cacheable
[ "$(runas s30 check --count)" = 6 ] || fail "expected 6 unread before the drain, got $(runas s30 check --count)"
got=""; runs=0
while [ "$runs" -lt 6 ]; do
  runs=$((runs + 1))
  out=$(hook s30 2)
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)
  this=$(printf '%s' "$ctx" | grep -o 'drain-[0-9]' | tr '\n' ' ' || true)
  n=$(printf '%s' "$this" | wc -w)
  [ "$n" -le 2 ] || fail "prompt $runs delivered $n messages with BEAMS_DELIVERY_CAP=2: $this"
  if [ "$runs" -le 3 ]; then
    [ "$n" = 2 ] || fail "prompt $runs delivered $n of the backlog, not 2 — the fast path stalled the drain: $out"
  fi
  got="$got$this"
  if [ "$runs" -lt 3 ]; then
    [ -f "$MARKER" ] || fail "a partial run must leave the partial-delivery marker for the hook"
  fi
  if [ -z "$this" ]; then break; fi
  sleep 1.1        # next prompt, a second later (mtimes settle)
done
[ "$runs" = 4 ] || fail "expected 3 delivering prompts + 1 silent, took $runs"
for i in 1 2 3 4 5 6; do
  c=$(printf '%s\n' $got | grep -cx "drain-$i" || true)
  [ "$c" = 1 ] || fail "drain-$i delivered $c times across the prompts (want exactly 1): [$got]"
done
[ "$(runas s30 check --count)" = 0 ] || fail "backlog did not reach 0 after the drain"
[ ! -f "$MARKER" ] || fail "the full run must remove the partial-delivery marker"
pass "6 unread, cap 2 → 2+2+2 across consecutive prompts then silence; marker set while partial, cleared at the end"

# ---------------------------------------------------------------------------
banner "F. a capped run never drags the watcher's notify cursor backwards"
# Both cursors take the same target, but the watcher's notify cursor is normally
# further ahead than the hook's, so a capped hook run used to pull it back and
# re-notify (desktop ping AND native doorbell wake, once per poll) everything in
# between.
as_a join r30f >/dev/null; as_b join r30f >/dev/null
for i in 1 2 3 4 5 6; do as_b send r30f alice "watch-$i" >/dev/null; done
n1=$(as_a check --notify | wc -l)
[ "$n1" = 6 ] || fail "watcher poll 1 should notify all 6, got $n1"
n2=$(as_a check --notify | wc -l)
[ "$n2" = 0 ] || fail "watcher poll 2 should be empty, got $n2"
capped=$(BEAMS_DELIVERY_CAP=2 as_a check --human)
printf '%s' "$capped" | grep -qF watch-1 || fail "capped run should still deliver to the model: $capped"
n3=$(as_a check --notify | wc -l)
[ "$n3" = 0 ] || fail "capped run rewound the notify cursor — the watcher re-notified $n3 message(s)"
BEAMS_DELIVERY_CAP=0 as_a check --human >/dev/null    # drain the rest for later cases
n4=$(as_a check --notify | wc -l)
[ "$n4" = 0 ] || fail "full drain rewound the notify cursor — $n4 re-notified"
pass "watcher drained first; capped + full hook runs left the next polls empty"

# ---------------------------------------------------------------------------
banner "G. 60 messages sharing ONE mtime still obey the budget and the cap"
# rsync without -t, cp -r, tar/zip extraction, a git checkout of an archive or a
# FAT/exFAT share all land a backlog on one mtime. Nothing is then strictly
# newer than its siblings, so the old "stop only where every unreached candidate
# is strictly newer" rule could never fire: budget AND cap were ignored and the
# whole backlog ran in one hook — the original timeout bug. Six distinct bodies
# copied ten times each stands in for the restore (and makes loss/duplication
# countable); every file then gets one shared mtime.
as_a join r30g >/dev/null; as_b join r30g >/dev/null
MDG="$SHARED/beams/r30g/messages"
for i in 1 2 3 4 5 6; do
  as_b send r30g alice "tie-$i" >/dev/null
  src=$(ls -1t "$MDG"/*.msg | head -1 || true)
  for c in 1 2 3 4 5 6 7 8 9; do cp "$src" "$MDG/copy-$i-$c.msg"; done
done
ASID=$(jq -r .session_id "$CFG_A/config.json")
CURG="$CFG_A/state/$ASID/cursor.r30g"
touch -d "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M:%S')" "$CURG"
touch -d "$(date -d  '-5 minutes' '+%Y-%m-%d %H:%M:%S')" "$MDG"/*.msg
[ "$(ls -1 "$MDG"/*.msg | wc -l)" = 60 ] || fail "expected 60 equal-mtime files"
[ "$(as_a check --count)" = 60 ] || fail "--count should be 60 before the drain, got $(as_a check --count)"
gotg=""; runs=0; first=1
while [ "$runs" -lt 25 ]; do
  runs=$((runs + 1))
  out=$(BEAMS_SCAN_BUDGET_SECS=1 BEAMS_DELIVERY_CAP=5 as_a check --human)
  this=$(printf '%s' "$out" | grep -o 'tie-[0-9]' || true)
  n=$(printf '%s' "$this" | grep -c . || true)
  [ "$n" -le 5 ] || fail "run $runs delivered $n equal-mtime messages with cap 5 (the cap was ignored)"
  if [ -z "$this" ]; then break; fi
  gotg="$gotg$this"$'\n'
  if [ "$first" = 1 ]; then
    first=0
    [ "$n" -ge 1 ] || fail "run 1 delivered nothing at all"
    left=$(as_a check --count)
    [ "$left" = $((60 - n)) ] || fail "--count says $left after a capped run that delivered $n of 60"
  fi
done
# ≤5 per run over 60 messages is ≥12 delivering runs plus the silent one; a
# slower host may take a couple more when the 1 s budget bites before the cap.
[ "$runs" -ge 13 ] || fail "60 messages at cap 5 drained in only $runs runs — the cap did not bound the work"
for i in 1 2 3 4 5 6; do
  c=$(printf '%s' "$gotg" | grep -cx "tie-$i" || true)
  [ "$c" = 10 ] || fail "tie-$i delivered $c times across the drain (want exactly 10 — the 10 copies)"
done
[ "$(as_a check --count)" = 0 ] || fail "--count should be 0 after the equal-mtime drain"
pass "60 equal-mtime messages drained 5 at a time across 12 runs, none lost, none duplicated, --count exact"

# ---------------------------------------------------------------------------
banner "H. a body that quotes 'from: <our sid>' is still delivered (header-only filter)"
# The sender-exclusion pre-filter used to grep the WHOLE file, so a message
# whose BODY quoted a raw `from: <our uuid>` header line — agents paste message
# dumps at each other on this bridge — was dropped AND the cursor advanced past
# it: permanent silent loss and a --count that disagreed with delivery.
as_a join r30h >/dev/null; as_b join r30h >/dev/null
as_b send r30h alice "pasting your own dump back at you:
from: $ASID
to: carol
(end of dump)" >/dev/null
as_b send r30h alice "plain-follow-up" >/dev/null
[ "$(as_a check --count)" = 2 ] || fail "--count should see both messages, got $(as_a check --count)"
outh=$(as_a check --human)
printf '%s' "$outh" | grep -qF 'pasting your own dump' || fail "quoted own-sid dump was dropped: $outh"
printf '%s' "$outh" | grep -qF 'plain-follow-up'       || fail "follow-up was dropped: $outh"
as_a send r30h all "my own broadcast" >/dev/null
[ "$(as_a check --count)" = 0 ] || fail "our own send came back to us"
pass "quoted own-sid body delivered and counted; real own sends still skipped"

# ---------------------------------------------------------------------------
banner "I. an ESC byte in a sender name never reaches the systemMessage"
# from_name is entirely sender-controlled (a peer writes its own config), and
# the systemMessage is printed in the user's terminal.
tmpn=$(mktemp)
jq --arg n "$(printf 'bob\033[2K\033[1;31mSYSTEM')" '.session_name = $n' "$CFG_B/config.json" > "$tmpn" \
  && mv "$tmpn" "$CFG_B/config.json"
as_b send r30 hooked "escape-attempt" >/dev/null
outi=$(runas s30 check --hook)
smi=$(printf '%s' "$outi" | jq -r '.systemMessage // ""')
printf '%s' "$smi" | grep -q "$(printf '\033')" && fail "ESC reached the systemMessage: $(printf '%s' "$smi" | od -c | head -2)" || true
printf '%s' "$outi" | jq -r '.hookSpecificOutput.additionalContext // ""' | grep -q "$(printf '\033')" \
  && fail "ESC reached the inbox render" || true
tmpn=$(mktemp); jq '.session_name = "bob"' "$CFG_B/config.json" > "$tmpn" && mv "$tmpn" "$CFG_B/config.json"
pass "control bytes stripped from the sender name before the systemMessage is built"

# ---------------------------------------------------------------------------
banner "J. the overflow hint never understates a backlog it did not measure"
# The hint used to count only the beam the scan stopped in, so "about 3 more"
# could hide 500 queued on a beam the run never reached.
as_a join r30j1 >/dev/null; as_b join r30j1 >/dev/null
as_a join r30j2 >/dev/null; as_b join r30j2 >/dev/null
for i in 1 2 3; do as_b send r30j1 alice "j1-$i" >/dev/null; done
for i in 1 2 3 4 5 6 7 8; do as_b send r30j2 alice "j2-$i" >/dev/null; done
outj=$(BEAMS_DELIVERY_CAP=1 as_a check --human)
printf '%s' "$outj" | grep -q 'still queued' || fail "capped run over two beams must carry the overflow note: $outj"
printf '%s' "$outj" | grep -qE 'about [0-9]+ more' \
  && fail "the hint quoted a number while a whole beam went unscanned: $outj" || true
BEAMS_DELIVERY_CAP=0 as_a check --human >/dev/null
[ "$(as_a check --count)" = 0 ] || fail "two-beam backlog did not drain"
pass "a skipped beam drops the number instead of understating the queue"

# ---------------------------------------------------------------------------
banner "K. a budget stop before the first match still reports the backlog"
# The note used to be computed and then thrown away by an early `total -eq 0`
# exit, so a run that spent its whole budget on mail for other recipients went
# completely silent while a backlog sat there.
as_a join r30k >/dev/null; as_b join r30k >/dev/null; as_c join r30k >/dev/null
MDK="$SHARED/beams/r30k/messages"
as_b send r30k carol "not for alice
to: alice
(this body line is a pre-filter hit, the header is not)" >/dev/null
nsrc=$(ls -1t "$MDK"/*.msg | head -1 || true)
# ~120 ms each (openssl + jq per candidate): 30 of them overrun a 1 s budget
# several times over on any host this suite runs on.
for i in $(seq 1 30); do cp "$nsrc" "$MDK/decoy-$i.msg"; done
as_b send r30k alice "behind-the-wall" >/dev/null
outk=$(BEAMS_SCAN_BUDGET_SECS=1 as_a check --hook)
[ -n "$outk" ] || fail "a budget-stopped run with no match went completely silent"
printf '%s' "$outk" | jq -e '.hookSpecificOutput.additionalContext | contains("still queued")' >/dev/null \
  || fail "the hint did not reach additionalContext: $outk"
printf '%s' "$outk" | jq -e '.systemMessage | length > 0' >/dev/null \
  || fail "the hint did not reach the systemMessage: $outk"
printf '%s' "$outk" | grep -qF 'behind-the-wall' && fail "the budget did not stop the scan — retune the decoy count" || true
outk2=$(BEAMS_SCAN_BUDGET_SECS=0 BEAMS_DELIVERY_CAP=0 as_a check --human)
printf '%s' "$outk2" | grep -qF 'behind-the-wall' || fail "the message behind the wall never arrived: $outk2"
pass "budget stop with zero matches still hints; the message behind the decoys arrives next run"

# ---------------------------------------------------------------------------
banner "L. a message landing between the scan and the advance is not swallowed"
# The advance used to re-list the directory (`ls -1t`) instead of using what the
# scan saw, so a message written during the scan set the cursor at or past its
# own mtime and was never read again. The seam below is that window, made
# deterministic: a `find` shim drops the late message into the beam right after
# the scan's listing returns.
as_a join r30l >/dev/null; as_b join r30l >/dev/null
MDL="$SHARED/beams/r30l/messages"
as_b send r30l alice "seam-early" >/dev/null
# TWO late arrivals, a hair apart: the equal-mtime tie list alone rescues a
# single late file that happens to share the cursor's new mtime, so only a
# second, older one proves the advance is really bounded by the listing.
as_b send r30l alice "seam-late-a" >/dev/null
lateaf=$(ls -1t "$MDL"/*.msg | head -1 || true); mv "$lateaf" "$TMP/seam-late-a.msg"
as_b send r30l alice "seam-late-b" >/dev/null
latebf=$(ls -1t "$MDL"/*.msg | head -1 || true); mv "$latebf" "$TMP/seam-late-b.msg"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/find" <<EOF
#!/usr/bin/env bash
# find(1) shim: real behaviour, plus the late deliveries into the beam the
# moment the scan has finished listing it.
/usr/bin/find "\$@"; rc=\$?
if [ "\${1:-}" = "$MDL" ] && [ ! -f "$TMP/seam.fired" ]; then
  : > "$TMP/seam.fired"
  cp "$TMP/seam-late-a.msg" "$MDL/zz-late-a.msg"
  cp "$TMP/seam-late-b.msg" "$MDL/zz-late-b.msg"
fi
exit \$rc
EOF
chmod +x "$FAKEBIN/find"
outl=$( PATH="$FAKEBIN:$PATH" as_a check --human )
[ -f "$TMP/seam.fired" ] || fail "the find shim never fired — the seam did not reproduce the window"
printf '%s' "$outl" | grep -qF 'seam-early' || fail "run 1 should deliver the message that was there: $outl"
printf '%s' "$outl" | grep -qF 'seam-late'  && fail "run 1 delivered a message written after its own listing" || true
outl2=$(as_a check --human)
for want in seam-late-a seam-late-b; do
  printf '%s' "$outl2" | grep -qF "$want" \
    || fail "$want landed during the scan and was swallowed by the cursor advance: $outl2"
done
[ "$(as_a check --count)" = 0 ] || fail "seam beam did not drain"
pass "the cursor advance is bounded by what the scan saw; the late message arrived next run"

green ""
green "round-30 PASS: exact recipient pre-filter, bounded capped delivery (no loss / no dup, equal mtimes included), a drain that survives the hook fast path, a notify cursor that never rewinds, header-only sender exclusion, honest overflow hints, identity-keyed hook fast path, tidy sender list"
