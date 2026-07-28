# Layer 3 (PATCHED QEMU) SMBIOS guest-OS boot test.
#
# Option B (guest-smbios-boot.nix) proved the AD SMBIOS/NIC/CPU values surface
# inside a booted guest under nixpkgs' PREBUILT (unpatched) QEMU. This test does
# the same boot under a PATCHED QEMU — built from source with the dynamic
# manufacturer-token patch (host/libvirtd.nix's overrideAttrs, triggered by
# antiDetection.patchQemu = true on the test VM). It verifies two things:
#
#   1. REGRESSION — the same 20 SMBIOS/NIC/CPU fields Option B checks still
#      match. The patched QEMU must not break AD surfacing: every -smbios / -cpu
#      / -net value the module produces must still reach the guest's firmware
#      tables. (Reuses Option B's expected values via common.nix.)
#
#   2. PATCHED STRINGS TOOK EFFECT — the QEMU string replacements actually
#      surface in the booted guest. Three reliable x86 surfaces are checked:
#      a. fw_cfg ACPI device _HID: QEMU0002 -> <token>0002 (hw/i386/fw_cfg.c)
#         — token-substituted. /sys/bus/acpi/devices/ must list <token>0002:00
#         and must NOT list QEMU0002:00. Always present on q35.
#      b. ACPI table OEM ID: "BOCHS " -> "INTEL " (ACPI_BUILD_APPNAME6 in
#         hw/i386/acpi-build.c) — a CONSTANT in the patch (not sed-substituted),
#         so it proves the static-string half took effect (fw_cfg proves the
#         token-substituted half). Read from the FACP table header; no table
#         may carry BOCHS.
#      c. SATA disk model: "QEMU HARDDISK" -> "<token> HARDDISK"
#         (hw/ide/core.c) — AD forces SATA, so disks surface the patched model
#         via /sys/block/sda/device/model. Assert-if-present (skip if the
#         surface is absent rather than fail spuriously).
#      Input device names are captured for diagnostics but NOT asserted: AD
#      uses PS/2 input, and PS/2 device names are kernel-generic (the QEMU
#      handler name doesn't surface for PS/2 — only USB HID names do, via USB
#      product strings, and there's no USB tablet under AD).
#
# What is NOT checked here (and why): SMBIOS defaults are overridden by AD
#      -smbios blocks; the KVM CPUID signature path isn't taken (hypervisor=off);
#      the virtio PCI vendor-ID patch has no virtio devices to apply to (SATA
#      disks, e1000e NIC, no balloon/rng/agent); EDID isn't generated (AD forces
#      std vga); ARM/s390/ppc strings are the wrong arch. The Layer 2 compile
#      test (anti-detection-qemu-compile) covers "does the patched QEMU build";
#      this test covers "does it run + do the reliable x86 replacements surface."
#      Full per-string verification isn't feasible in one x86 fixture (many
#      strings are arch/backend-specific), but the three surfaces above cover
#      both the token-substituted and static halves of the patch.
#
# Requires nested KVM (same as Option B) AND builds QEMU from source on the test
# VM (~10+ min, cached). OPT-IN via patchBuilds, NOT in checks:
#   nix build .#patchBuilds.x86_64-linux.anti-detection-guest-smbios-patched --no-link -L
#
# The boot machinery (guest image + test VM + driver templating) is shared with
# Option B via common.nix's mkGuestImage / mkBootTest. The driver script is
# REUSED as-is (guest-smbios-boot-driver.py) — it's generic: define XML, start
# the "adon" domain, wait for poweroff, run the diff harness on the results
# disk. The only difference from Option B is extraTestVMModules enabling
# patchQemu, a probe script with the ACPI-device capture, and a diff harness
# with the patched-string assertions.
{ lib, pkgs }:
with lib;
let
  common = import ./common.nix { inherit lib pkgs; };
  inherit (common)
    baseGuest generateXML
    es hostManufacturer
    mkGuestImage mkBootTest mkExpectedValues mkDiffHarness;

  # Same AD-on synthetic guest as Option B — the ONLY difference is the test VM
  # runs a patched QEMU. The guest XML is identical (the patch is a host-level
  # binary change, not a per-guest XML change).
  fullGuest = baseGuest // {
    vcpus = 1;
    memory = 1024;
    disks = [
      { path = "/var/lib/libvirt/images/adon.qcow2"; format = "qcow2"; device = "disk"; bus = "virtio"; boot = null; cache = null; aio = null; discard = null; iothread = null; ssd = false; serial = null; readOnly = false; size = null; sourceUrl = null; }
      { path = "/var/lib/libvirt/images/adon-results.raw"; format = "raw"; device = "disk"; bus = "virtio"; boot = null; cache = null; aio = null; discard = null; iothread = null; ssd = false; serial = null; readOnly = false; size = null; sourceUrl = null; }
    ];
    networks = [ { type = "network"; source = "default"; model = "virtio"; mac = null; } ];
  };

  generatedXML = generateXML "adon" fullGuest;
  xmlFile = pkgs.writeText "kvm-guest-adon-patched.xml" generatedXML;

  # ── Scripts (extracted into ./scripts/ for maintainability) ──────────────
  # The probe is the shared base (guest-probe-base.sh — the SMBIOS/NIC/CPU/
  # PCI/ACPI-tables/block-models captures the 20-field regression diffs against)
  # LAYERED with the patched-extras probe (the fw_cfg ACPI device + ACPI OEM ID
  # + input-device captures the patched-string assertions diff against). No
  # duplication: the base is shared with Option B; only the extras are
  # patched-specific. mkGuestImage runs the list and wraps the concat in one
  # ===PROBE-START/END=== marker pair. The diff harness + expected values reuse
  # common.nix's shared 20-field core (mkDiffHarness / mkExpectedValues) with
  # the patched-specific extras layered on.
  baseProbe = pkgs.writeShellScript "guest-probe-base"
    (readFile ./scripts/guest-probe-base.sh);
  patchedExtrasProbe = pkgs.writeShellScript "guest-probe-patched-extras"
    (readFile ./scripts/guest-probe-patched-extras.sh);
  diffHarness = mkDiffHarness {
    name = "guest-smbios-patched";
    extras = readFile ./scripts/guest-smbios-patched-diff-extras.sh;
  };

  # Expected values: the shared 20 SMBIOS/NIC/CPU fields (regression, via
  # mkExpectedValues) PLUS the patched-string expectations derived from the
  # host-selected manufacturer. The patchToken is seed-selected on the host and
  # baked into the patched QEMU binary; the fw_cfg ACPI _HID becomes
  # <patchToken>0002. The ACPI OEM ID is a patch constant (INTEL).
  expectedValues = mkExpectedValues {
    name = "guest-smbios-patched";
    extraLines = ''
      EXPECTED_patch_token=${es hostManufacturer.patchToken}
      EXPECTED_acpi_fwcfg_hid=${es "${hostManufacturer.patchToken}0002"}
      # ACPI OEM ID is a CONSTANT in the patch (ACPI_BUILD_APPNAME6 "BOCHS " ->
      # "INTEL "), not sed-token-substituted — same for every manufacturer. Proves
      # the static-string half took effect (fw_cfg _HID proves the token half).
      EXPECTED_acpi_oem_id=INTEL
    '';
  };

  guestImage = mkGuestImage {
    name = "adon";
    probeScripts = [ baseProbe patchedExtrasProbe ];
  };
in
mkBootTest {
  name = "anti-detection-guest-smbios-patched";
  inherit guestImage xmlFile diffHarness expectedValues;
  # Reuse Option B's driver — it's generic (define/start "adon", wait for
  # poweroff, run diff harness on the results disk).
  driverScript = ./scripts/guest-smbios-boot-driver.py;
  # The only behavioral difference from Option B: make the test VM's libvirtd
  # use the dynamically-patched QEMU (built from source). mkForce so it
  # overrides kvmTestModule's patchQemu = false.
  extraTestVMModules = [
    ({ lib, ... }: { cfg.kvm.host.antiDetection.patchQemu = lib.mkForce true; })
  ];
}