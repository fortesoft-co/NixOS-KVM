#!/usr/bin/env bash
#
# scripts/run-tests.sh — run flake checks and show their full build logs.
#
# Background: `nix build .#checks.*` and `nix flake check` are quiet on success
# (they don't stream build logs), and a NixOS test's `machine.succeed` only
# dumps its captured stdout on FAILURE — so on a passing run the probe's
# `===`/`OK:` lines are normally invisible. The guest-smbios test calls
# `machine.log(out)` to capture that output into the build log on success too,
# and this helper surfaces it.
#
# For each selected check it:
#   1. builds it with `nix build` (uses the cache if already built — does NOT
#      force a rebuild by default, so re-running a passing test is fast),
#   2. prints the full build log (`nix log`) — on failure this includes the
#      probe's `===`/`FAIL:` dump; on success it includes the `===`/`OK:` lines,
#   3. prints a ✅/❌ summary.
#
# Usage:
#   scripts/run-tests.sh                 # all checks
#   scripts/run-tests.sh guest-smbios    # checks whose name contains the substring
#   scripts/run-tests.sh -l              # list available checks
#   scripts/run-tests.sh --no-log        # don't print logs, just pass/fail summary
#   scripts/run-tests.sh --tail 40       # show only the last N lines of each log
#   scripts/run-tests.sh --rebuild       # force a fresh run even if cached
#   scripts/run-tests.sh -h              # this help
#
# Exit code is non-zero if any check fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run from the flake root so .# resolves to this flake.
cd "$SCRIPT_DIR/.."

# Flat check names (each is a derivation under checks.x86_64-linux — nix flake
# check does not recurse into nested attrsets, so they are flat; see flake.nix).
ALL=(
  anti-detection-cpu-socket
  anti-detection-smbios-profiles
  anti-detection-host-lib
  anti-detection-guest-lib
  anti-detection-guest-smbios
  guest-xml
)

SHOW_LOG=1
TAIL=0
REBUILD=0
LIST=0
TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list) LIST=1; shift;;
    --no-log) SHOW_LOG=0; shift;;
    --rebuild) REBUILD=1; shift;;
    --tail)
      TAIL="${2:?--tail needs an N (e.g. --tail 40)}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,33p' "$0"
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do TARGETS+=("$1"); shift; done
      ;;
    -*)
      echo "unknown flag: $1 (try --help)" >&2
      exit 2
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

if [ "$LIST" -eq 1 ]; then
  echo "Available checks (.#checks.x86_64-linux.<name>):"
  printf '  %s\n' "${ALL[@]}"
  exit 0
fi

# Resolve targets by substring match against the flat check names.
if [ "${#TARGETS[@]}" -eq 0 ]; then
  SELECTED=("${ALL[@]}")
else
  SELECTED=()
  for t in "${TARGETS[@]}"; do
    found=0
    for c in "${ALL[@]}"; do
      if [[ "$c" == *"$t"* ]]; then
        SELECTED+=("$c")
        found=1
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "No check matches '$t'. Available:" >&2
      printf '  %s\n' "${ALL[@]}" >&2
      exit 2
    fi
  done
fi

show_log() {
  local attr="$1"
  if [ "$SHOW_LOG" -eq 0 ]; then
    return
  fi
  echo "----- nix log $attr -----"
  local log
  if ! log="$(nix log "$attr" 2>/dev/null)"; then
    echo "  (no log available — the check may never have been built)"
    echo "----- end log -----"
    return
  fi
  if [ "$TAIL" -gt 0 ]; then
    printf '%s\n' "$log" | tail -n "$TAIL"
  else
    printf '%s\n' "$log"
  fi
  echo "----- end log -----"
}

PASS=0
FAIL=0
FAILED=()
for c in "${SELECTED[@]}"; do
  attr=".#checks.x86_64-linux.$c"
  echo "▶ $c"
  build_args=(--no-link)
  if [ "$REBUILD" -eq 1 ]; then
    build_args+=(--rebuild)
  fi
  # `if` consumes a non-zero exit so `set -e` doesn't abort the loop.
  if nix build "${build_args[@]}" "$attr"; then
    show_log "$attr"
    echo "✅ $c"
    PASS=$((PASS + 1))
  else
    # nix build already printed the error + log tail; show the full log too.
    show_log "$attr"
    echo "❌ $c"
    FAIL=$((FAIL + 1))
    FAILED+=("$c")
  fi
  echo
done

echo "================== summary =================="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  failed checks: ${FAILED[*]}"
  exit 1
fi