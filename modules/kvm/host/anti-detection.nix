# Anti-detection: manufacturer registry, selection, and MAC OUI.
#
# Separated from host/lib.nix so the general CPU detection code stays clean.
# This module is imported by guests/anti-detection.nix (for SMBIOS profile
# selection + MAC OUI) and host/libvirtd.nix (for the QEMU patch strings).
#
# Depends on host/lib.nix for hexToInt (seed-based selection), cpuVendor, and
# cpuSocket (socket-aware manufacturer filtering).
{ config, lib, pkgs }:
with lib;
let
  cfg = config.cfg.kvm;
  hostLib = import ./lib.nix { inherit config lib pkgs; };
  inherit (hostLib) hexToInt cpuVendor cpuSocket;

  # ───────── Manufacturer registry ─────────
  # The set of consumer motherboard manufacturers eligible for seed-based
  # selection. Constraint (see CONTEXT.md): only manufacturers that produce
  # BOTH AMD and Intel consumer motherboards qualify, so the seed's choice
  # works regardless of the host's CPU vendor.
  #
  # Each record carries the strings consumed by later steps:
  #   - smbiosManufacturer: full SMBIOS manufacturer string (step 5 profile filter)
  #   - patchToken: 4-char token for QEMU source patches — ACPI HID "XXXX0002"
  #     and per-device strings like "ASUS Keyboard" (step 7 dynamic sed)
  #   - defaultProduct: legacy QEMU x86 fallback product (step 7)
  #   - realMachine: replaces "QEMU Virtual Machine" / "KVM Virtual Machine"
  #     in QEMU source (step 7)
  manufacturers = [
      {
        id = "asus";
        smbiosManufacturer = "ASUSTeK COMPUTER INC.";
        patchToken = "ASUS";
        defaultProduct = "M4A88TD-M";
        realMachine = "ASUS Real Machine";
        # Real OUI registered to ASUSTek Computer Inc. (IEEE OUI registry).
        # Board vendor OUI — kept for reference/validation.
        oui = "04:D9:F5";
      }
      {
        id = "msi";
        smbiosManufacturer = "Micro-Star International Co., Ltd.";
        patchToken = "MSIC";
        defaultProduct = "MS-7C37";
        realMachine = "MSI Real Machine";
        # Real OUI registered to Micro-Star International Co., Ltd.
        # Board vendor OUI (see ASUS entry for rationale).
        oui = "00:01:6C";
      }
      {
        id = "gigabyte";
        smbiosManufacturer = "Gigabyte Technology Co., Ltd.";
        patchToken = "GBTC";
        defaultProduct = "X570 AORUS ELITE";
        realMachine = "Gigabyte Real Machine";
        # Real OUI registered to Gigabyte Technology Co., Ltd.
        # Board vendor OUI (see ASUS entry for rationale).
        oui = "00:13:20";
      }
      {
        id = "asrock";
        smbiosManufacturer = "ASRock";
        patchToken = "ASRK";
        defaultProduct = "X570 Taichi";
        realMachine = "ASRock Real Machine";
        # Real OUI registered to ASRock Inc.
        # Board vendor OUI (see ASUS entry for rationale).
        oui = "00:13:74";
      }
    ];

  # NIC vendor OUI — used for MAC address generation when antiDetection is on.
  # The emulated NIC is always e1000e (Intel 82574L) when AD is on, so the MAC
  # uses Intel's OUI. On real hardware, the MAC is assigned by the NIC chip
  # vendor (Intel), so an ASUS board with an Intel NIC has an Intel OUI MAC +
  # ASUS SMBIOS.
  nicOui = "00:1B:21";  # Intel Corporation (IEEE OUI registry)

  # Deterministically select one manufacturer for the entire host.
  #
  # Why host-level: QEMU is a host-level binary shared across all guests, so
  # the patched strings (keyboard names, ACPI OEM, drive models) must match
  # the SMBIOS manufacturer — and SMBIOS filtering (step 5) must use the same
  # brand for every guest on a host to keep the QEMU↔SMBIOS story consistent.
  #
  # Why seed-based: different installations get different brands based on
  # their hwidSeed, avoiding a "NixOS-KVM always picks ASUS" signature that
  # could be blocklisted. A physical PC has one motherboard brand — a virtual
  # host should too.
  #
  # Formula: sha256(seed + "-manufacturer")[0:7] mod N
  selectManufacturer = seed:
    let
      h = builtins.hashString "sha256" "${seed}-manufacturer";
      idx = lib.mod (hexToInt (substring 0 7 h)) (length manufacturers);
    in
    elemAt manufacturers idx;

  # ───────── Socket-aware manufacturer selection ─────────
  # The curated profile library, imported here so manufacturer selection can be
  # constrained to vendors that actually ship a board for the host's socket.
  smbiosProfiles = import ./smbios-profiles.nix;

  # Manufacturers that have at least one profile for (vendor, socket), in
  # registry order. The seed-based pick is constrained to this set so we never
  # choose a vendor with no matching profile.
  manufacturersForSocket = vendor: socket:
    let
      sock = if socket != null then socket else "unknown";
      profilesFor = m:
        let byVendor = smbiosProfiles.${m.id} or {};
        in (byVendor.${vendor} or {}).${sock} or [];
    in
    filter (m: (profilesFor m) != []) manufacturers;

  # Deterministically select a manufacturer that has profiles for the host's
  # (vendor, socket). Among the eligible vendors, the same sha256-mod formula
  # as selectManufacturer picks one — just over the smaller eligible set. If
  # NO vendor has a profile for the socket, fall back to the unconstrained
  # seed-based pick; the guest then uses fallbackProfile.
  selectManufacturerForSocket = seed: vendor: socket:
    let
      eligible = manufacturersForSocket vendor socket;
    in
    if eligible == [] then
      selectManufacturer seed
    else
      let
        h = builtins.hashString "sha256" "${seed}-manufacturer";
        idx = lib.mod (hexToInt (substring 0 7 h)) (length eligible);
      in
      elemAt eligible idx;

  # The single host-level manufacturer used by the QEMU patch (host/libvirtd.nix)
  # and the SMBIOS profile selection (guests/anti-detection.nix) — so the brand
  # is consistent across those surfaces. The MAC OUI is separate (nicOui, above).
  # Socket-aware: constrained to vendors with a profile for the host's socket.
  #
  # NOTE: this forces cpuVendor/cpuSocket. When cpuSocket = "auto" it runs
  # cpuid_tool during eval, which reads the BUILD machine's CPU — so for
  # remote/cross builds you should set cfg.kvm.host.cpuSocket explicitly.
  hostManufacturer = selectManufacturerForSocket cfg.host.hwidSeed cpuVendor cpuSocket;

  # ───────── Dynamic QEMU patch adaptation ─────────
  # The single source of truth for the sed recipe that adapts the ASUS-template
  # QEMU patch (patches/qemu-10.2.2-anti-detection.patch) to a given manufacturer
  # record: swaps the ASUS placeholders for the record's realMachine /
  # defaultProduct / patchToken. Used by host/libvirtd.nix (with hostManufacturer)
  # AND by the patch-build tests (tests/anti-detection/qemu-patch-build.nix, with
  # each manufacturer) so the test exercises the EXACT production sed — no replica
  # that could drift. Returns a store-path patch file.
  mkDynamicPatch = m: pkgs.runCommand "qemu-anti-detection-${m.id}.patch" {} ''
    sed \
      -e 's/ASUS Real Machine/${m.realMachine}/g' \
      -e 's/M4A88TD-M/${m.defaultProduct}/g' \
      -e 's/ASUS-PC/${m.patchToken}-PC/g' \
      -e 's/ASUS/${m.patchToken}/g' \
      ${../patches/qemu-10.2.2-anti-detection.patch} > $out
  '';
in
{
  inherit manufacturers nicOui selectManufacturer selectManufacturerForSocket
    manufacturersForSocket hostManufacturer smbiosProfiles mkDynamicPatch;
}