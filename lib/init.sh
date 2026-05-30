#!/usr/bin/env bash
# /buses:init <shared-path> [--force] [--profile <name>] — set the shared
# folder for this machine/session and generate a session UUID. Safe to re-run:
# refuses to clobber an existing config unless --force is passed.
#
# --profile <name> reads presets/<name>.json from the plugin root and applies
# its overlays after standard init: default_name, role, auto_subscribe.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
buses::require jq

# Re-split: see comment in other lib scripts.
[ "$#" -le 1 ] && { read -ra __buses_args <<<"${1-}"; set -- "${__buses_args[@]}"; unset __buses_args; }

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
      [ -n "$profile" ] || buses::die "--profile requires a name (e.g. --profile hermes)"
      shift 2
      ;;
    *)
      buses::die "unknown argument: $1 (usage: init.sh <shared-path> [--force] [--profile <name>])"
      ;;
  esac
done

[ -n "$shared" ] || buses::die "usage: init.sh <shared-path> [--force] [--profile <name>]"

# Validate profile name early (before touching any state). Reject path-
# traversal, dotfiles, absolute paths, and anything outside [A-Za-z0-9_-].
if [ -n "$profile" ]; then
  case "$profile" in
    *'/'*|*'.'*|'-'*|'')
      buses::die "invalid profile name: '$profile' (must match [A-Za-z0-9_-]+, no dots, slashes, or leading dash)"
      ;;
  esac
  if ! printf '%s' "$profile" | LC_ALL=C grep -qE '^[A-Za-z0-9_-]+$'; then
    buses::die "invalid profile name: '$profile' (must match [A-Za-z0-9_-]+)"
  fi
  plugin_root="$(cd "$(dirname "$0")/.." && pwd)"
  preset_file="$plugin_root/presets/$profile.json"
  [ -f "$preset_file" ] || buses::die "no such profile: '$profile' (looked at $preset_file)"
  jq empty "$preset_file" >/dev/null 2>&1 || buses::die "preset file is not valid JSON: $preset_file"
fi

# Expand ~ if present.
case "$shared" in
  '~'|'~/'*) shared="${HOME}${shared#\~}" ;;
esac

# Make absolute.
case "$shared" in
  /*) ;;
  *)  shared="$(cd "$shared" 2>/dev/null && pwd)" || buses::die "shared path not found (and could not resolve to absolute): $1" ;;
esac

if buses::config_exists && [ "$force" != "--force" ]; then
  existing=$(buses::config_get '.shared_path')
  sid=$(buses::config_get '.session_id')
  buses::die "config already exists at $BUSES_CONFIG_FILE
  shared_path: $existing
  session_id:  $sid
re-run with --force to reset."
fi

mkdir -p "$shared/buses" || buses::die "cannot create $shared/buses (check the path is mounted and writable)"

sid=$(buses::config_init_file "$shared")

# Generate cryptographic identity (Ed25519). The private key never leaves
# this machine; the public key is published in member records so peers can
# verify our signed messages.
buses::ensure_identity_key
fp=$(buses::fingerprint)

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
    tmp_cfg=$(mktemp "${BUSES_CONFIG_FILE}.XXXXXX")
    jq --arg r "$role" '.role = $r' "$BUSES_CONFIG_FILE" > "$tmp_cfg" \
      && mv "$tmp_cfg" "$BUSES_CONFIG_FILE" \
      || { rm -f "$tmp_cfg"; buses::die "failed to set role from preset"; }
  fi

  # React overlay: a preset may enable the proactive hooks (notifier daemon
  # autostart on boot, Stop-hook active-session sustain). Merge its .react
  # object over the defaults config_init_file already wrote, so a preset can
  # flip individual flags without restating all of them. Only literal boolean
  # values are honoured — a preset can't smuggle arbitrary keys/values into the
  # config's react block.
  react_overlay=$(jq -c '(.react // {}) | with_entries(select(.value == true or .value == false))' "$preset_file" 2>/dev/null || echo '{}')
  if [ -n "$react_overlay" ] && [ "$react_overlay" != "{}" ]; then
    tmp_cfg=$(mktemp "${BUSES_CONFIG_FILE}.XXXXXX")
    jq --argjson r "$react_overlay" '.react = ((.react // {}) + $r)' "$BUSES_CONFIG_FILE" > "$tmp_cfg" \
      && mv "$tmp_cfg" "$BUSES_CONFIG_FILE" \
      || { rm -f "$tmp_cfg"; buses::die "failed to apply react overlay from preset"; }
  fi

  joined_count=0
  if [ -n "$auto_subscribe" ]; then
    while IFS= read -r bus; do
      [ -n "$bus" ] || continue
      "$lib_dir/join.sh" "$bus" >/dev/null 2>&1 \
        && joined_count=$((joined_count + 1)) || true
    done <<< "$auto_subscribe"
  fi

  profile_summary=$(printf '  profile:     %s%s%s%s' \
    "$profile" \
    "${default_name:+  (name=$default_name)}" \
    "${role:+  (role=$role)}" \
    "$([ "$joined_count" -gt 0 ] && printf '  (auto-joined %d bus)' "$joined_count")")
fi

cc_sid=$(buses::terminal_id)
cat <<EOF
buses: initialised
  terminal:    ${cc_sid:-<not set — running outside Claude Code?>}
  project:     $(buses::project_dir)
  config:      $BUSES_CONFIG_FILE
  shared_path: $shared
  session_id:  $sid
  fingerprint: ${fp:-(none)}   (sha256/16 of public key)${profile_summary:+
$profile_summary}

  (identity is scoped to THIS terminal — other Claude Code terminals on this
   machine get their own UUIDs, even in the same project. Override with
   BUSES_CONFIG_DIR if you want to share identity across terminals.)

next steps:
  /buses:name <friendly-name>     give this session a memorable name
  /buses:create <bus>             make a new bus, or
  /buses:join <existing-bus>      subscribe to one
EOF
