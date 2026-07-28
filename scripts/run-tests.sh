#!/usr/bin/env bash
#
# scripts/run-tests.sh — run flake checks (and optionally the opt-in patchBuilds)
# and show their full build logs.
#
# Background: `nix build .#checks.*` and `nix flake check` are quiet on success
# (they don't stream build logs), and a NixOS test's `machine.succeed` only
# dumps its captured stdout on FAILURE — so on a passing run the probe's
# `===`/`OK:` lines are normally invisible. The guest-smbios test calls
# `machine.log(out)` to capture that output into the build log on success too,
# and this helper surfaces it.
#
# By default this runs the `checks.x86_64-linux.*` outputs (fast Layer 1 eval
# tests + the unpatched Layer 3 boot tests using nixpkgs' prebuilt QEMU). The
# opt-in `patchBuilds.x86_64-linux.*` outputs (Layer 2: QEMU-from-source patch
# build + static string check; Layer 3: the patched-QEMU boot test) are HEAVY
# (build QEMU from source; the boot test also needs nested KVM) and are NOT run
# unless you pass --patch.
#
# For each selected test it:
#   1. builds it with `nix build` (uses the cache if already built — does NOT
#      force a rebuild by default, so re-running a passing test is fast),
#   2. prints the full build log (`nix log`) — on failure this includes the
#      probe's `===`/`FAIL:` dump; on success it includes the `===`/`OK:` lines,
#   3. prints a ✅/❌ summary.
#
# Usage:
#   scripts/run-tests.sh                 # all checks
#   scripts/run-tests.sh guest-smbios    # checks whose name contains the substring
#   scripts/run-tests.sh --patch         # checks + opt-in patchBuilds (heavy: QEMU from source + patched boot test)
#   scripts/run-tests.sh --patch qemu    # just the QEMU patch build tests (applies/compile/strings) — substring filters the combined set
#   scripts/run-tests.sh -l              # list available checks (+ patchBuilds if --patch)
#   scripts/run-tests.sh --no-log        # don't print logs, just pass/fail summary
#   scripts/run-tests.sh --tail 40       # show only the last N lines of each log
#   scripts/run-tests.sh --rebuild       # force a fresh run even if cached
#   scripts/run-tests.sh -h              # this help
#
# Exit code is non-zero if any test fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run from the flake root so .# resolves to this flake.
cd "$SCRIPT_DIR/.."

# Discover the attr names of a flake output set (checks or patchBuilds) as a
# newline-separated list. Returns non-zero if the eval fails. Discovered from
# the flake itself so new outputs are picked up automatically — no hardcoded
# list to maintain.
discover_set() {
  nix eval --raw ".#${1}.x86_64-linux" --apply 'x: builtins.concatStringsSep "\n" (builtins.attrNames x)' 2>/dev/null
}

# checks are always discovered (the default test set).
if ! DISCOVERED_CHECKS="$(discover_set checks)"; then
  echo "ERROR: could not discover checks from flake (nix eval failed)." >&2
  echo "       Ensure the flake is accessible and nix eval works." >&2
  exit 1
fi
mapfile -t CHECK_NAMES < <(printf '%s\n' "$DISCOVERED_CHECKS" | sort)

SHOW_LOG=1
TAIL=0
REBUILD=0
LIST=0
INCLUDE_PATCH=0
TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list) LIST=1; shift;;
    --no-log) SHOW_LOG=0; shift;;
    --rebuild) REBUILD=1; shift;;
    --patch) INCLUDE_PATCH=1; shift;;
    --tail)
      TAIL="${2:?--tail needs an N (e.g. --tail 40)}"
      if ! [[ "$TAIL" =~ ^[0-9]+$ ]]; then
        echo "--tail expects a non-negative integer, got '$TAIL'" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      sed -n '2,38p' "$0"
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

