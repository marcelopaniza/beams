#!/usr/bin/env bash
# Run every smoke-test round in order. Exits 0 if all pass, nonzero otherwise.
# Each round is self-contained — own tmpdir, own session UUIDs, own keys.
# Total wall-clock is ~50-60 seconds (most of it is sleep-between-events).
#
# Usage:
#   tests/run-all.sh          # all rounds
#   tests/run-all.sh 1 3 7    # just listed rounds
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PLUGIN_ROOT
# Hermetic base dir for the whole run: keep each round's config / sessions /
# TOFU known_keys out of the real ~/.config/beams. Rounds that export their own
# XDG_CONFIG_HOME override this inside their own process.
export XDG_CONFIG_HOME="$(mktemp -d "${TMPDIR:-/tmp}/beams-runall-xdg.XXXXXX")"
trap 'rm -rf "$XDG_CONFIG_HOME"' EXIT
ROUNDS=("$@")
[ "${#ROUNDS[@]}" -eq 0 ] && ROUNDS=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23)

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

bold "Running beams smoke tests against $PLUGIN_ROOT"
fail=0
fail_list=()
t0=$(date +%s)
for r in "${ROUNDS[@]}"; do
  script="$PLUGIN_ROOT/tests/round-$r.sh"
  if [ ! -x "$script" ]; then
    red "skip: $script not found or not executable"
    continue
  fi
  printf '  round %-2s ... ' "$r"
  if "$script" > "/tmp/beams-test-round-$r.log" 2>&1; then
    green "OK"
  else
    red "FAIL"
    fail=$((fail + 1))
    fail_list+=("$r")
  fi
done
t1=$(date +%s)

echo
if [ "$fail" -eq 0 ]; then
  green "ALL ROUNDS PASS  (took $((t1 - t0))s)"
else
  red "$fail round(s) FAILED: ${fail_list[*]}"
  for r in "${fail_list[@]}"; do
    echo
    bold "── /tmp/beams-test-round-$r.log (last 30 lines) ──"
    tail -n 30 "/tmp/beams-test-round-$r.log"
  done
  exit 1
fi
