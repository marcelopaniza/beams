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
  # Read a boolean under .react (e.g. "watch_on_boot", "on_stop"). Echoes
  # "true" ONLY when the flag is explicitly set to JSON true; absent, null,
  # false, or any other value all echo "" (off). Callers test:
  #     [ "$(beams::react_flag on_stop)" = "true" ]
  # These flags gate the proactive hooks (SessionStart daemon autostart, Stop
  # active-session sustain); both default off so a plain session never spawns a
  # daemon or burns an extra turn without opting in.
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

beams::lease_claim() {             # current session takes the lease on $BEAMS_CONFIG_DIR
  local lf tmp; lf=$(beams::lease_file); tmp="${lf}.tmp.$$"
  mkdir -p "$(dirname "$lf")"
  jq -n --arg s "$(beams::terminal_id)" --argjson t "$(beams::_now_epoch)" \
    '{bound_session:$s, last_seen:$t}' > "$tmp" 2>/dev/null && mv "$tmp" "$lf" || rm -f "$tmp"
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
  [ "$age" -lt "$BEAMS_INUSE_STALE_SECONDS" ] && printf 'busy:%s' "$age" || printf 'free'
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
  local beam="$1" who="$2"
  local mdir; mdir=$(beams::beam_members "$beam")
  [ -d "$mdir" ] || { printf ''; return 0; }
  # Already a uuid that exists as a member?
  if [ -f "$mdir/$who.json" ]; then printf '%s' "$who"; return 0; fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local id name
    id=$(jq -r '.id // ""' "$f" 2>/dev/null)
    name=$(jq -r '.name // ""' "$f" 2>/dev/null)
    if [ "$name" = "$who" ]; then printf '%s' "$id"; return 0; fi
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
# To get an unambiguous canonical that protects against ANY field value
# (newlines, separators) shifting the parse, we write the canonical bytes
# directly to a file with NUL separators, then hand the file to openssl.
# The header fields are NUL-separated; the body is appended verbatim AFTER
# a final NUL. Receiver does the identical write, so identical bytes hit
# the verifier.

beams::_write_canonical() {
  # $1 = destination file path
  # $2..$6 = id beam from to ts
  # $7 = body
  {
    printf '%s\0' "$2" "$3" "$4" "$5" "$6"
    printf '%s'   "$7"
  } > "$1"
}

beams::sign_canonical() {
  # Sign (id, beam, from, to, ts, body); echo base64 signature, nonzero on
  # failure. Bytes never round-trip through a bash variable.
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
  # $3..$8 = id beam from to ts body
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

  local pubkey
  pubkey=$(jq -r '.public_key // ""' "$members_dir/$m_from.json" 2>/dev/null)

  local m_sig; m_sig=$(beams::fm_field "$fm" sig)

  if [ -n "$pubkey" ]; then
    [ -n "$m_sig" ] || return 1
    local m_to; m_to=$(beams::fm_field "$fm" to)
    beams::verify_canonical "$m_sig" "$pubkey" "$m_id" "$m_beam" "$m_from" "$m_to" "$m_ts" "$body" \
      || return 1
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
  sig=$(beams::sign_canonical "$mid" "$beam" "$sid" "$to" "$ts_iso" "$body") || return 1

  local fname="${ts_compact}__${short}.msg"
  local final="$msgs_dir/$fname"
  local tmp="$msgs_dir/.$fname.tmp.$$"
  {
    printf -- '---\n'
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
