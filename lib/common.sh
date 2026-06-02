#!/usr/bin/env bash
# Shared helpers for the beams plugin. Source, don't execute.
# Portable across Linux and macOS. Requires: bash 3.2+, jq, find, date.

set -u

# Restrictive umask for every file the plugin creates. Config carries the
# session UUID + name; message files contain user content; both should not
# be world-readable on multi-user machines.
umask 077

# ── config dir resolution ───────────────────────────────────────────────────
# Identity is PER-TERMINAL so multiple Claude Code terminals on one machine
# never share a config. Precedence:
#   1. $BEAMS_CONFIG_DIR if explicitly set    (manual override; highest)
#   2. <xdg-config>/beams/sessions/$CLAUDE_CODE_SESSION_ID   (Claude Code)
#   3. <xdg-config>/beams/terminals/<pane>                   (non-Claude shells:
#      derives a per-pane key from TMUX_PANE / TERM_SESSION_ID / WT_SESSION —
#      first one set wins, so two panes in one project never collide)
#   4. <xdg-config>/beams/projects/<flat-PWD>                (last-resort fallback;
#      shells in the same dir share identity — set BEAMS_CONFIG_DIR per shell
#      to avoid this)
#
# Every Claude Code terminal has a distinct CLAUDE_CODE_SESSION_ID, so each
# one resolves to its own config dir, its own UUID, its own /beams:name. The
# id persists across resumes of the same conversation, so closing and
# reopening Claude Code keeps the same identity.
beams::_flatten_path() {
  local p="$1"
  case "$p" in
    /*) ;;
    *)  p="$(cd "$p" 2>/dev/null && pwd 2>/dev/null)" || p="$HOME" ;;
  esac
  [ -n "$p" ] || p="$HOME"
  printf '%s' "$p" | sed 's,/,-,g'
}

beams::project_dir() {
  local p="${CLAUDE_PROJECT_DIR:-$PWD}"
  [ -n "$p" ] || p="$HOME"
  printf '%s' "$p"
}

beams::terminal_id() {
  printf '%s' "${CLAUDE_CODE_SESSION_ID:-}"
}

beams::_safe_key() {
  # Sanitise a user string into ONE safe path component: rewrite anything
  # outside the allowlist to '_', then reject the degenerate forms that could
  # escape the directory (empty, '.', '..', dotfiles, leading dash, embedded
  # '..'). Same hardening as the pane-key path below.
  local k; k=$(printf '%s' "${1:-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  case "$k" in
    ''|.|..|.*|-*|*..*) printf ''; return 0 ;;
  esac
  printf '%s' "$k"
}

beams::_resolve_config_dir() {
  if [ -n "${BEAMS_CONFIG_DIR:-}" ]; then
    printf '%s' "$BEAMS_CONFIG_DIR"
    return 0
  fi
  local base="${XDG_CONFIG_HOME:-$HOME/.config}/beams"
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    # A session may be BOUND to a durable, name-keyed identity so its config
    # survives a Claude restart that hands out a fresh session id. The pointer
    # lives in the per-session dir and names the identity; resolution then
    # redirects to projects/<project>/identities/<name>. An unbound session
    # keeps using its ephemeral per-session dir (empty → "not initialised"
    # until the SessionStart hook auto-binds it to the project's lone free
    # identity, when exactly one is bindable).
    local sdir="$base/sessions/$CLAUDE_CODE_SESSION_ID"
    if [ -f "$sdir/bound" ]; then
      local bname; bname=$(beams::_safe_key "$(cat "$sdir/bound" 2>/dev/null)")
      if [ -n "$bname" ]; then
        printf '%s/projects/%s/identities/%s' \
          "$base" "$(beams::_flatten_path "$(beams::project_dir)")" "$bname"
        return 0
      fi
    fi
    printf '%s' "$sdir"
    return 0
  fi
  # Non-Claude shells (Codex, Gemini, plain bash, local-LLM orchestrators):
  # prefer a per-pane id from the terminal multiplexer / terminal app so two
  # panes in the same project don't collide on one identity. TMUX_PANE wins
  # over the host terminal's own id because tmux nests inside iTerm/WT and
  # gives a finer-grained key. We deliberately do NOT consult $WINDOWID —
  # it's the X11 *window* id, so two split panes inside one gnome-terminal
  # window share it and would silently share identity. If none of these are
  # set (plain xterm, no tmux, no WT), fall through to the per-PWD key and
  # advise setting BEAMS_CONFIG_DIR explicitly.
  local pane="${TMUX_PANE:-${TERM_SESSION_ID:-${WT_SESSION:-}}}"
  if [ -n "$pane" ]; then
    local pane_key; pane_key=$(printf '%s' "$pane" | tr -c 'A-Za-z0-9._-' '_')
    # Sanitise-and-reject: even after `tr` rewrites unsafe chars to `_`, the
    # allowlist permits `.` and `-`, so an attacker (or a stray dotfile) that
    # controls TMUX_PANE can still send `..` / `.` / `....-..` / `-flag` /
    # `.hidden` — which collapse to a parent dir (silently clobbering legacy
    # configs), hide as dotdirs, or look like CLI flags. Reject those and
    # fall through to the per-project key.
    case "$pane_key" in
      ''|.|..|.*|-*|*..*) pane_key='' ;;
    esac
    if [ -n "$pane_key" ]; then
      printf '%s/terminals/%s' "$base" "$pane_key"
      return 0
    fi
  fi
  # Last resort: per-project key. Multiple shells in one PWD will share it.
  local key; key=$(beams::_flatten_path "$(beams::project_dir)")
  printf '%s/projects/%s' "$base" "$key"
}

# Remember whether the user explicitly set the path, for the legacy hint.
BEAMS_CONFIG_DIR_EXPLICIT="${BEAMS_CONFIG_DIR:-}"
BEAMS_CONFIG_DIR="$(beams::_resolve_config_dir)"
BEAMS_CONFIG_FILE="$BEAMS_CONFIG_DIR/config.json"
BEAMS_LEGACY_CONFIG_FILE="$HOME/.config/beams/config.json"
BEAMS_IDENTITY_KEY="$BEAMS_CONFIG_DIR/identity.key"
BEAMS_BASE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/beams"
# A durable identity is "in use" while the session holding it was seen within
# this window; past it the lease is treated as released (the holder went away),
# so a name frees up after an idle/closed session without manual cleanup.
BEAMS_INUSE_STALE_SECONDS="${BEAMS_INUSE_STALE_SECONDS:-900}"

# ── output ──────────────────────────────────────────────────────────────────
beams::err() { printf 'beams: %s\n' "$*" >&2; }
beams::die() { beams::err "$*"; exit 1; }

# ── dependencies ────────────────────────────────────────────────────────────
beams::require() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || beams::die "missing required command: $cmd"
  done
}

# ── UUID generation (portable) ──────────────────────────────────────────────
beams::uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    beams::die "no UUID generator available (need uuidgen or python3)"
  fi
}

# ── timestamps ──────────────────────────────────────────────────────────────
beams::now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
beams::now_compact() { date -u +'%Y%m%dT%H%M%SZ'; }

# ── config I/O ──────────────────────────────────────────────────────────────
beams::config_exists() { [ -f "$BEAMS_CONFIG_FILE" ]; }

beams::config_require() {
  if beams::config_exists; then return 0; fi
  # Helpful hint when a legacy single-config exists but isn't being used.
  if [ -z "$BEAMS_CONFIG_DIR_EXPLICIT" ] \
     && [ -f "$BEAMS_LEGACY_CONFIG_FILE" ] \
     && [ "$BEAMS_CONFIG_FILE" != "$BEAMS_LEGACY_CONFIG_FILE" ]; then
    beams::err "no config for this terminal session yet."
    beams::err "  terminal session: ${CLAUDE_CODE_SESSION_ID:-<not set — running outside Claude Code?>}"
    beams::err "  expected config:  $BEAMS_CONFIG_FILE"
    beams::err ""
    beams::err "  found legacy single-config at: $BEAMS_LEGACY_CONFIG_FILE"
    beams::err "    (in the old layout all terminals shared one identity — that's the bug)"
    beams::err ""
    beams::err "  pick one:"
    beams::err "    /beams:admin init <shared-path>"
    beams::err "       → fresh per-terminal identity here (recommended — /beams:name only affects this terminal)"
    beams::err "    BEAMS_CONFIG_DIR=$HOME/.config/beams <cmd>"
    beams::err "       → keep using the legacy shared identity"
    exit 1
  fi
  beams::die "not initialised — run /beams:start first"
}

beams::config_get() {
  # $1 = jq filter (e.g. '.session_id'); falls back to "" on null/missing
  jq -r "${1} // \"\"" "$BEAMS_CONFIG_FILE"
}

beams::config_set() {
  # $1 = jq update expression, e.g. '.session_name = $v' with --arg v "foo"
  # Remaining args are passed to jq verbatim (for --arg / --argjson).
  local expr="$1"; shift
  local tmp="${BEAMS_CONFIG_FILE}.tmp.$$"
  jq "$@" "$expr" "$BEAMS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$BEAMS_CONFIG_FILE"
}

beams::react_flag() {
  # Read a boolean under .react (e.g. "on_stop"). Echoes "true" ONLY when the
  # flag is explicitly JSON true; absent, null, false, or anything else echo ""
  # (off). Callers test: [ "$(beams::react_flag on_stop)" = "true" ].
  # NOTE: because config_get appends `// ""` and jq's `//` collapses false → "",
  # this CANNOT express "explicitly off" — fine for an opt-IN flag like on_stop
  # (default false), but do NOT use it to gate a DEFAULT-ON flag's opt-out.
  # watch_on_boot now DEFAULTS TRUE (see config_init_file) and is read with a raw
  # jq that keeps false distinct (hooks/check-on-start.sh), not via react_flag.
  [ "$(beams::config_get ".react.$1")" = "true" ] && printf 'true' || printf ''
}

# ── named identities, session binding, and the in-use lease ─────────────────
# A Claude Code session id is ephemeral: a fresh start gets a new one, which
# would orphan the per-session config (the "not initialised after restart"
# bug). So identity is anchored on a NAME the user picks — the same one
# /beams:name sets — keyed per project at
#   <base>/projects/<project>/identities/<name>/
# A session BINDS to one via the pointer <base>/sessions/<id>/bound, which
# resolution follows. A lease (lease.json) records which session currently
# holds a name and when it was last seen, so two live sessions don't silently
# share one identity.

beams::_project_key() { beams::_flatten_path "$(beams::project_dir)"; }

beams::identities_dir() {
  printf '%s/projects/%s/identities' "$BEAMS_BASE_DIR" "$(beams::_project_key)"
}

beams::list_identity_names() {     # one name per line (only those with a config)
  local d p; d=$(beams::identities_dir)
  [ -d "$d" ] || return 0
  for p in "$d"/*/; do
    [ -f "${p}config.json" ] || continue
    printf '%s\n' "$(basename "$p")"
  done
}