# patchBuilds are discovered only when --patch is requested (they're heavy:
# QEMU-from-source build + the patched boot test needing nested KVM).
PATCH_NAMES=()
if [ "$INCLUDE_PATCH" -eq 1 ]; then
  if DISCOVERED_PATCH="$(discover_set patchBuilds)"; then
    mapfile -t PATCH_NAMES < <(printf '%s\n' "$DISCOVERED_PATCH" | sort)
  else
    echo "WARNING: --patch requested but could not discover patchBuilds (nix eval failed); running checks only." >&2
  fi
fi

# Build the candidate item list as "set:name" entries (set = checks|patchBuilds)
# so each item carries which flake output it lives under (the build attr differs:
# .#checks.x86_64-linux.<name> vs .#patchBuilds.x86_64-linux.<name>).
ITEMS=()
for n in "${CHECK_NAMES[@]}"; do ITEMS+=("checks:$n"); done
for n in "${PATCH_NAMES[@]}"; do ITEMS+=("patchBuilds:$n"); done

if [ "$LIST" -eq 1 ]; then
  echo "Available checks (.#checks.x86_64-linux.<name>):"
  printf '  %s\n' "${CHECK_NAMES[@]}"
  if [ "${#PATCH_NAMES[@]}" -gt 0 ]; then
    echo
    echo "Available patchBuilds (.#patchBuilds.x86_64-linux.<name>) — opt-in, heavy (QEMU from source / patched boot test):"
    printf '  %s\n' "${PATCH_NAMES[@]}"
  fi
  exit 0
fi

# Resolve targets by substring match against the name part of each item.
if [ "${#TARGETS[@]}" -eq 0 ]; then
  SELECTED=("${ITEMS[@]}")
else
  SELECTED=()
  for t in "${TARGETS[@]}"; do
    found=0
    for item in "${ITEMS[@]}"; do
      name="${item#*:}"
      if [[ "$name" == *"$t"* ]]; then
        SELECTED+=("$item")
        found=1
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "No test matches '$t'. Available:" >&2
      printf '  %s\n' "${CHECK_NAMES[@]}" >&2
      [ "${#PATCH_NAMES[@]}" -gt 0 ] && { echo "patchBuilds:" >&2; printf '  %s\n' "${PATCH_NAMES[@]}" >&2; }
      exit 2
    fi
  done
fi

show_log() {
  local attr="$1"
  if [ "$SHOW_LOG" -eq 0 ]; then
    return
  fi
  local log
  if ! log="$(nix log "$attr" 2>/dev/null)"; then
    echo "  (no log available — the test may never have been built)"
    return
  fi
  if [ -z "$log" ]; then
    echo "  (no build log — eval-time check)"
    return
  fi
  echo "----- nix log $attr -----"
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
for item in "${SELECTED[@]}"; do
  setname="${item%%:*}"
  name="${item#*:}"
  attr=".#${setname}.x86_64-linux.${name}"
  # Show patchBuilds with a set prefix so it's clear which are the heavy opt-in ones.
  display="$name"
  [ "$setname" = "patchBuilds" ] && display="patchBuilds/$name"
  echo "▶ $display"
  build_args=(--no-link)
  if [ "$REBUILD" -eq 1 ]; then
    build_args+=(--rebuild)
  fi
  # Capture stderr; discard on success (just nix warnings like “git tree
  # dirty” / “error (ignored): SQLite database”), show on failure (the error
  # trace is the useful diagnostic). `if` consumes a non-zero exit so `set -e`
  # doesn't abort the loop.
  build_stderr=""
  if build_stderr="$(nix build "${build_args[@]}" "$attr" 2>&1 1>/dev/null)"; then
    show_log "$attr"
    echo "✅ $display"
    PASS=$((PASS + 1))
  else
    printf '%s\n' "$build_stderr" >&2
    show_log "$attr"
    echo "❌ $display"
    FAIL=$((FAIL + 1))
    FAILED+=("$display")
  fi
  echo
done

echo "================== summary =================="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  failed tests: ${FAILED[*]}"
  exit 1
fi