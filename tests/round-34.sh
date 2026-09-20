#!/usr/bin/env bash
# Round 34: generic-model parity — no Claude environment at all.
#
# beams serves two audiences: Claude Code sessions (plugin hooks + native
# doorbell) and everything else (GPT via codex, Gemini, Ollama, plain
# scripts) through bin/beams, bin/beams-wrap and bin/beams-react. This round
# never exports CLAUDE_PID, CLAUDE_CODE_SESSION_ID, CLAUDE_CODE_MESSAGING_SOCKET
# or CLAUDE_CODE_MESSAGING_TOKEN — every identity here is a plain
# BEAMS_CONFIG_DIR pointed at a shared folder, exactly what docs/CROSS-CLI.md
# tells a non-Claude shell to set per terminal. Modeled on round-9 (bin/beams
# + --inject against a hermetic environment).
#
# Regression under test: lib/check.sh's bounded-delivery change (a per-run
# BEAMS_DELIVERY_CAP / BEAMS_SCAN_BUDGET_SECS, default 20 msgs / 20s for most
# modes) was right for Claude's 5s/10s hook timeouts but wrong for --inject —
# a generic model's ONLY delivery path, with no hook and no /beams:read to
# pick up the rest next turn — and for --peek, the read-only human view of a
# beam from a second identity (docs/CROSS-CLI.md). Both now default unbounded
# (0/0) like --count, while still honouring an explicit env override; --count
# stays immune to both env overrides even when both are exported (an exact
# count, full stop — beams-react's poll loop and /beams:status trust it).
#
# Cases:
#   A.  30-message backlog: one `beams read --inject` drains all 30, a
#       second call is empty (Task 1's default-unbounded fix)
#   B.  BEAMS_DELIVERY_CAP=5: --inject delivers 5 + a CLI-agnostic overflow
#       note (no "/beams:read"), repeated calls drain the rest — no loss, no
#       duplicate (set comparison)
#   C.  `beams read --count` is exact with 30 unread and after a partial
#       drain
#   C2. --count ignores BOTH BEAMS_DELIVERY_CAP and BEAMS_SCAN_BUDGET_SECS
#       even when both are exported together; --peek defaults unbounded with
#       no note, and honours an explicit cap with its own CLI-agnostic note
#   D.  beams-react drains a 30-message backlog in exactly one fire
#   E.  every addressing form docs/CROSS-CLI.md + docs/COMMANDS.md promise —
#       a name, all, a spaced comma-list, @-mentions at the start/middle/end
#       of a body, a name with dots/dashes/underscores — plus a message
#       addressed to someone else is NOT delivered
#   F.  a generic identity (no CLAUDE_PID) binds a name and "restarts" (a
#       fresh subshell) without needing --force to keep it; the documented
#       boundary (no BEAMS_CONFIG_DIR, no session id -> refuses with
#       guidance) still holds
#   G.  the watcher daemon on a generic identity appends to wake.log and
#       never attempts an inbox post (no pointer file, no "inbox" line in
#       watcher.log)

set -euo pipefail
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN 2>/dev/null || true
unset BEAMS_CONFIG_DIR BEAMS_DELIVERY_CAP BEAMS_SCAN_BUDGET_SECS BEAMS_FAKE_LIVE_SESSIONS 2>/dev/null || true

PLUGIN="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP=$(mktemp -d /tmp/beams-test-r34.XXXXXX)
export XDG_CONFIG_HOME="$TMP/xdg" HOME="$TMP/home" CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$XDG_CONFIG_HOME" "$HOME" "$CLAUDE_PROJECT_DIR"
export BEAMS_DISABLE_WATCH_ON_BOOT=1
export BEAMS_NOTIFIER_CMD=true
SHARED="$TMP/share"; mkdir -p "$SHARED"
CFG_A="$TMP/cfg-gena"; CFG_B="$TMP/cfg-genb"
NAME_A='gen.a_b-1'   # dot, underscore, dash — Task 3's name-charset coverage
NAME_B='genb'

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
banner() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
pass()   { green "PASS: $*"; }

