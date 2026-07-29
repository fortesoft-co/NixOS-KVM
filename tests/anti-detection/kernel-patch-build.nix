# Layer 2 — Tier 3 (Kernel anti-detection) patch-build test (OPT-IN).
#
# Verifies the five vendored per-vector patches at
# modules/kvm/patches/linux-6.18-ad-*.patch against the EXACT kernel they
# were generated for (Linux 6.18.38, hash-verified via
# modules/kvm/patches/kernel-pin.nix — the same pin host/kernel.nix builds
# in production, so test and production can never drift).
#
# Levels (BESPOKE-PATCH-DESIGN.md §8 — apply checks are seconds, kernel
# compiles are the expensive step, so matrix the applies and pay ONE
# compile on the happy path):
#
#   1. Apply matrix    — `patch -p1` against the unpacked 6.18.38 source:
#        • per-file: each of the 5 patches alone, then grep for the marker
#          symbol that file must land (catches context drift per file, and
#          an empty/no-op patch)
#        • combined: all 5 in listed order + all 5 markers (catches a
#          cross-file context interaction; a red combined + green per-file
#          localizes it)
#      Cheap (no compile).
#
#   2. Compile, happy path — ONE full kernel build with all 5 patches
#      appended to `kernelPatches`, exactly as host/kernel.nix wires it in
#      production. Heavy (a Linux kernel build — minutes to tens of
#      minutes). Catches C syntax errors / broken headers /
#      patch-on-nixpkgs-patch context conflicts the apply check can't see.
#
#   3. Compile, bisect — per-file compiles (kernel with ONLY that patch).
#      Exposed as flake outputs but never referenced by `all`, so they're
#      only built when debugging a failing stage-2 build.
#
# This is OPT-IN: exposed via the `patchBuilds` output, NOT in `checks`, so
# `nix flake check` stays fast by default. Build with:
#
#   nix build .#patchBuilds.x86_64-linux.anti-detection-kernel --no-link -L
#
# Granular:
#
#   nix build .#patchBuilds.x86_64-linux.anti-detection-kernel-applies --no-link -L
#   nix build .#patchBuilds.x86_64-linux.anti-detection-kernel-compile --cores 0 --no-link -L
#   nix build .#patchBuilds.x86_64-linux.anti-detection-kernel-compile-ad-rdtsc-timing --cores 0 --no-link -L
#
# ── Parallelism (NOT hard-coded) ─────────────────────────────────────────
# A kernel build is hugely CPU-bound. Nix propagates `--cores N` into each
# derivation via $NIX_BUILD_CORES; the nixpkgs kernel derivation sets
# `enableParallelBuilding = true`, so `make` runs with -j$NIX_BUILD_CORES.
# `--cores 0` uses every available core. The test never bakes in -jN.
#
# Returns { applies, compile, all, perFileCompiles } — the flake wires
# applies/compile/all + one output per perFileCompiles entry.
{ lib, pkgs }:
with lib;
let
  # The pinned kernel + patch set under test (same pin host/kernel.nix uses
  # when customKernelSrcUrl/customKernelPatch are null).
  pin = import ../../modules/kvm/patches/kernel-pin.nix { inherit pkgs; };
  kernelVersion = pin.version;
  kernelSrc = pin.src;
  adPatches = pin.antiDetectionPatches;

  # Marker each patch must land — proves the hunk actually applied (not a
  # no-op). Picked to be unique to each patch's added lines.
  markers = {
    ad-rdtsc-timing    = { file = "arch/x86/kvm/vmx/vmx.c";          symbol = "handle_rdtsc"; };
    ad-msr-tsc-read    = { file = "arch/x86/kvm/x86.c";              symbol = "rdtsc_user_divisor"; };
    ad-cpuid-signature = { file = "arch/x86/kvm/cpuid.c";            symbol = "GenuineIntel"; };
    ad-debug-trap-fix  = { file = "arch/x86/include/asm/kvm_host.h"; symbol = "DR6_B0"; };
    ad-hypercall-ud    = { file = "arch/x86/kvm/x86.c";              symbol = "always synthesize #UD"; };
  };
  markerFor = name: markers.${name};

  # ── Linux 6.18.38 source (unpack only — no built-in patches, no build) ───
  # Shared by all apply checks so the tarball is fetched + unpacked ONCE
  # (Nix shares the store path). Copy the unpacked tree (not the wrapper
  # dir) so `cd src && patch -p1` lands at the right level.
  linuxSourceUnpacked = pkgs.stdenv.mkDerivation {
    name = "linux-${kernelVersion}-src";
    src = kernelSrc;
    dontConfigure = true;
    dontBuild = true;
    installPhase = "cp -r . $out";
  };

  # ── Level 1a: per-file applies-cleanly checks ────────────────────────────
  # Real `patch -p1` (not --dry-run) against a throwaway copy, then grep for
  # the file's marker. Fails if any hunk is rejected OR the marker is absent.
  patchAppliesCheck = p: pkgs.runCommand "check-kernel-patch-applies-${p.name}" { } ''
    set -euo pipefail
    cp -r ${linuxSourceUnpacked} src
    chmod -R u+w src
    cd src
    patch -p1 --no-backup-if-mismatch < ${p.patch}
    if ! grep -rIq -- "${(markerFor p.name).symbol}" ${(markerFor p.name).file}; then
      echo "FAIL: '${(markerFor p.name).symbol}' absent from patched ${(markerFor p.name).file}" >&2
      exit 1
    fi
    touch $out
  '';
  perFileApplies = map patchAppliesCheck adPatches;

  # ── Level 1b: combined apply check (all five, listed order) ─────────────
  combinedApplyCheck = pkgs.runCommand "check-kernel-patch-applies-combined" { } ''
    set -euo pipefail
    cp -r ${linuxSourceUnpacked} src
    chmod -R u+w src
    cd src
    ${concatMapStringsSep "\n" (p: "patch -p1 --no-backup-if-mismatch < ${p.patch}") adPatches}
    ${concatMapStringsSep "\n" (p: ''
      if ! grep -rIq -- "${(markerFor p.name).symbol}" ${(markerFor p.name).file}; then
        echo "FAIL: '${(markerFor p.name).symbol}' absent after combined apply" >&2
        exit 1
      fi
    '') adPatches}
    touch $out
  '';

  # ── The pinned kernel package, exactly as production builds it ───────────
  pinnedKernelPackages = pkgs.linuxPackagesFor (pkgs.linux_6_18.override {
    argsOverride = {
      inherit (pin) src version;
      modDirVersion = pin.version;
    };
  });

  # ── Level 2: combined compile (happy path — all five patches) ───────────
  withPatches = patches: pinnedKernelPackages.extend (self: super: {
    kernel = super.kernel.override {
      kernelPatches = super.kernel.kernelPatches ++ patches;
    };
  });
  combinedCompile = (withPatches adPatches).kernel;

  # ── Level 3: per-file compiles (bisect targets — not in `all`) ───────────
  perFileCompiles = listToAttrs (map (p:
    nameValuePair p.name (withPatches [ p ]).kernel
  ) adPatches);

  # ── Aggregates ───────────────────────────────────────────────────────────
  applies = pkgs.runCommand "kernel-patch-applies-all" {
    passthru = { inherit perFileApplies combinedApplyCheck; };
  } ''
    ${concatMapStringsSep "\n" (d: "test -f ${d}") perFileApplies}
    test -f ${combinedApplyCheck}
    echo "all 5 anti-detection patches apply cleanly (per-file + combined) to Linux ${kernelVersion}" > $out
  '';

  all = pkgs.runCommand "kernel-patch-build-all" {
    passthru = {
      inherit perFileApplies combinedApplyCheck combinedCompile perFileCompiles pinnedKernelPackages;
    };
  } ''
    echo "kernel-patch-build: apply matrix + combined compile OK (Linux ${kernelVersion})" > $out
    ${concatMapStringsSep "\n" (d: "test -f ${d}") perFileApplies}
    test -f ${combinedApplyCheck}
    test -e ${combinedCompile}
  '';
in {
  # `compile` = the heavy full-kernel build with all five patches (the one
  # compile paid on the happy path).
  compile = combinedCompile;
  inherit applies perFileCompiles all;
}
