# Layer 3 (unpatched) SMBIOS guest-OS boot test — Option B.
#
# Option A (guest-smbios.nix) proved via libvirt's PURE argv computation that
# every SMBIOS/NIC/CPU value the module produces would REACH QEMU. It did NOT
# boot the AD-on guest — `virsh domxml-to-native` computes the QEMU command line
# without starting QEMU. This test closes that gap: it boots a real (minimal)
# NixOS guest UNDER libvirt with the AD-on XML, runs the first-party probe sweep
# from INSIDE the guest (dmidecode / /sys/class/dmi/id / lscpu / ip link / lspci
# / acpi tables / block models), gets the results back to the host, and diffs
# against the same expected-value harness Option A uses (shared via common.nix).
#
# This is the only test that catches the rare class where QEMU/SeaBIOS silently
# IGNORES a passed `-smbios` block — the firmware tables the guest OS reads via
# dmidecode / sysfs would not match what libvirt put on the QEMU command line.
#
# Requires nested KVM: the module emits <domain type='kvm'>, which requires
# /dev/kvm inside the test VM. The test VM gets /dev/kvm when the build host has
# KVM + nested virt enabled. We HARD-FAIL if /dev/kvm is missing (CI without
# nested KVM will fail loudly rather than silently skip — per the user's call).
#
# Machine-independence: same explicit fixture as Option A (hwidSeed/hwidSalt/
# cpuVendor/cpuSocket in common.nix). The guest image build uses the same
# make-disk-image.nix machinery the NixOS test framework uses for its own nodes.
#
# The boot machinery (guest image build + test VM + driver templating) is
# shared via common.nix's mkGuestImage / mkBootTest — extracted so the future
# patched-QEMU / RDTSC boot variants reuse it without rewriting the
# results-transport + nested-KVM scaffolding.
#
# Scripts are extracted into ./scripts/ to avoid maintaining shell/Python inside
# Nix ''...'' strings (escaping issues, no syntax highlighting):
#   scripts/guest-smbios-boot-guest-probe.sh  — runs inside the booted guest
#   scripts/guest-smbios-boot-results-diff.sh — host-side diff harness (static)
#   scripts/guest-smbios-boot-driver.py       — test driver (Python, @PLACEHOLDER@ tokens)
#
# Standalone build:
#   nix build .#checks.x86_64-linux.anti-detection-guest-smbios-boot --no-link
{ lib, pkgs }:
with lib;
let
  common = import ./common.nix { inherit lib pkgs; };
  inherit (common)
    baseGuest generateXML
    mkGuestImage mkBootTest mkExpectedValues mkDiffHarness;

  # Option B adds a real boot disk (the NixOS qcow2 built below) and a raw
  # results disk to the base guest, and switches the NIC to the libvirt default
  # network (the test VM has no br0 bridge). AD-on forces SATA bus + e1000e NIC
  # regardless of what we set here, so the guest sees /dev/sda (boot) + /dev/sdb
  # (results) and an e1000e interface with the expected MAC.
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
  xmlFile = pkgs.writeText "kvm-guest-adon-boot.xml" generatedXML;

  # ── Scripts (extracted into ./scripts/ for maintainability) ──────────────
  # The probe is the shared base only (no test-specific extras for Option B);
  # mkGuestImage runs the list and wraps the concat in one ===PROBE-START/END===
  # marker pair. The diff harness + expected values are the shared 20-field core
  # from common.nix (mkDiffHarness / mkExpectedValues) — Option B has no extras.
  baseProbe = pkgs.writeShellScript "guest-probe-base"
    (readFile ./scripts/guest-probe-base.sh);
  diffHarness = mkDiffHarness { name = "guest-smbios-boot"; };
  expectedValues = mkExpectedValues { name = "guest-smbios-boot"; };

  # ── Minimal NixOS guest image (BIOS-bootable qcow2) + test VM ────────────
  # Both assembled by common.nix's reuse helpers. mkGuestImage builds the
  # qcow2 (make-disk-image.nix, BIOS) with the adon-probe service that runs the
  # probe script list → results disk → poweroff. mkBootTest wires the runNixOSTest:
  # the libvirtd test VM (nested-KVM-sized, kvmTestModule) + the driver script
  # that defines/starts the guest and runs the diff harness. No extraTestVMModules
  # here — this is the UNPATCHED test (nixpkgs' prebuilt QEMU). The patched
  # variant layers a patched-extras probe script + extraTestVMModules enabling
  # antiDetection.patchQemu = true.
  guestImage = mkGuestImage {
    name = "adon";
    probeScripts = [ baseProbe ];
  };
in
mkBootTest {
  name = "anti-detection-guest-smbios-boot";
  inherit guestImage xmlFile diffHarness expectedValues;
  driverScript = ./scripts/guest-smbios-boot-driver.py;
}