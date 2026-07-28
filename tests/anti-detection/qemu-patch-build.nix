# Layer 2 — Tier 2 (QEMU) patch-build test (OPT-IN).
#
# Verifies that the dynamic manufacturer-token rewrite in
# modules/kvm/host/libvirtd.nix (the `runCommand` + `sed` that swaps the ASUS
# placeholders in patches/qemu-10.2.2-anti-detection.patch for a selected
# manufacturer's patchToken / realMachine / defaultProduct) produces a VALID
# patch for ALL FOUR manufacturer tokens (ASUS / MSIC / GBTC / ASRK), not just
# the default.
#
# Two levels of "valid", each catching a different failure mode:
#
#   1. Applies cleanly  — `patch -p1` against unpacked QEMU 10.2.2 source, for
#      EACH of the four tokens (parallel, cheap — unpack only, no compile).
#      Catches a `sed` substitution that breaks patch context/offsets enough
#      that a hunk is rejected. Also asserts the token actually appears in the
#      patched source (the sed didn't no-op).
#
#   2. Compiles         — a full QEMU 10.2.2 build with the dynamic patch for
#      the manufacturer the seed would actually select (hostManufacturer), for
#      ONE token. Catches C syntax errors / broken string literals that the
#      apply-check can't see (a patch can apply cleanly and still produce code
#      that won't compile). Heavy (minutes), hence opt-in.
#
# Why not compile all four: the four tokens differ only by 4-char string
# substitutions of equal length (ASUS/MSIC/GBTC/ASRK). A compile that passes
# for one is ~certain to pass for the others — the token-specific risk is
# "did the substitution break the patch", which the apply-check covers at
# ~zero cost. Compiling QEMU four times would burn ~4x the CPU for no extra
# signal.
#
# This is OPT-IN: exposed via a separate flake output (`patchBuilds`), NOT in
# `checks`, so `nix flake check` stays fast by default. Build with:
#
#   nix build .#patchBuilds.x86_64-linux.anti-detection-qemu --no-link -L
#
# Granular runs (the cheap apply-checks without the heavy compile):
#
#   nix build .#patchBuilds.x86_64-linux.anti-detection-qemu-applies --no-link -L
#
# Returns an attrset { applies, compile, all } — the flake wires each to its
# own output. `all` is the convenience attr that triggers every derivation.
{ lib, pkgs }:
with lib;
let
  # ── Manufacturer registry (the REAL one from the module) ─────────────────
  # Iterate over ALL four manufacturers directly rather than going through
  # hostManufacturer (which picks one by seed) so every patchToken is exercised.
  # cpuVendor/cpuSocket only affect socket-aware selection, which we bypass by
  # iterating the raw list.
  #
  # Single-source fixture: import the SAME seed/vendor/socket as the boot tests
  # (common.nix) so this compile test builds the SAME manufacturer's patched QEMU
  # the boot tests run — one seed value in one place, no drift, no separate
  # recompile for a different manufacturer. common.nix's seed selects gigabyte
  # (GBTC, a NON-template token) so the static binary check below catches a
  # broken sed: for a non-template token the present check for
  # `<m.defaultProduct>` (e.g. X570 AORUS ELITE) would fail if the sed no-op'd
  # (leaving the ASUS template M4A88TD-M).
  common = import ./common.nix { inherit lib pkgs; };
  hostAd = import ../../modules/kvm/host/anti-detection.nix {
    config = {
      cfg.kvm.host = { inherit (common) hwidSeed cpuVendor cpuSocket; };
    };
    inherit lib pkgs;
  };
  manufacturers = hostAd.manufacturers;

  # Reuse the PRODUCTION dynamic-patch function (host/anti-detection.nix's
  # mkDynamicPatch) — NOT a replica. This is the whole point of the refactor:
  # the test exercises the EXACT sed recipe libvirtd.nix uses, so if the recipe
  # changes there's one place to update and the test can't drift from production.
  dynamicPatchFor = hostAd.mkDynamicPatch;

  # ── QEMU 10.2.2 source (unpack only — no configure, no build) ────────────
  # Shared by all four apply-checks so the tarball is fetched + unpacked ONCE
  # (Nix shares the store path). `patch -p1` runs against this tree.
  qemuVersion = "10.2.2";
  qemuSrc = pkgs.fetchurl {
    url = "https://download.qemu.org/qemu-${qemuVersion}.tar.xz";
    sha256 = "0xp1457v1hw5szf7gx942xvvk6pasarbqfijfam1f54wy9pjjjvq";
  };
  qemuSourceUnpacked = pkgs.stdenv.mkDerivation {
    name = "qemu-${qemuVersion}-src";
    src = qemuSrc;
    dontConfigure = true;
    dontBuild = true;
    # unpackPhase extracts into qemu-${qemuVersion}/ and cds into it; copy the
    # contents (not the wrapper dir) so `cd src && patch -p1` lands at the
    # right level (a/block/vhdx.c -> block/vhdx.c).
    installPhase = "cp -r . $out";
  };

  # ── Level 1: applies-cleanly check (all 4 tokens) ────────────────────────
  # Real `patch -p1` (not --dry-run) against a throwaway copy, then grep for
  # the token to confirm the sed actually substituted something. Fails if any
  # hunk is rejected OR the token is absent. Cheap (no compile).
  patchAppliesCheck = m: pkgs.runCommand "check-qemu-patch-applies-${m.id}" {} ''
    set -euo pipefail
    cp -r ${qemuSourceUnpacked} src
    chmod -R u+w src
    cd src
    patch -p1 --no-backup-if-mismatch < ${dynamicPatchFor m}
    if ! grep -rIq -- "${m.patchToken}" .; then
      echo "FAIL: patchToken '${m.patchToken}' absent from patched source" >&2
      exit 1
    fi
    touch $out
  '';

  applyChecks = map patchAppliesCheck manufacturers;

  # ── Level 2: full QEMU compile (the seed-selected default token) ──────────
  # Mirrors the former scripts/test-qemu-build.nix: build QEMU 10.2.2 from
  # source with the dynamic patch for the manufacturer the seed would
  # actually select on a real host. This is the heavy derivation (minutes).
  # Overwrites upstream nixpkgs patches (avoids the qemu-ga patch conflict
  # the standalone harness hit) — same approach as the former test.
  defaultManufacturer = hostAd.hostManufacturer;
  defaultPatch = dynamicPatchFor defaultManufacturer;

  customQemu = pkgs.qemu.overrideAttrs (old: rec {
    version = qemuVersion;
    src = qemuSrc;
    patches = [ defaultPatch ];
    configureFlags = (old.configureFlags or []) ++ [
      "--disable-docs"
      "--disable-gtk"
      "--target-list=x86_64-softmmu"
    ];
    outputs = lib.remove "doc" old.outputs;
  });

  # ── Level 3: static binary string check (the compiled artifact) ──────────
  # Runs `strings` (binutils) on the compiled patched qemu-system-x86_64 ELF and
  # verifies the sed did what we asked: the SELECTED manufacturer's strings are
  # present (parameterized on `m` — `<m.patchToken>0002`, `<m.defaultProduct>`,
  # `<m.patchToken>-PC`, …) AND the QEMU defaults the patch replaces are gone
  # (`QEMU0002`, `QEMU HARDDISK`, `KVMKVMKVM`, … — robust for every manufacturer,
  # since the patch template always replaces QEMU defaults regardless of token).
  #
  # Covers ALL string replacements — including ones that DON'T surface at
  # runtime (USB HID names, PS/2 names, drive serial, the smbios_set_defaults
  # product, etc.). The runtime boot test only sees surfaces that reach the
  # guest. Numeric changes (virtio vendor ID 0x1af4→0x8086, EDID model_nr) aren't
  # string-greppable; the string half is covered here, the runtime OEM-ID check
  # covers the ACPI constant.
  #
  # Uses strings(1) (not grep -aF on the raw ELF): grepping a 32MB binary directly
  # matches code-section byte sequences (false matches) and is slow; strings
  # extracts the .rodata literals correctly. The real ELF is bin/.qemu-system-
  # x86_64-wrapped (bin/qemu-system-x86_64 is a makeBinaryWrapper stub) — pick the
  # largest matching file to be robust.
  patchedStringCheck = let m = defaultManufacturer; in pkgs.runCommand "check-qemu-patched-strings" {
    nativeBuildInputs = [ pkgs.binutils ];
    passthru = { inherit customQemu defaultManufacturer; };
  } ''
    set -e
    BIN=$(find "${customQemu}/bin" -name '*qemu-system-x86_64*' -type f -printf '%s	%p\n' | sort -rn | head -1 | cut -f2-)
    [ -n "$BIN" ] || { echo "FAIL: no qemu-system-x86_64 binary found in ${customQemu}/bin"; exit 1; }
    echo "static string check: $BIN (manufacturer=${m.id}, token=${m.patchToken})"
    pass=0; fail=0
    assertPresent() { if strings "$BIN" | grep -qF -- "$1"; then echo "OK   present: '$1'"; pass=$((pass+1)); else echo "FAIL missing-expected-present: '$1'"; fail=$((fail+1)); fi; }
    assertAbsent()  { if strings "$BIN" | grep -qF -- "$1"; then echo "FAIL present-expected-absent: '$1'"; fail=$((fail+1)); else echo "OK   absent:  '$1'"; pass=$((pass+1)); fi; }
    # --- token-substituted (sed ran with the selected manufacturer's token) ---
    assertPresent "${m.patchToken}0002"            # fw_cfg ACPI _HID
    assertPresent "${m.patchToken}-PC"             # smbios_set_defaults version
    assertPresent "${m.defaultProduct}"            # smbios_set_defaults product
    assertPresent "${m.patchToken} DVD-ROM"        # IDE CD model
    assertPresent "${m.patchToken} MICRODRIVE"     # IDE CF model
    assertPresent "${m.patchToken}%05d"            # IDE drive serial
    assertPresent "${m.patchToken} HID Keyboard"   # USB HID handler name
    assertPresent "${m.patchToken} PS/2 Keyboard"  # PS/2 handler name
    # --- constants (the static-string half of the patch) ---
    assertPresent "GenuineIntel"                  # KVM CPUID signature
    # --- QEMU defaults gone (the patch replaced them) ---
    assertAbsent "QEMU0002"
    assertAbsent "QEMU HARDDISK"
    assertAbsent "QEMU DVD-ROM"
    assertAbsent "QEMU MICRODRIVE"
    assertAbsent "KVMKVMKVM"
    assertAbsent "QEMU Monitor"
    echo ""
    echo "=== Summary: $pass passed, $fail failed ==="
    [ "$fail" -eq 0 ] || exit 1
    touch $out
  '';

  # ── Aggregate ────────────────────────────────────────────────────────────
  # `all` references every derivation so a single build pulls in all four
  # apply-checks (parallel, cheap) + the full QEMU compile (heavy) + the static
  # string check (cheap once the compile is cached). Nix parallelizes the
  # independent derivations automatically. The `test -e` lines force each store
  # path to be built.
  all = pkgs.runCommand "qemu-patch-build-all" {
    passthru = {
      inherit applyChecks customQemu defaultManufacturer manufacturers patchedStringCheck;
      applyCheck = listToAttrs (map (m: nameValuePair m.id (patchAppliesCheck m)) manufacturers);
    };
  } ''
    echo "qemu-patch-build: all 4 token patches apply + default-token compile + static string check OK" > $out
    ${concatMapStringsSep "\n" (d: "test -f ${d}") applyChecks}
    test -e ${customQemu}
    test -f ${patchedStringCheck}
  '';
in {
  # `compile` = the heavy full-QEMU build with the default token's patch
  # (alias for customQemu — the name documents its role in the flake output).
  compile = customQemu;
  inherit applyChecks customQemu all patchedStringCheck;
  # `applies` = the cheap all-four-tokens check alone (no heavy compile). Lets
  # a user run the fast half interactively without waiting on a QEMU build.
  # (runCommand rather than symlinkJoin because each check emits a regular
  # file, not a directory — symlinkJoin rejects file inputs.)
  applies = pkgs.runCommand "qemu-patch-applies-all" {
    passthru.checks = listToAttrs (map (m: nameValuePair m.id (patchAppliesCheck m)) manufacturers);
  } ''
    ${concatMapStringsSep "\n" (d: "test -f ${d}") applyChecks}
    echo "all 4 manufacturer-token patches apply cleanly to QEMU ${qemuVersion}" > $out
  '';
}
