#!/usr/bin/env bash
# UserPromptSubmit hook: pull any unread messages addressed to this session,
# inject them as additionalContext, and advance the cursor. Silent on error,
# silent when there is nothing to deliver — so cost is ~0 tokens in the idle
# case and never blocks the user's prompt.
#
# Fast path: when nothing has changed since the last hook fire (config file
# unmodified AND every subscribed beam's messages/ dir has the same mtime as
# last time AND the cached beam list matches the live config), skip the full
# check.sh entirely. A cached fingerprint lives at
# $BEAMS_CONFIG_DIR/state/hook-mtime-stash.
#
# Security model. The stash is trust-but-verify cache: a same-UID peer who
# can write to $BEAMS_CONFIG_DIR is hostile by design (see threat model).
# Two hardening measures:
#   (1) per-process tmp via mktemp on the slow-path stash refresh — prevents
#       a peer from planting a fixed-name `.tmp` symlink that would redirect
#       our write to an attacker-chosen victim file.
#   (2) the fast path cross-checks the cached beam list against `jq .beams`
#       from the live config — without this, a peer who forges a stash with
#       only a subset of beams (or none at all) can silently censor messages
#       on the omitted beams until the victim happens to modify config.
#
# Stash format (one key=value per line):
#   cfg=<config_mtime>
#   shared=<shared_path>
#   b=<beam_name>=<messages_dir_mtime>
#   ...
#
# Worst case under stale / forged stash: one redundant slow-path run. Any
# unexpected condition falls through to the full check.sh path; nothing is
# silently dropped.

set -uo pipefail

# Drain stdin (Claude Code passes JSON we don't currently consume).
cat >/dev/null 2>&1 || true