beams::project_shared_path() {     # inherit the shared folder from any sibling identity
  local d f; d=$(beams::identities_dir)
  [ -d "$d" ] || return 0
  for f in "$d"/*/config.json; do
    [ -f "$f" ] || continue
    jq -r '.shared_path // empty' "$f" 2>/dev/null
    return 0
  done
}

beams::bound_name() {              # echoes the name this session is bound to, if any
  local sid pf; sid=$(beams::terminal_id); [ -n "$sid" ] || return 0
  pf="$BEAMS_BASE_DIR/sessions/$sid/bound"
  [ -f "$pf" ] && beams::_safe_key "$(cat "$pf" 2>/dev/null)"
}

beams::_now_epoch() { date -u +%s; }
beams::lease_file() { printf '%s/lease.json' "${1:-$BEAMS_CONFIG_DIR}"; }

# Hostname recorded in each lease so a reclaim can tell "the holder was on THIS
# machine" (its liveness is checkable here) from "the holder is on another
# machine" (only its heartbeat clock can speak for it).
beams::_host() { hostname 2>/dev/null || printf 'unknown'; }

# Is Claude session <sid> still alive ON THIS HOST? echoes: alive | dead | unknown.
# A live Claude session exports CLAUDE_CODE_SESSION_ID=<sid> into its own (and its
# children's) environment, so a match anywhere under /proc means alive and no
# match means dead. Only a Linux host with a readable /proc can answer; anywhere
# else we say 'unknown' and the caller keeps trusting the heartbeat window.
#   TEST SEAM: BEAMS_FAKE_LIVE_SESSIONS (comma-separated) — when set, only the
#   listed ids are 'alive' and every other id is 'dead', so the suite can drive
#   liveness deterministically without spawning processes or needing /proc.
beams::_session_alive_local() {
  local sid="$1"
  [ -n "$sid" ] || { printf 'unknown'; return 0; }
  if [ -n "${BEAMS_FAKE_LIVE_SESSIONS:-}" ]; then
    case ",$BEAMS_FAKE_LIVE_SESSIONS," in
      *",$sid,"*) printf 'alive' ;;
      *)          printf 'dead'  ;;
    esac
    return 0
  fi
  [ -d /proc ] && [ -r /proc/self/environ ] || { printf 'unknown'; return 0; }
  # Concatenate every readable environ blob, split NUL→newline, and capture the
  # exact id line if present. We test the captured TEXT (not the pipeline exit),
  # and `|| true` swallows cat's failures on unreadable other-user procs — so the
  # verdict is correct under both `set -e` and `set -o pipefail`.
  local hit
  hit=$( { cat /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' \
             | grep -Fx "CLAUDE_CODE_SESSION_ID=$sid"; } || true )
  [ -n "$hit" ] && printf 'alive' || printf 'dead'
}

# Can we PROVE the lease holder is gone, so its name is reclaimable without
# --force? Only when the lease was taken on THIS host AND that session no longer
# runs here — e.g. a Claude restart left its own lease behind. A holder on another
# machine, a host with no /proc, or a pre-host-field lease all yield 'no' (we
# can't see those processes, so the heartbeat window still rules). echoes: yes | no.
beams::_holder_gone() {
  local lf="$1" lhost holder
  lhost=$(jq -r '.host // ""'           "$lf" 2>/dev/null)
  holder=$(jq -r '.bound_session // ""' "$lf" 2>/dev/null)
  [ -n "$holder" ] && [ -n "$lhost" ] && [ "$lhost" = "$(beams::_host)" ] || { printf 'no'; return 0; }
  [ "$(beams::_session_alive_local "$holder")" = dead ] && printf 'yes' || printf 'no'
}

beams::lease_claim() {             # current session takes the lease on $BEAMS_CONFIG_DIR
  local lf tmp; lf=$(beams::lease_file); tmp="${lf}.tmp.$$"
  mkdir -p "$(dirname "$lf")"
  jq -n --arg s "$(beams::terminal_id)" --arg h "$(beams::_host)" --argjson t "$(beams::_now_epoch)" \
    '{bound_session:$s, host:$h, last_seen:$t}' > "$tmp" 2>/dev/null && mv "$tmp" "$lf" || rm -f "$tmp"
}

beams::lease_refresh() {           # bump last_seen iff this session holds the lease
  local lf tmp holder; lf=$(beams::lease_file); [ -f "$lf" ] || return 0
  holder=$(jq -r '.bound_session // ""' "$lf" 2>/dev/null)
  [ "$holder" = "$(beams::terminal_id)" ] || return 0
  tmp="${lf}.tmp.$$"
  jq --argjson t "$(beams::_now_epoch)" '.last_seen = $t' "$lf" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$lf" || rm -f "$tmp"
}

beams::lease_state() {             # $1 = identity dir; echoes: free | mine | busy:<age-secs>
  local lf holder seen age; lf=$(beams::lease_file "${1:-$BEAMS_CONFIG_DIR}")
  [ -f "$lf" ] || { printf 'free'; return 0; }
  holder=$(jq -r '.bound_session // ""' "$lf" 2>/dev/null)
  [ -n "$holder" ] || { printf 'free'; return 0; }
  [ "$holder" = "$(beams::terminal_id)" ] && { printf 'mine'; return 0; }
  seen=$(jq -r '.last_seen // 0' "$lf" 2>/dev/null)
  age=$(( $(beams::_now_epoch) - seen ))
  [ "$age" -ge "$BEAMS_INUSE_STALE_SECONDS" ] && { printf 'free'; return 0; }
  # Inside the heartbeat window the holder still looks active — UNLESS it was
  # this host's own session and that session is already gone (a Claude restart
  # leaves its lease behind for up to BEAMS_INUSE_STALE_SECONDS). Then the name
  # isn't really in use: free it so the restarted terminal reclaims it with no
  # --force. Holders on other machines stay busy — we can't see their processes.
  [ "$(beams::_holder_gone "$lf")" = yes ] && { printf 'free'; return 0; }
  printf 'busy:%s' "$age"
}

beams::bind_session() {
  # Bind THIS session to the durable identity <name> in this project: rebind to
  # an existing one (restoring its UUID + subscriptions), migrate a not-yet-bound
  # scratch config into one, or create a fresh one (inheriting the project's
  # shared folder). Pass --force to take over a name another live session still
  # holds. Reassigns the module config globals to the identity so every helper
  # below operates on it.
  local force="" name=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) [ -z "$name" ] && name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || beams::die "usage: name.sh <friendly-name> [--force]"
  beams::valid_name "$name" || beams::die "invalid name: $name (allowed: A-Z a-z 0-9 . _ -, length 1-64)"
  local key; key=$(beams::_safe_key "$name")
  [ -n "$key" ] || beams::die "name '$name' is not usable as an identity key"
  local sid; sid=$(beams::terminal_id)
  [ -n "$sid" ] || beams::die "binding needs a Claude Code session id; outside Claude Code, set BEAMS_CONFIG_DIR instead"

  local sdir="$BEAMS_BASE_DIR/sessions/$sid"
  local scratch="$sdir/config.json"
  local idir; idir="$(beams::identities_dir)/$key"
  local action

  # Serialize the lease-check → claim → bound-pointer write below so two
  # concurrent binds to the SAME identity (e.g. two auto-binding SessionStart
  # hooks on a multi-terminal cold start) can't both pass the lease gate and
  # end up sharing one UUID/key. mkdir is atomic everywhere (incl. NFS) — the
  # same idiom as watch.sh's start lock. The loser blocks ~one critical section,
  # then reads the now-claimed lease as busy and is refused (unless --force).
  # Released right after the bound write; the trap is the die/crash safety net.
  mkdir -p "$(dirname "$idir")"
  local lock_dir="${idir}.bindlock" __bind_wait=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    __bind_wait=$((__bind_wait + 1))
    [ "$__bind_wait" -gt 50 ] && beams::die "name '$name' is being bound by another session (stale lock? rmdir '$lock_dir')"
    sleep 0.1
  done
  # Safety net for the beams::die / unexpected-exit paths inside the critical
  # section; the lock is released explicitly at its end. bind_session OWNS the
  # EXIT trap here and clears it on completion — callers must not rely on an
  # EXIT trap surviving this call (none do). We deliberately do NOT save/restore
  # via `eval "$(trap -p EXIT)"`: that re-eval corrupts any trap body containing
  # a single quote.
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

  if [ -f "$idir/config.json" ]; then
    # Existing identity → lease gate, then rebind (config/UUID kept as-is).
    local state; state=$(beams::lease_state "$idir")
    case "$state" in
      busy:*)
        [ -n "$force" ] || beams::die "name '$name' is in use by another active session (last seen ${state#busy:}s ago).
  re-run with --force to take it over (e.g. you just restarted), or pick another name."
        ;;
    esac
    action="rebound to"
  elif [ -f "$scratch" ]; then
    # This session ran init but isn't bound yet → migrate the scratch config
    # into the durable identity (preserves its UUID, key, and subscriptions).
    mkdir -p "$idir"
    mv "$scratch" "$idir/config.json"
    [ -f "$sdir/identity.key" ] && mv "$sdir/identity.key" "$idir/identity.key"
    action="created"
  else
    # Brand-new identity → inherit the project's shared folder from a sibling.
    local shared; shared=$(beams::project_shared_path)
    [ -n "$shared" ] || beams::die "no beams identity in this project yet — run /beams:start to choose the shared folder first"
    mkdir -p "$idir"
    BEAMS_CONFIG_DIR="$idir"; BEAMS_CONFIG_FILE="$idir/config.json"; BEAMS_IDENTITY_KEY="$idir/identity.key"
    beams::config_init_file "$shared" >/dev/null
    beams::ensure_identity_key
    action="created"
  fi

  # Operate as the identity from here on.
  BEAMS_CONFIG_DIR="$idir"; BEAMS_CONFIG_FILE="$idir/config.json"; BEAMS_IDENTITY_KEY="$idir/identity.key"
  beams::config_set '.session_name = $v' --arg v "$name"
  beams::lease_claim
  mkdir -p "$sdir"; printf '%s' "$key" > "$sdir/bound"
  rmdir "$lock_dir" 2>/dev/null || true; trap - EXIT   # end of critical section

  # Re-publish presence so peers see this session live on its subscriptions.
  local beam
  while IFS= read -r beam; do
    [ -n "$beam" ] || continue
    beams::beam_exists "$beam" && beams::write_member_record "$beam"
  done < <(jq -r '.beams[]?' "$BEAMS_CONFIG_FILE")

  # Best-effort window title — works in a real terminal, silently skips when
  # there's no controlling TTY (e.g. the VS Code Claude Code integration). The
  # group redirects stderr FIRST so a failed open of /dev/tty (ENXIO when there
  # is no controlling terminal) can't leak onto the user's output.
  { printf '\033]2;beams:%s\007' "$name" >/dev/tty; } 2>/dev/null || true

  printf 'beams: %s "%s"%s\n' "$action" "$name" "$([ -n "$force" ] && printf ' (forced takeover)')"
}

beams::config_init_file() {
  # Write a fresh config with shared_path + session_id. $1 = shared_path.
  local shared_path="$1"
  local sid
  sid=$(beams::uuid)
  mkdir -p "$BEAMS_CONFIG_DIR"
  jq -n \
    --arg sp "$shared_path" \
    --arg sid "$sid" \
    --arg cc_sid "${CLAUDE_CODE_SESSION_ID:-}" \
    --arg created "$(beams::now_iso)" \
    '{
      version: 1,
      shared_path: $sp,
      session_id: $sid,
      session_name: "",
      claude_code_session_id: $cc_sid,
      beams: [],
      created: $created,
      react: { watch_on_boot: true, on_stop: false }
    }' > "$BEAMS_CONFIG_FILE"
  printf '%s' "$sid"
}

# ── shared-folder paths ─────────────────────────────────────────────────────
beams::shared_root() { beams::config_get '.shared_path'; }

beams::beam_dir()      { printf '%s/beams/%s' "$(beams::shared_root)" "$1"; }
beams::beam_messages() { printf '%s/beams/%s/messages' "$(beams::shared_root)" "$1"; }
beams::beam_members()  { printf '%s/beams/%s/members' "$(beams::shared_root)" "$1"; }

beams::state_dir() {
  # Per-session local state (cursors, etc). Lives under config dir, NOT shared,
  # so cursors are independent per session even if config is on the share.
  local sid; sid=$(beams::config_get '.session_id')
  printf '%s/state/%s' "$BEAMS_CONFIG_DIR" "$sid"
}

beams::cursor_file() {
  # Per-beam cursor for "what's the newest message I've already processed
  # and delivered to the model". Advanced by the hook and /beams:read.
  printf '%s/cursor.%s' "$(beams::state_dir)" "$1"
}

beams::notify_cursor_file() {
  # Per-beam cursor for "what's the newest message I've already shown the user
  # via a desktop notification". Advanced by the watcher (and also by the hook,
  # so we never re-notify after delivery).
  printf '%s/notified.%s' "$(beams::state_dir)" "$1"
}

# ── beam validation ──────────────────────────────────────────────────────────
beams::beam_exists() { [ -d "$(beams::beam_dir "$1")" ]; }
beams::is_subscribed() {
  # $1 = beam name. Returns 0 if subscribed.
  jq -e --arg b "$1" '.beams | index($b) != null' "$BEAMS_CONFIG_FILE" >/dev/null 2>&1
}

beams::valid_name() {
  # Beam and session names: 1-64 chars from [A-Za-z0-9._-], with explicit
  # rejection of "." and ".." (which would otherwise be valid by the regex
  # and would let a beam name resolve OUTSIDE the beams/ subtree on disk).
  # Also reject leading "." to avoid hidden files/dirs.
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
  case "$1" in
    .|..|.*) return 1 ;;
  esac
  return 0
}

# ── manifest / driver / lock / ban ──────────────────────────────────────────
# The "driver" of a beam is its admin. Older manifests stored this under
# `manager`; new code reads both (driver wins, manager is the fallback) and
# new writes use `driver` (and drop the legacy `manager` key) so manifests
# migrate naturally on any driver-action without an explicit step.
beams::manifest_file() { printf '%s/manifest.json' "$(beams::beam_dir "$1")"; }

beams::manifest_get() {
  # $1 = beam, $2 = jq filter (e.g. '.driver')
  local mf; mf=$(beams::manifest_file "$1")
  [ -f "$mf" ] || { printf ''; return 0; }
  jq -r "${2} // \"\"" "$mf" 2>/dev/null || printf ''
}

beams::manifest_set() {
  # $1 = beam, $2 = jq expression, remaining args passed to jq.
  # Every write also migrates any legacy `manager` field to `driver`, so a
  # beam created on an old version of the plugin gets normalised the first
  # time anyone modifies its manifest.
  local beam="$1"; shift
  local expr="$1"; shift
  local mf; mf=$(beams::manifest_file "$beam")
  [ -f "$mf" ] || beams::die "beam '$beam' has no manifest"
  local tmp="${mf}.tmp.$$"
  jq "$@" "(.driver = (.driver // .manager)) | del(.manager) | (${expr})" \
    "$mf" > "$tmp" && mv "$tmp" "$mf"
}

beams::driver_uuid() {
  # Resolve the beam driver's UUID, reading `.driver` first and falling back
  # to the legacy `.manager` field. Echoes empty if neither is set.
  local mf; mf=$(beams::manifest_file "$1")
  [ -f "$mf" ] || { printf ''; return 0; }
  jq -r '(.driver // .manager // "")' "$mf" 2>/dev/null
}

beams::is_driver() {
  # $1 = beam. Returns 0 if our session is the beam driver.
  local sid drv
  sid=$(beams::config_get '.session_id')
  drv=$(beams::driver_uuid "$1")
  [ -n "$drv" ] && [ "$drv" = "$sid" ]
}

beams::set_driver() {
  # $1 = beam, $2 = new driver UUID. manifest_set already drops legacy .manager.
  beams::manifest_set "$1" '.driver = $d' --arg d "$2"
}

beams::is_locked() {
  # $1 = beam. Returns 0 if a lock is set.
  local mf; mf=$(beams::manifest_file "$1")
  [ -f "$mf" ] || return 1
  jq -e '.locked != null and .locked != {}' "$mf" >/dev/null 2>&1
}

beams::lock_reason() {
  beams::manifest_get "$1" '.locked.reason'
}

beams::is_banned() {
  # $1 = beam, $2 = target uuid (defaults to our own sid).
  local beam="$1"
  local target="${2:-$(beams::config_get '.session_id')}"
  local mf; mf=$(beams::manifest_file "$beam")
  [ -f "$mf" ] || return 1
  jq -e --arg t "$target" '.banned // [] | index($t) != null' "$mf" >/dev/null 2>&1
}

beams::resolve_member() {
  # $1 = beam, $2 = name-or-uuid. Echoes the canonical UUID if found, else empty.
  #
  # SECURITY: the returned id is used by callers to build file paths — e.g.
  # kick.sh runs `rm -f "$members_dir/$id.json"`. A hostile shared-folder
  # participant can plant a member record whose ".id" is a path-traversal
  # string ("../../../../home/victim/.../config"); if we returned that, the
  # driver's next kick would delete an arbitrary .json on the victim's box.
  # So EVERY returned value is validated as a bare UUID before it leaves here.
  local beam="$1" who="$2"
  local mdir; mdir=$(beams::beam_members "$beam")
  [ -d "$mdir" ] || { printf ''; return 0; }
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  # Already a uuid that exists as a member? (member files are named <uuid>.json,
  # so a non-uuid `who` could only "match" via traversal — require the uuid form.)
  if [[ "$who" =~ $uuid_re ]] && [ -f "$mdir/$who.json" ]; then printf '%s' "$who"; return 0; fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local id name
    id=$(jq -r '.id // ""' "$f" 2>/dev/null)
    name=$(jq -r '.name // ""' "$f" 2>/dev/null)
    if [ "$name" = "$who" ] && [[ "$id" =~ $uuid_re ]]; then printf '%s' "$id"; return 0; fi
  done < <(find "$mdir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
  printf ''
}

# ── frontmatter helpers ─────────────────────────────────────────────────────
# Extract a frontmatter field's value. Robust to:
#   - colons in the value (timestamps): captures everything after the first
#     ": " separator, not just up to the next ":".
#   - prefix-name collisions: `from` no longer matches `from_name`, since
#     the pattern anchors on the literal ": " and requires the line to end
#     after the value (\1$).
# Callers must pass literal field names with no regex metacharacters; that's
# enforced by convention (all field names are short ASCII identifiers).
beams::fm_field() {
  # $1 = frontmatter text, $2 = field name. Echoes value or empty.
  printf '%s\n' "$1" | sed -n "s/^${2}: \\(.*\\)\$/\\1/p" | head -n 1
}

# Content-aware frontmatter / body extractors. They take the full file
# content as a string argument so callers can read the file ONCE and pass
# the result everywhere. Reading once protects against TOCTOU races where
# a hostile peer could swap the file content on the share between
# validation and rendering.
beams::extract_fm() {
  printf '%s\n' "$1" | awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print} n>=2{exit}'
}
beams::extract_body() {
  printf '%s\n' "$1" | awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}'
}

# ── cryptographic identity (Ed25519) ────────────────────────────────────────
# Each session keeps a private Ed25519 key in its config dir and publishes
# the public key in its member record on every beam it joins. Every message
# the session sends is signed; every message a session receives is verified
# against the sender's published pubkey IF one is published (migration:
# sessions that pre-date this feature have no pubkey, so their unsigned
# messages still flow until they upgrade).
#
# Forgery is the actual attack we defend against: someone with raw write
# access to the shared folder can drop a file claiming to be from any UUID,
# but without that session's private key the signature won't verify and the
# message is rejected at the gate (before token spend).

beams::ensure_identity_key() {
  # Idempotent: generate ed25519 keypair if not present. chmod private 0600.
  if [ -f "$BEAMS_IDENTITY_KEY" ]; then return 0; fi
  command -v openssl >/dev/null 2>&1 \
    || beams::die "openssl is required for cryptographic signing — install it (apt install openssl / brew install openssl)"
  mkdir -p "$BEAMS_CONFIG_DIR"
  if ! openssl genpkey -algorithm Ed25519 -out "$BEAMS_IDENTITY_KEY" 2>/dev/null; then
    beams::die "openssl could not generate an Ed25519 key (your openssl may be too old; need >= 1.1.1)"
  fi
  chmod 600 "$BEAMS_IDENTITY_KEY"
}

# Portable base64-no-newlines. macOS BSD base64 has no -w flag (default is
# 60-char line wrap), so `base64 -w0` only works on GNU coreutils. Pipe to
# `tr -d '\n'` for cross-platform single-line output.
beams::_b64() { base64 | tr -d '\n'; }

beams::pubkey_b64() {
  # Echo our public key as base64-of-DER. Empty string if not initialised.
  [ -f "$BEAMS_IDENTITY_KEY" ] || { printf ''; return 0; }
  openssl pkey -in "$BEAMS_IDENTITY_KEY" -pubout -outform DER 2>/dev/null | beams::_b64
}

beams::fingerprint() {
  # Short human-readable fingerprint of OUR pubkey (first 16 hex of sha256).
  [ -f "$BEAMS_IDENTITY_KEY" ] || { printf ''; return 0; }
  openssl pkey -in "$BEAMS_IDENTITY_KEY" -pubout -outform DER 2>/dev/null \
    | sha256sum | cut -c1-16
}

# Why no beams::canonicalize() function:
# Bash strings cannot hold NUL bytes (the shell strips them on capture).
# ── trust-on-first-use (TOFU) pinned-key store ──────────────────────────────
# The pubkey used to VERIFY a sender's signature must be anchored locally, not
# trusted from the shared member record at verify time — a shared-folder
# attacker can overwrite members/<uuid>.json with their own key (or remove it)
# and impersonate/downgrade. So on the first successful contact with a sender
# UUID we PIN its pubkey under the user's LOCAL base (never the shared folder);
# later messages verify against the pin. Same-UID-shell trust tier as
# identity.key. Keyed by UUID (one identity, one key). To re-pin after a
# legitimate key rotation, delete the pin file (SSH known_hosts style).
beams::known_keys_dir() { printf '%s/known_keys' "$BEAMS_BASE_DIR"; }

beams::known_key_get() {
  # $1 = sender uuid. Echoes the pinned base64 pubkey, or empty if not pinned.
  local uuid="$1"
  case "$uuid" in ''|*[!0-9a-f-]*) printf ''; return 0 ;; esac
  local f; f="$(beams::known_keys_dir)/$uuid"
  { [ -f "$f" ] && [ ! -L "$f" ]; } || { printf ''; return 0; }
  local k; IFS= read -r k < "$f" 2>/dev/null || true
  printf '%s' "$k"
}

beams::known_key_pin() {
  # $1 = sender uuid, $2 = base64 pubkey. First-use only — NEVER overwrites an
  # existing pin (a changed key must be re-pinned by deleting the file).
  # Written via mktemp+rename so a planted symlink at the pin path can't
  # redirect the write to a victim file.
  local uuid="$1" pub="$2"
  case "$uuid" in ''|*[!0-9a-f-]*) return 0 ;; esac
  [ -n "$pub" ] || return 0
  local dir f tmp; dir="$(beams::known_keys_dir)"; f="$dir/$uuid"
  [ -L "$f" ] && rm -f "$f"          # never follow a planted symlink
  [ -e "$f" ] && return 0            # already pinned
  mkdir -p "$dir" 2>/dev/null; chmod 700 "$dir" 2>/dev/null || true
  tmp=$(mktemp "$dir/.pin.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$pub" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# To get an unambiguous canonical that protects against ANY field value
# (newlines, separators) shifting the parse, we write the canonical bytes
# directly to a file with NUL separators, then hand the file to openssl.
# The header fields are NUL-separated; the body is appended verbatim AFTER
# a final NUL. Receiver does the identical write, so identical bytes hit
# the verifier.
#
# `fmt` versions the signed field set so the wire format can grow without a
# flag day: fmt 1 (legacy, the absent default) signs id,beam,from,to,ts,body;
# fmt 2 also signs from_name (so a third party can't relabel someone's signed
# message). A receiver verifies against the fmt the message declares — an old
# receiver checking a fmt-2 message it doesn't understand falls to the legacy
# canonical and simply fails closed; old fmt-1 messages keep verifying as before.
beams::_write_canonical() {
  # $1 = destination file path
  # $2 = fmt ("1" legacy | "2")
  # $3..$8 = id beam from from_name to ts
  # $9 = body
  {
    if [ "$2" = "2" ]; then
      printf '%s\0' "$3" "$4" "$5" "$6" "$7" "$8"   # id beam from from_name to ts
    else
      printf '%s\0' "$3" "$4" "$5" "$7" "$8"        # id beam from to ts (no from_name)
    fi
    printf '%s'   "$9"
  } > "$1"
}

beams::sign_canonical() {
  # Args: <fmt> <id> <beam> <from> <from_name> <to> <ts> <body>. Echo base64
  # signature, nonzero on failure. Bytes never round-trip through a bash var.
  command -v openssl >/dev/null 2>&1 || return 1
  [ -f "$BEAMS_IDENTITY_KEY" ]      || return 1
  local td; td=$(mktemp -d)
  beams::_write_canonical "$td/msg" "$@"
  local rc=0
  openssl pkeyutl -sign -inkey "$BEAMS_IDENTITY_KEY" -rawin -in "$td/msg" \
    > "$td/sig" 2>/dev/null || rc=1
  if [ $rc -eq 0 ]; then beams::_b64 < "$td/sig"; fi
  rm -rf "$td"
  return $rc
}

beams::verify_canonical() {
  # $1 = base64 sig, $2 = base64 pubkey (DER).
  # $3.. = fmt id beam from from_name to ts body  (the canonical's arg list)
  # Returns 0 if signature is valid against the canonical of those fields.
  local sig_b64="$1" pubkey_b64="$2"
  shift 2
  [ -n "$sig_b64" ] && [ -n "$pubkey_b64" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  local td; td=$(mktemp -d)
  beams::_write_canonical "$td/msg" "$@"
  printf '%s' "$sig_b64"    | base64 -d 2>/dev/null > "$td/sig"
  printf '%s' "$pubkey_b64" | base64 -d 2>/dev/null > "$td/pub.der"
  local rc=0
  openssl pkeyutl -verify -pubin -inkey "$td/pub.der" -keyform DER \
    -rawin -in "$td/msg" -sigfile "$td/sig" >/dev/null 2>&1 || rc=1
  rm -rf "$td"
  return $rc
}

# ── message validation ──────────────────────────────────────────────────────
# Cheap pre-read gate, invoked before any message is delivered to the model
# or fired as a notification. Returns 0 if the file is well-formed and from
# a plausible sender, 1 otherwise. Failing files are silently skipped — no
# error, no token spend.
BEAMS_MSG_MAX_SIZE=102400       # 100 KB total file size
BEAMS_MSG_MAX_BODY=10240        #  10 KB body length

beams::msg_validate() {
  # $1 = file content (read once by caller, passed in to eliminate TOCTOU
  #      with a peer swapping the file between validation and rendering)
  # $2 = file path (only used for size cap, beam-vs-dir cross-check, and
  #      looking up the sender's member record / per-beam signature policy)
  local content="$1" f="$2"
  [ -f "$f" ] || return 1

  # Size cap — based on the in-memory content we already have.
  [ "${#content}" -le "$BEAMS_MSG_MAX_SIZE" ] || return 1

  # Pull frontmatter.
  local fm; fm=$(beams::extract_fm "$content") || return 1
  [ -n "$fm" ] || return 1

  # Required fields.
  local m_id m_beam m_from m_ts
  m_id=$(  beams::fm_field "$fm" id)
  m_beam=$( beams::fm_field "$fm" beam)
  m_from=$(beams::fm_field "$fm" from)
  m_ts=$(  beams::fm_field "$fm" ts)
  [ -n "$m_id" ] && [ -n "$m_beam" ] && [ -n "$m_from" ] && [ -n "$m_ts" ] || return 1

  # UUID-ish (8-4-4-4-12 lowercase hex).
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [[ "$m_id"   =~ $uuid_re ]] || return 1
  [[ "$m_from" =~ $uuid_re ]] || return 1

  # Anti-spoof: `beam` field MUST match the directory the file is in.
  local actual_beam beam_root
  beam_root=$(dirname "$(dirname "$f")")
  actual_beam=$(basename "$beam_root")
  [ "$m_beam" = "$actual_beam" ] || return 1

  # Sender membership.
  local members_dir="$beam_root/members"
  [ -f "$members_dir/$m_from.json" ] || return 1

  # Body length — extract from in-memory content (no re-read).
  local body; body=$(beams::extract_body "$content")
  [ "${#body}" -le "$BEAMS_MSG_MAX_BODY" ] || return 1

  # Signature policy:
  #   - Sender has published a pubkey → sig required and verified.
  #   - Sender has no pubkey AND beam has require_signatures=false (default)
  #     → unsigned accepted (back-compat for the migration window).
  #   - Beam has require_signatures=true → reject unsigned regardless.
  local manifest="$beam_root/manifest.json"
  local require_sig=false
  if [ -f "$manifest" ]; then
    require_sig=$(jq -r '.require_signatures // false' "$manifest" 2>/dev/null)
  fi

  local m_sig;       m_sig=$(beams::fm_field "$fm" sig)
  local m_to;        m_to=$(beams::fm_field "$fm" to)
  local m_fmt;       m_fmt=$(beams::fm_field "$fm" fmt); [ -n "$m_fmt" ] || m_fmt=1
  local m_from_name; m_from_name=$(beams::fm_field "$fm" from_name)

  # TOFU verification. The verifying key is the LOCALLY PINNED one if we've seen
  # this sender before; otherwise the key advertised in the (shared, attacker-
  # writable) member record — which we PIN on the first successful verify. This
  # is what stops a shared-folder attacker from impersonating by substituting a
  # member's published pubkey, and from downgrading a pinned sender to unsigned.
  local shared_pubkey pinned_pubkey
  shared_pubkey=$(jq -r '.public_key // ""' "$members_dir/$m_from.json" 2>/dev/null)
  pinned_pubkey=$(beams::known_key_get "$m_from")

  if [ -n "$pinned_pubkey" ]; then
    [ -n "$m_sig" ] || return 1
    beams::verify_canonical "$m_sig" "$pinned_pubkey" \
      "$m_fmt" "$m_id" "$m_beam" "$m_from" "$m_from_name" "$m_to" "$m_ts" "$body" || return 1
  elif [ -n "$shared_pubkey" ]; then
    [ -n "$m_sig" ] || return 1
    beams::verify_canonical "$m_sig" "$shared_pubkey" \
      "$m_fmt" "$m_id" "$m_beam" "$m_from" "$m_from_name" "$m_to" "$m_ts" "$body" || return 1
    beams::known_key_pin "$m_from" "$shared_pubkey"   # trust on first use
  elif [ "$require_sig" = "true" ]; then
    return 1  # beam requires sigs; sender has no pubkey published → reject
  fi

  return 0
}

# ── directory permissions ───────────────────────────────────────────────────
# Belt-and-braces tightening: even though umask 077 takes care of NEW files
# and directories created by this version of the plugin, older shares (or
# manual mkdir) may have left beam dirs at 0755. We re-chmod 0700 on any
# write path that "owns" a beam (create, join). Idempotent.
beams::tighten_perms() {
  local beam="$1"
  local d
  for d in \
    "$(beams::beam_dir "$beam")" \
    "$(beams::beam_messages "$beam")" \
    "$(beams::beam_members "$beam")"
  do
    [ -d "$d" ] && chmod 700 "$d" 2>/dev/null || true
  done
}

# ── shared write helper ─────────────────────────────────────────────────────
# Build, sign, and atomically write one .msg file. Used by /beams:send and
# /beams:admin kick (which writes its own notice). Centralising means the wire
# format only changes in ONE place.
#
# Args (required):
#   $1 = beam name
#   $2 = recipient ("to" field — name, UUID, "all", or comma-separated list)
#   $3 = body text
# Args (optional, in order):
#   $4 = to_id  (single UUID for the recipient, when known)
#   $5 = kind   (extra frontmatter field, e.g. "kick-notice")
# Prints on stdout: "<filename> <id>"
# Returns nonzero on signing failure.
beams::write_message() {
  local beam="$1" to="$2" body="$3" to_id="${4:-}" kind="${5:-}"
  local msgs_dir; msgs_dir=$(beams::beam_messages "$beam")
  mkdir -p "$msgs_dir"

  local mid;        mid=$(beams::uuid)
  local short="${mid:0:8}"
  local ts_iso;     ts_iso=$(beams::now_iso)
  local ts_compact; ts_compact=$(beams::now_compact)
  local sid;        sid=$(beams::config_get '.session_id')
  local name;       name=$(beams::config_get '.session_name')
  [ -n "$name" ] || name="$sid"

  beams::ensure_identity_key
  local sig
  # fmt 2: from_name is part of the signed canonical (third-party relabel-proof).
  sig=$(beams::sign_canonical "2" "$mid" "$beam" "$sid" "$name" "$to" "$ts_iso" "$body") || return 1

  local fname="${ts_compact}__${short}.msg"
  local final="$msgs_dir/$fname"
  local tmp="$msgs_dir/.$fname.tmp.$$"
  {
    printf -- '---\n'
    printf 'fmt: %s\n'       "2"
    printf 'id: %s\n'        "$mid"
    printf 'beam: %s\n'       "$beam"
    printf 'from: %s\n'      "$sid"
    printf 'from_name: %s\n' "$name"
    printf 'to: %s\n'        "$to"
    [ -n "$to_id" ] && printf 'to_id: %s\n' "$to_id"
    [ -n "$kind" ]  && printf 'kind: %s\n'  "$kind"
    printf 'ts: %s\n'        "$ts_iso"
    printf 'sig: %s\n'       "$sig"
    printf -- '---\n'
    printf '%s\n' "$body"
  } > "$tmp"
  mv "$tmp" "$final"
  printf '%s %s' "$fname" "$mid"
}

# ── duration parser (shared by gc + cleanup-stale) ──────────────────────────
# Parse "<N><unit>" (e.g. "30d", "12h", "90m") into find-friendly flags.
# Echoes one flag per line; caller does `mapfile -t flags < <(...)`.
# Returns nonzero for invalid input.
beams::parse_duration() {
  local d="$1"
  local num="${d%[mhd]}"
  local unit="${d: -1}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  case "$unit" in
    d) printf -- '-mtime\n+%s\n' "$num" ;;
    h) printf -- '-mmin\n+%s\n'  "$((num * 60))" ;;
    m) printf -- '-mmin\n+%s\n'  "$num" ;;
    *) return 1 ;;
  esac
}

# ── presence ────────────────────────────────────────────────────────────────
beams::write_member_record() {
  # Drop / refresh this session's member.json inside a beam. $1 = beam.
  # Includes our public key so peers can verify our signed messages.
  local beam="$1"
  local members_dir; members_dir=$(beams::beam_members "$beam")
  local sid; sid=$(beams::config_get '.session_id')
  local name; name=$(beams::config_get '.session_name')
  local host; host=$(hostname 2>/dev/null || echo "unknown")
  beams::ensure_identity_key
  local pub; pub=$(beams::pubkey_b64)
  mkdir -p "$members_dir"
  local tmp="$members_dir/.$sid.tmp.$$"
  jq -n \
    --arg id "$sid" \
    --arg name "$name" \
    --arg host "$host" \
    --arg seen "$(beams::now_iso)" \
    --arg pub "$pub" \
    '{id: $id, name: $name, host: $host, last_seen: $seen, public_key: $pub}' > "$tmp"
  mv "$tmp" "$members_dir/$sid.json"
}