ROUND_PIDS=()
cleanup() {
  local p
  for p in "${ROUND_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

beams_a() { ( export BEAMS_CONFIG_DIR="$CFG_A"; "$PLUGIN/bin/beams" "$@" ); }
beams_b() { ( export BEAMS_CONFIG_DIR="$CFG_B"; "$PLUGIN/bin/beams" "$@" ); }

beams_a init "$SHARED"  >/dev/null
beams_a name "$NAME_A"  >/dev/null
beams_a join r34        >/dev/null
beams_b init "$SHARED"  >/dev/null
beams_b name "$NAME_B"  >/dev/null
beams_b join r34        >/dev/null

# ---------------------------------------------------------------------------
banner "A. --inject default is unlimited: a 30-message backlog drains in one call"
for i in $(seq 1 30); do beams_b send r34 "$NAME_A" "bulk-$i" >/dev/null; done
inj=$(beams_a read --inject)
missing=0
for i in $(seq 1 30); do
  printf '%s\n' "$inj" | grep -qF "bulk-$i" || missing=$((missing + 1))
done
[ "$missing" -eq 0 ] || fail "$missing of 30 bodies missing from the single --inject drain"
opens=$(printf '%s\n' "$inj" | grep -cE '^=== beams inbox [0-9a-f]+ ===$' || true)
closes=$(printf '%s\n' "$inj" | grep -cE '^=== end inbox [0-9a-f]+ ===$' || true)
[ "$opens" -eq 1 ] && [ "$closes" -eq 1 ] || fail "expected exactly one fenced block, got opens=$opens closes=$closes"
printf '%s\n' "$inj" | grep -q 'delivery capped\|more unread' && fail "default --inject must not be capped" || true
inj2=$(beams_a read --inject)
[ -z "$inj2" ] || fail "second --inject call should be empty after a full drain; got: $inj2"
pass "30-message backlog drains in one --inject call; second call is silent"

# ---------------------------------------------------------------------------
banner "B. BEAMS_DELIVERY_CAP=5: capped --inject drains fully, no loss/dup, CLI-agnostic note"
sent_file="$TMP/b-sent.txt"; got_file="$TMP/b-got.txt"
: > "$sent_file"; : > "$got_file"
for i in $(seq 1 5); do
  body="cap-msg-$i"; beams_b send r34 "$NAME_A" "$body" >/dev/null; printf '%s\n' "$body" >> "$sent_file"
done
sleep 1.05   # distinct mtime boundary at the FIRST 5-message cap (round-30 explains the same-second issue)
for i in $(seq 6 10); do
  body="cap-msg-$i"; beams_b send r34 "$NAME_A" "$body" >/dev/null; printf '%s\n' "$body" >> "$sent_file"
done
sleep 1.05   # distinct mtime boundary at the SECOND 5-message cap
for i in $(seq 11 12); do
  body="cap-msg-$i"; beams_b send r34 "$NAME_A" "$body" >/dev/null; printf '%s\n' "$body" >> "$sent_file"
done
calls=0
first_delivered=""
while :; do
  calls=$((calls + 1))
  [ "$calls" -le 20 ] || fail "runaway drain loop in section B"
  out=$(BEAMS_DELIVERY_CAP=5 beams_a read --inject)
  [ -n "$out" ] || break
  printf '%s\n' "$out" | grep -oE '^cap-msg-[0-9]+$' >> "$got_file" || true
  if [ "$calls" -eq 1 ]; then
    first_delivered=$(printf '%s\n' "$out" | grep -cE '^cap-msg-[0-9]+$' || true)
    printf '%s\n' "$out" | grep -q '/beams:read' && fail "generic --inject overflow note must not mention /beams:read: $out" || true
    printf '%s\n' "$out" | grep -qE 'more unread message' || fail "first capped call missing the overflow note: $out"
    printf '%s\n' "$out" | grep -qE 'beams-wrap run' || fail "note should point at a beams-wrap run: $out"
    printf '%s\n' "$out" | grep -qE '`beams read --inject`' || fail "note should mention \`beams read --inject\`: $out"
  fi
done
[ "$first_delivered" = 5 ] || fail "first capped call should deliver exactly 5; delivered $first_delivered"
[ "$calls" -ge 2 ] || fail "expected the cap to force more than one call, only took $calls"
sort -o "$sent_file" "$sent_file"; sort -o "$got_file" "$got_file"
diff "$sent_file" "$got_file" >/dev/null || fail "capped drain lost or duplicated messages: $(diff "$sent_file" "$got_file")"
pass "BEAMS_DELIVERY_CAP=5 drained 12 messages across $((calls - 1)) delivering call(s) + a final empty confirmation, no loss/dup, CLI-agnostic note"

# ---------------------------------------------------------------------------
banner "C. beams read --count is exact with 30 unread and after a partial drain"
for i in $(seq 1 30); do beams_b send r34 "$NAME_A" "cnt-$i" >/dev/null; done
count_before=$(beams_a read --count)
[ "$count_before" = 30 ] || fail "expected --count=30 before any drain, got $count_before"
drained=$(BEAMS_DELIVERY_CAP=10 beams_a read --inject)
delivered=$(printf '%s\n' "$drained" | grep -cE '^cnt-[0-9]+$' || true)
[ "$delivered" -ge 1 ] && [ "$delivered" -lt 30 ] || fail "partial drain should deliver 1-29 messages, delivered $delivered"
count_after=$(beams_a read --count)
expect_after=$((30 - delivered))
[ "$count_after" = "$expect_after" ] || fail "expected --count=$expect_after after the partial drain (delivered=$delivered), got $count_after"
beams_a read --inject >/dev/null   # mop up the rest so later sections start clean
[ "$(beams_a read --count)" = 0 ] || fail "count did not reach 0 after the mop-up drain"
pass "--count exact before (30) and after ($expect_after) a partial drain"

# ---------------------------------------------------------------------------
banner "C2. --count ignores env overrides entirely; --peek defaults unbounded, honours an explicit cap"
for i in $(seq 1 5); do beams_b send r34 "$NAME_A" "n27-$i" >/dev/null; done
sleep 1.05   # distinct mtime boundary at the 5-message cap used by the --peek check below
for i in $(seq 6 27); do beams_b send r34 "$NAME_A" "n27-$i" >/dev/null; done
c27=$(BEAMS_DELIVERY_CAP=2 BEAMS_SCAN_BUDGET_SECS=1 beams_a read --count)
[ "$c27" = 27 ] || fail "expected --count=27 even with BEAMS_DELIVERY_CAP=2 and BEAMS_SCAN_BUDGET_SECS=1 exported together, got $c27"
peek1=$(beams_a read --peek)
p1n=$(printf '%s\n' "$peek1" | grep -cE '^n27-[0-9]+$' || true)
[ "$p1n" = 27 ] || fail "expected --peek to show all 27 by default, showed $p1n"
printf '%s\n' "$peek1" | grep -q 'not shown\|delivery capped' && fail "default --peek must not be capped: $peek1" || true
printf '%s\n' "$peek1" | grep -q '/beams:read' && fail "default --peek must not mention /beams:read: $peek1" || true
peek2=$(beams_a read --peek)
p2n=$(printf '%s\n' "$peek2" | grep -cE '^n27-[0-9]+$' || true)
[ "$p2n" = 27 ] || fail "--peek must not advance the cursor; second peek showed $p2n"
peek_capped=$(BEAMS_DELIVERY_CAP=5 beams_a read --peek)
pcn=$(printf '%s\n' "$peek_capped" | grep -cE '^n27-[0-9]+$' || true)
[ "$pcn" = 5 ] || fail "BEAMS_DELIVERY_CAP=5 should cap --peek at exactly 5, showed $pcn"
printf '%s\n' "$peek_capped" | grep -q '/beams:read' && fail "capped --peek note must not mention /beams:read: $peek_capped" || true
printf '%s\n' "$peek_capped" | grep -qE '`beams read --peek`' || fail "capped --peek note should mention \`beams read --peek\`: $peek_capped"
printf '%s\n' "$peek_capped" | grep -qE '`beams read`' || fail "capped --peek note should mention \`beams read\`: $peek_capped"
cfinal=$(beams_a read --count)
[ "$cfinal" = 27 ] || fail "count changed after peeking (peek must never advance a cursor); got $cfinal"
beams_a read --inject >/dev/null   # mop up before the next section
[ "$(beams_a read --count)" = 0 ] || fail "count did not reach 0 after the C2 mop-up drain"
pass "--count immune to BEAMS_DELIVERY_CAP+BEAMS_SCAN_BUDGET_SECS together; --peek unbounded by default, capped note on request"

# ---------------------------------------------------------------------------
banner "D. beams-react drains a 30-message backlog in exactly one fire"
FAKE_MODEL="$TMP/fake-model.sh"
cat > "$FAKE_MODEL" <<'FAKE'
#!/usr/bin/env bash
# Stand-in for a generic AI CLI: append whatever beams-wrap hands it on
# stdin (no {BEAMS_INBOX} placeholder is used, so beams-wrap picks Mode B).
cat >> "${FAKE_MODEL_OUT:?FAKE_MODEL_OUT not set}"
FAKE
chmod +x "$FAKE_MODEL"
REACT_OUT="$TMP/react-out.txt"
: > "$REACT_OUT"
for i in $(seq 1 30); do beams_b send r34 "$NAME_A" "react-$i" >/dev/null; done
( export BEAMS_CONFIG_DIR="$CFG_A" FAKE_MODEL_OUT="$REACT_OUT"
  "$PLUGIN/bin/beams-react" --interval 1 --quiet "$FAKE_MODEL" ) &
react_pid=$!
ROUND_PIDS+=("$react_pid")
fired=0
for _ in $(seq 1 50); do
  if grep -q 'react-30' "$REACT_OUT" 2>/dev/null; then fired=1; break; fi
  sleep 0.2
done
kill -INT "$react_pid" 2>/dev/null || true
wait "$react_pid" 2>/dev/null || true
[ "$fired" -eq 1 ] || fail "beams-react never fired within 10s; captured: $(head -c 300 "$REACT_OUT" 2>/dev/null)"
missing=0
for i in $(seq 1 30); do
  grep -q "react-$i" "$REACT_OUT" || missing=$((missing + 1))
done
[ "$missing" -eq 0 ] || fail "$missing of 30 bodies missing from the fake model's capture"
fire_count=$(grep -c '=== beams inbox' "$REACT_OUT" 2>/dev/null || true)
[ "$fire_count" = 1 ] || fail "expected exactly one fire (one inbox fence), got $fire_count"
[ "$(beams_a read --count)" = 0 ] || fail "beams-react's fire should have drained the whole backlog"
pass "beams-react drained the 30-message backlog in exactly one fire"

# ---------------------------------------------------------------------------
banner "E. addressing forms: name, all, spaced comma-list, @-mentions (start/mid/end), dotted-dashed name; not-for-you excluded"
beams_b send r34 "$NAME_A" "form-direct-name" >/dev/null
beams_b send r34 all "form-all" >/dev/null
# send.sh always normalises the `to:` field to a no-space comma list, so the
# only way to exercise to_re's tolerance for SPACED commas is to build the
# message with the shared write_message helper directly (same signing path
# send.sh uses, just without its whitespace normalisation).
( export BEAMS_CONFIG_DIR="$CFG_B"
  source "$PLUGIN/lib/common.sh" >/dev/null
  beams::write_message "r34" "genb, ${NAME_A} ,carol" "form-comma-spaced" >/dev/null )
beams_b send r34 "$NAME_B" "@${NAME_A} start-of-body mention" >/dev/null
beams_b send r34 "$NAME_B" "hello @${NAME_A} in the middle of a sentence" >/dev/null
beams_b send r34 "$NAME_B" "mention at the very end @${NAME_A}" >/dev/null
beams_b send r34 someoneelse "form-not-for-you" >/dev/null

inj=$(beams_a read --inject)
for want in form-direct-name form-all form-comma-spaced 'start-of-body mention' 'in the middle of a sentence' 'mention at the very end'; do
  printf '%s\n' "$inj" | grep -qF "$want" || fail "addressing-form coverage: missing '$want' from: $inj"
done
printf '%s\n' "$inj" | grep -qF 'form-not-for-you' && fail "a message addressed to someone else leaked through the pre-filter" || true
[ "$(beams_a read --count)" = 0 ] || fail "count should be 0 after draining section E's backlog"
pass "every documented addressing form matched via --inject; a message for someone else was not delivered"

# ---------------------------------------------------------------------------
banner "F. a generic identity (no CLAUDE_PID) binds a name and 'restarts' without --force"
CFG_R="$TMP/cfg-restart"
( export BEAMS_CONFIG_DIR="$CFG_R"
  "$PLUGIN/bin/beams" init "$SHARED" >/dev/null
  "$PLUGIN/bin/beams" name genr      >/dev/null )
[ "$(jq -r '.session_name' "$CFG_R/config.json")" = genr ] || fail "initial bind did not set session_name to genr"
# name.sh's plain-rename fast path (an explicit BEAMS_CONFIG_DIR) never calls
# beams::bind_session, so it never calls beams::lease_claim either — the
# lease/reclaim machinery in lib/common.sh (beams::lease_state,
# beams::_holder_gone) belongs entirely to the Claude session-id bind path.
# A pinned-directory generic identity has nothing to contest: the directory
# itself IS the identity, restart or not.
[ ! -f "$CFG_R/lease.json" ] || fail "a pinned BEAMS_CONFIG_DIR identity should never gain a lease.json (see beams::bind_session vs name.sh's plain-rename fast path)"
restart_out="$TMP/f-restart.out"
if ! ( unset CLAUDE_PID; export BEAMS_CONFIG_DIR="$CFG_R"; "$PLUGIN/bin/beams" name genr >"$restart_out" 2>&1 ); then
  fail "generic identity could not reclaim its own name after a simulated restart: $(cat "$restart_out")"
fi
grep -q -- '--force' "$restart_out" && fail "a pinned identity's own restart should never need --force: $(cat "$restart_out")" || true
[ "$(jq -r '.session_name' "$CFG_R/config.json")" = genr ] || fail "name lost across the simulated restart"
pass "explicit-BEAMS_CONFIG_DIR identity rebinds across a simulated restart with no lease and no --force"

banner "F2. documented boundary: no BEAMS_CONFIG_DIR + no Claude session id refuses naming"
# beams::bind_session (the ONLY path name.sh falls to without an explicit
# BEAMS_CONFIG_DIR) requires beams::terminal_id (CLAUDE_CODE_SESSION_ID) and
# dies with an explicit "set BEAMS_CONFIG_DIR instead" otherwise — this is
# the documented non-Claude requirement (docs/CROSS-CLI.md: "set this per
# terminal to be unambiguous"), not a bug.
set +e
noname_out=$( ( unset BEAMS_CONFIG_DIR CLAUDE_CODE_SESSION_ID CLAUDE_PID
                 export CLAUDE_PROJECT_DIR="$TMP/proj-noname"
                 "$PLUGIN/bin/beams" name genx 2>&1 ) )
noname_rc=$?
set -e
[ "$noname_rc" -ne 0 ] || fail "naming with no BEAMS_CONFIG_DIR and no session id unexpectedly succeeded: $noname_out"
printf '%s\n' "$noname_out" | grep -q 'set BEAMS_CONFIG_DIR' || fail "expected the documented 'set BEAMS_CONFIG_DIR instead' guidance; got: $noname_out"
pass "documented boundary holds: naming with neither refuses with guidance to set BEAMS_CONFIG_DIR"

# ---------------------------------------------------------------------------
banner "G. watcher daemon on a generic identity: wake.log only, never an inbox post"
beams_a read --inject >/dev/null 2>&1 || true   # clean slate, no leftover unread
CFG_W="$CFG_A"
( export BEAMS_CONFIG_DIR="$CFG_W"
  "$PLUGIN/lib/watch.sh" start 1 --on-message "bash $(printf '%q' "$PLUGIN/lib/on-message.sh")" ) >/dev/null
wpid_file=""
for _ in $(seq 1 25); do
  wpid_file=$(find "$CFG_W/state" -maxdepth 2 -name watcher.pid 2>/dev/null | head -n1)
  [ -n "$wpid_file" ] && [ -f "$wpid_file" ] && break
  sleep 0.2
done
[ -n "$wpid_file" ] || fail "watcher did not create a pid file within 5s"
wpid=$(cat "$wpid_file")
kill -0 "$wpid" 2>/dev/null || fail "watcher pid $wpid is not alive"
ROUND_PIDS+=("$wpid")
[ ! -f "$CFG_W/inbox.json" ] || fail "a generic identity must never publish an inbox pointer (no CLAUDE_CODE_MESSAGING_SOCKET)"

beams_b send r34 "$NAME_A" "wake-test-msg" >/dev/null
wake_log="$CFG_W/wake.log"
seen=0
for _ in $(seq 1 25); do
  if [ -f "$wake_log" ] && grep -q 'wake-test-msg' "$wake_log" 2>/dev/null; then seen=1; break; fi
  sleep 0.2
done
watcher_log="$(dirname "$wpid_file")/watcher.log"
( export BEAMS_CONFIG_DIR="$CFG_W"; "$PLUGIN/lib/watch.sh" stop ) >/dev/null 2>&1 || true
[ "$seen" -eq 1 ] || fail "wake.log never recorded the new message within 5s"
[ -f "$watcher_log" ] || fail "watcher.log missing at $watcher_log"
grep -qi 'inbox' "$watcher_log" && fail "watcher.log mentions 'inbox' for a generic identity with no pointer file: $(grep -i inbox "$watcher_log")" || true
pass "generic identity's watcher appends to wake.log only; never attempts an inbox post"

green ""
green "round-34 PASS: generic-model parity — unbounded --inject/--peek by default (env-overridable), --count immune to both caps, beams-react one-fire drain, every documented addressing form, restart-reclaim with no lease/no --force, watcher wake.log-only"
