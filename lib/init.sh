#!/usr/bin/env bash
# /beams:admin init <shared-path> [--force] [--profile <name>] — set the shared
# folder for this machine/session and generate a session UUID. Safe to re-run:
# refuses to clobber an existing config unless --force is passed.
#
# --profile <name> reads presets/<name>.json from the plugin root and applies
# its overlays after standard init: default_name, role, auto_subscribe.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
beams::require jq

# Re-split: see comment in other lib scripts.
[ "$#" -le 1 ] && { read -ra __beams_args <<<"${1-}"; set -- "${__beams_args[@]}"; unset __beams_args; }

shared="${1:-}"
shift || true

force=""
profile=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      force="--force"
      shift
      ;;
    --profile)
      profile="${2:-}"
      [ -n "$profile" ] || beams::die "--profile requires a name (e.g. --profile hermes)"
      shift 2
      ;;
    *)
      beams::die "unknown argument: $1 (usage: init.sh <shared-path> [--force] [--profile <name>])"
      ;;
  esac
done

[ -n "$shared" ] || beams::die "usage: init.sh <shared-path> [--force] [--profile <name>]"

# Validate profile name early (before touching any state). Reject path-
# traversal, dotfiles, absolute paths, and anything outside [A-Za-z0-9_-].
if [ -n "$profile" ]; then
  case "$profile" in
    *'/'*|*'.'*|'-'*|'')
      beams::die "invalid profile name: '$profile' (must match [A-Za-z0-9_-]+, no dots, slashes, or leading dash)"
      ;;
  esac
  if ! printf '%s' "$profile" | LC_ALL=C grep -qE '^[A-Za-z0-9_-]+$'; then
    beams::die "invalid profile name: '$profile' (must match [A-Za-z0-9_-]+)"
  fi
  plugin_root="$(cd "$(dirname "$0")/.." && pwd)"
  preset_file="$plugin_root/presets/$profile.json"
  [ -f "$preset_file" ] || beams::die "no such profile: '$profile' (looked at $preset_file)"
  jq empty "$preset_file" >/dev/null 2>&1 || beams::die "preset file is not valid JSON: $preset_file"
fi

# Expand ~ if present.
case "$shared" in
  '~'|'~/'*) shared="${HOME}${shared#\~}" ;;
esac

# Make absolute.
case "$shared" in
  /*) ;;
  *)  shared="$(cd "$shared" 2>/dev/null && pwd)" || beams::die "shared path not found (and could not resolve to absolute): $1" ;;
esac

if beams::config_exists && [ "$force" != "--force" ]; then
  existing=$(beams::config_get '.shared_path')
  sid=$(beams::config_get '.session_id')
  beams::die "config already exists at $BEAMS_CONFIG_FILE
  shared_path: $existing
  session_id:  $sid
re-run with --force to reset."
fi

mkdir -p "$shared/beams" || beams::die "cannot create $shared/beams (check the path is mounted and writable)"

sid=$(beams::config_init_file "$shared")

# Generate cryptographic identity (Ed25519). The private key never leaves
# this machine; the public key is published in member records so peers can
# verify our signed messages.
beams::ensure_identity_key
fp=$(beams::fingerprint)

# Apply profile overlays (name, role, auto-subscribe). Order matters: set the
# session name BEFORE auto-subscribing so member records written by join.sh
# carry the preset name from the first publish.
profile_summary=""
if [ -n "$profile" ]; then
  lib_dir="$(cd "$(dirname "$0")" && pwd)"
  default_name=$(jq -r '.default_name // ""'        "$preset_file")
  role=$(jq -r        '.role         // ""'        "$preset_file")
  auto_subscribe=$(jq -r '.auto_subscribe // [] | .[]' "$preset_file" 2>/dev/null || true)

  if [ -n "$default_name" ]; then
    "$lib_dir/name.sh" "$default_name" >/dev/null
  fi

  if [ -n "$role" ]; then
    tmp_cfg=$(mktemp "${BEAMS_CONFIG_FILE}.XXXXXX")
    jq --arg r "$role" '.role = $r' "$BEAMS_CONFIG_FILE" > "$tmp_cfg" \
      && mv "$tmp_cfg" "$BEAMS_CONFIG_FILE" \
      || { rm -f "$tmp_cfg"; beams::die "failed to set role from preset"; }
  fi

  # React overlay: a preset may enable the proactive hooks (notifier daemon
  # autostart on boot, Stop-hook active-session sustain). Merge its .react
  # object over the defaults config_init_file already wrote, so a preset can
  # flip individual flags without restating all of them. Only literal boolean
  # values are honoured — a preset can't smuggle arbitrary keys/values into the
  # config's react block.
  react_overlay=$(jq -c '(.react // {}) | with_entries(select(.value == true or .value == false))' "$preset_file" 2>/dev/null || echo '{}')
  if [ -n "$react_overlay" ] && [ "$react_overlay" != "{}" ]; then
    tmp_cfg=$(mktemp "${BEAMS_CONFIG_FILE}.XXXXXX")
    jq --argjson r "$react_overlay" '.react = ((.react // {}) + $r)' "$BEAMS_CONFIG_FILE" > "$tmp_cfg" \
      && mv "$tmp_cfg" "$BEAMS_CONFIG_FILE" \
      || { rm -f "$tmp_cfg"; beams::die "failed to apply react overlay from preset"; }
  fi

  joined_count=0
  if [ -n "$auto_subscribe" ]; then
    while IFS= read -r beam; do
      [ -n "$beam" ] || continue
      "$lib_dir/join.sh" "$beam" >/dev/null 2>&1 \
        && joined_count=$((joined_count + 1)) || true
    done <<< "$auto_subscribe"
  fi

  profile_summary=$(printf '  profile:     %s%s%s%s' \
    "$profile" \
    "${default_name:+  (name=$default_name)}" \
    "${role:+  (role=$role)}" \
    "$([ "$joined_count" -gt 0 ] && printf '  (auto-joined %d beam)' "$joined_count")")
fi

cc_sid=$(beams::terminal_id)
cat <<EOF
beams: initialised
  terminal:    ${cc_sid:-<not set — running outside Claude Code?>}
  project:     $(beams::project_dir)
  config:      $BEAMS_CONFIG_FILE
  shared_path: $shared
  session_id:  $sid
  fingerprint: ${fp:-(none)}   (sha256/16 of public key)${profile_summary:+
$profile_summary}

  (identity is scoped to THIS terminal — other Claude Code terminals on this
   machine get their own UUIDs, even in the same project. Override with
   BEAMS_CONFIG_DIR if you want to share identity across terminals.)

next steps:
  /beams:name <friendly-name>     give this session a memorable name
  /beams:admin create <beam>             make a new beam, or
  /beams:join <existing-beam>      subscribe to one
EOF