# Be paranoid: a misconfigured hook must never break the user's session.
{
  [ -x "${CLAUDE_PLUGIN_ROOT:-}/lib/check.sh" ] || exit 0
  command -v jq    >/dev/null 2>&1 || exit 0
  command -v find  >/dev/null 2>&1 || exit 0

  # Resolve the config dir the way common.sh does — explicit override, else
  # the session's bound identity (sessions/<id>/bound + bound_project →
  # projects/<p>/identities/<name>), else the session's own scratch dir —
  # without paying common.sh's startup cost. Previously this defaulted to the
  # LEGACY single-config path (~/.config/beams/config.json), which a bound
  # identity never has, so the fast path below never engaged (every prompt ran
  # the full check.sh) — and, had a legacy config existed, its beam list would
  # have driven the cache and silently skipped the bound identity's messages.
  _bsid="${CLAUDE_CODE_SESSION_ID:-}"
  _base="${XDG_CONFIG_HOME:-$HOME/.config}/beams"
  beams_config_dir=""
  if [ -n "${BEAMS_CONFIG_DIR:-}" ]; then
    beams_config_dir="$BEAMS_CONFIG_DIR"
  elif [ -n "$_bsid" ]; then
    _sdir="$_base/sessions/$_bsid"
    beams_config_dir="$_sdir"
    if [ -f "$_sdir/bound" ] && [ ! -L "$_sdir/bound" ]; then
      _bname=$(cat "$_sdir/bound" 2>/dev/null) || _bname=""
      _bproj=$(cat "$_sdir/bound_project" 2>/dev/null) || _bproj=""
      # Identity keys are already sanitised by beams::_safe_key; project keys
      # are flattened absolute paths and therefore START with a dash
      # ("-mnt-data-beams"), so only guard against escaping the tree.
      case "$_bname" in ''|*/*|.|..|.*|-*) _bname="" ;; esac
      case "$_bproj" in ''|*/*|.|..)      _bproj="" ;; esac
      if [ -n "$_bname" ] && [ -n "$_bproj" ] \
         && [ -f "$_base/projects/$_bproj/identities/$_bname/config.json" ]; then
        beams_config_dir="$_base/projects/$_bproj/identities/$_bname"
      fi
    fi
  fi
  cfg="$beams_config_dir/config.json"
  state_dir="$beams_config_dir/state"
  stash="$state_dir/hook-mtime-stash"
  # A bounded check.sh run (delivery cap / time budget) leaves this marker: it
  # advanced only our own cursor files, so no beam directory mtime moved and the
  # fast path below would report "nothing changed" on every following prompt —
  # the rest of the backlog would then sit there until the lease guard happened
  # to force a slow path (and an identity with no lease.json would never drain
  # at all). Take the slow path while the marker exists; check.sh removes it on
  # the run that finally drains everything.
  partial="$state_dir/partial-delivery"

  # One-shot: a just-completed /beams:name or /beams:join leaves a marker so we
  # set the Claude Code session title to the new identity on THIS next prompt (a
  # lib can't call /rename; only a hook can rename a live session). Cheap stat,
  # present only on the prompt right after a bind. When set, we skip the fast
  # path below so the title actually gets emitted.
  pending_title=""
  if [ -n "$_bsid" ]; then
    _ptf="${XDG_CONFIG_HOME:-$HOME/.config}/beams/sessions/$_bsid/title_pending"
    if [ -f "$_ptf" ] && [ ! -L "$_ptf" ]; then
      # NB: `read` returns non-zero when the line has no trailing newline even
      # though it populated the var — so `|| true`, never `|| pending_title=""`
      # (which would wipe a perfectly-good value read from a newline-less marker).
      IFS= read -r pending_title < "$_ptf" 2>/dev/null || true
      rm -f "$_ptf" 2>/dev/null || true
    fi
  fi

  # If state_dir is itself a symlink, refuse stash operations — a peer who
  # replaces it with a symlink to an attacker-chosen directory could
  # redirect writes elsewhere. Slow path still runs (and delivers
  # messages); we just don't refresh the stash from that fire.
  state_dir_safe=1
  if [ -e "$state_dir" ] && [ -L "$state_dir" ]; then
    state_dir_safe=0
  fi

  # The fast path also skips check.sh's lease heartbeat, so take it only while
  # the lease was refreshed recently (< 5 min); otherwise run the slow path,
  # which refreshes it. Keeps an active session's name from going stale.
  lease_fresh=1
  if [ -n "$beams_config_dir" ] && [ -f "$beams_config_dir/lease.json" ] && command -v stat >/dev/null 2>&1; then
    _lm=$(stat -c %Y "$beams_config_dir/lease.json" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - _lm )) -lt 300 ] || lease_fresh=0
  fi

  if [ -z "$pending_title" ] && [ -n "$beams_config_dir" ] && [ -r "$cfg" ] && [ "$lease_fresh" = 1 ] \
     && [ ! -f "$partial" ] && command -v stat >/dev/null 2>&1 && [ "$state_dir_safe" = "1" ]; then
    cfg_mtime=$(stat -c %Y "$cfg" 2>/dev/null || echo 0)

    # Refuse to read the stash if it's a symlink (peer-planted redirect).
    if [ -f "$stash" ] && [ ! -L "$stash" ]; then
      stash_cfg=""
      stash_shared=""
      stash_beams=()
      stash_mtimes=()
      while IFS= read -r line; do
        case "$line" in
          cfg=*)    stash_cfg="${line#cfg=}" ;;
          shared=*) stash_shared="${line#shared=}" ;;
          b=*)
            rest="${line#b=}"
            bname="${rest%=*}"
            bmtime="${rest##*=}"
            [ -n "$bname" ] || continue
            stash_beams+=("$bname")
            stash_mtimes+=("$bmtime")
            ;;
        esac
      done < "$stash"

      if [ "$stash_cfg" = "$cfg_mtime" ] && [ -n "$stash_shared" ]; then
        # Cross-check stash beam list against authoritative config. Without
        # this, a peer who plants a curated stash (omitting `b=` lines for
        # a target beam, or all beams) can silently censor those messages
        # because the fast path's all_match=1 would otherwise be vacuously
        # true on an empty/forged beam list. One jq call here is cheap vs
        # the full slow path it replaces.
        expected_beams=$(jq -r '.beams[]? // empty' "$cfg" 2>/dev/null \
                         | LC_ALL=C sort)
        got_beams=""
        if [ "${#stash_beams[@]}" -gt 0 ]; then
          got_beams=$(printf '%s\n' "${stash_beams[@]}" | LC_ALL=C sort)
        fi

        if [ "$expected_beams" = "$got_beams" ]; then
          if [ -z "$expected_beams" ]; then
            # No subscribed beams; nothing to deliver, no slow path needed.
            exit 0
          fi
          # Stash beam list matches config — now stat each beam messages dir.
          all_match=1
          for i in "${!stash_beams[@]}"; do
            b="${stash_beams[$i]}"
            want="${stash_mtimes[$i]}"
            got=$(stat -c %Y "$stash_shared/beams/$b/messages" 2>/dev/null || echo NA)
            if [ "$got" != "$want" ]; then
              all_match=0
              break
            fi
          done
          if [ "$all_match" -eq 1 ]; then
            exit 0  # silent return; nothing changed since last fire
          fi
        fi
        # beam list mismatch OR mtime drift — fall through to slow path.
      fi
    fi
  fi

  # Slow path: full check.sh. Captures any new messages addressed to us.
  out=$("${CLAUDE_PLUGIN_ROOT}/lib/check.sh" --hook 2>/dev/null) || {
    # check.sh failed (e.g. not initialised) — still honour a pending retitle so
    # a fresh bind names the tab even when there's no inbox to deliver.
    [ -n "$pending_title" ] && jq -n --arg t "$pending_title" \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $t}}' 2>/dev/null
    exit 0
  }
  if [ -n "$pending_title" ]; then
    # A bind just happened: assert the tab title now. Merge into the inbox
    # payload if there is one; if the merge fails (e.g. check.sh ever emits
    # something jq can't parse), fall back to a title-only payload so the retitle
    # is never silently lost — the marker is already consumed at this point.
    _title_only=$(jq -n --arg t "$pending_title" \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $t}}' 2>/dev/null)
    if [ -n "$out" ]; then
      _merged=$(printf '%s' "$out" | jq --arg t "$pending_title" \
        '.hookSpecificOutput.sessionTitle = $t' 2>/dev/null)
      if [ -n "$_merged" ]; then out="$_merged"; else out="$_title_only"; fi
    else
      out="$_title_only"
    fi
  fi
  [ -n "$out" ] && printf '%s' "$out"

  # Refresh the stash after every slow-path run (populates first-ever run
  # too). Capture mtimes AFTER check.sh so any messages it advanced past
  # are reflected. Best-effort — failures here just trigger one extra slow
  # path next time.
  if [ -n "$beams_config_dir" ] && [ -r "$cfg" ] && command -v stat >/dev/null 2>&1 && [ "$state_dir_safe" = "1" ]; then
    cfg_mtime=$(stat -c %Y "$cfg" 2>/dev/null || echo 0)
    parsed=$(jq -r '.shared_path // "", "---SEP---", (.beams[]? // empty)' \
                "$cfg" 2>/dev/null || true)
    if [ -n "$parsed" ]; then
      shared=$(printf '%s\n' "$parsed" | sed -n '1p')
      if [ -n "$shared" ]; then
        mkdir -p "$state_dir" 2>/dev/null || true
        # mktemp opens with O_CREAT|O_EXCL, so a peer-planted symlink at
        # the tmp path cannot redirect our write. Without this, a fixed-
        # name `$stash.tmp` would follow the symlink and truncate the
        # attacker's chosen victim file.
        tmp_stash=$(mktemp "$state_dir/hook-mtime-stash.XXXXXX" 2>/dev/null) \
          || tmp_stash=""
        if [ -n "$tmp_stash" ]; then
          # mtimes are compared at SECOND granularity. A snapshot taken in the
          # same second a directory (or the config) was last modified is "hot":
          # a message landing later in that same second would leave the mtime
          # equal to the snapshot and the fast path would skip it until the
          # next change. Refuse to promote such a snapshot (\`hot=1\`) — the
          # next prompt takes the slow path and snapshots again.
          _now=$(date +%s 2>/dev/null || echo 0)
          hot=0
          [ "$cfg_mtime" -ge "$_now" ] 2>/dev/null && hot=1
          {
            printf 'cfg=%s\n'    "$cfg_mtime"
            printf 'shared=%s\n' "$shared"
            printf '%s\n' "$parsed" | sed -n '/^---SEP---$/,$p' | tail -n +2 \
              | while IFS= read -r b; do
                  [ -n "$b" ] || continue
                  m=$(stat -c %Y "$shared/beams/$b/messages" 2>/dev/null || echo NA)
                  printf 'b=%s=%s\n' "$b" "$m"
                  [ "$m" -ge "$_now" ] 2>/dev/null && printf 'hot=1\n'
                done
          } > "$tmp_stash" 2>/dev/null
          grep -q '^hot=1' "$tmp_stash" 2>/dev/null && hot=1
          # Validate at least one b= line landed before promoting. Under
          # pipefail with stderr suppressed, a non-zero exit from sed/tail
          # would otherwise leave a stash with only cfg=/shared= lines and
          # zero beams — which the fast path treats as "nothing to check"
          # and silently drops all real messages until config changes.
          if [ "$hot" = 0 ] && grep -q '^b=' "$tmp_stash" 2>/dev/null; then
            mv "$tmp_stash" "$stash" 2>/dev/null || rm -f "$tmp_stash" 2>/dev/null
          else
            rm -f "$tmp_stash" 2>/dev/null
          fi
        fi
      fi
    fi
  fi
} 2>/dev/null

exit 0
