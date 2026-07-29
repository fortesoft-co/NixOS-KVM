# Layer 3 (PATCHED KERNEL) guest-OS boot test — the RDTSC patched-boot test
# (BESPOKE-PATCH-DESIGN.md §8 "Layer 3 test (later)").
#
# Option B (guest-smbios-boot.nix) and the patched-QEMU variant boot the AD-on
# guest inside a test VM running the STOCK kernel. This test boots the same
# guest inside a test VM running the PINNED + PATCHED kernel (Linux 6.18.38 +
# the five linux-6.18-ad-*.patch files — host/kernel.nix's production wiring,
# triggered by antiDetection.patchKernel = true on the test VM). It verifies:
#
#   1. REGRESSION — the shared 20 SMBIOS/NIC/CPU fields still match: the
#      patched kernel must not break normal guest surfacing. (Reuses the
#      shared expected values via common.nix.)
#
#   2. PATCHED BEHAVIOR TOOK EFFECT — the two runtime surfaces of the patch
#      set, probed from INSIDE the guest (guest-kernel-probe.c):
#      a. CPUID 0x40000000 signature = "GenuineIntel" (cpuid-signature patch)
#      b. user-mode apparent TSC frequency / kernel-calibrated frequency ≈
#         rdtsc_user_divisor (default 8), asserted in [5, 12]
#         (rdtsc-timing patch). The guest kernel's boot-time calibration runs
#         at CPL 0 (unscaled by design); user-mode RDTSC is scaled — the
#         ratio proves the divisor is active.
#
# What is NOT checked (and why): the MSR_IA32_TSC gate (a guest rdmsr(0x10)
# executes at CPL 0, where both paths pass the real scaled TSC through by
# design — the sync is structural, see the diff extras), the TF+DR0 trap fix
# (needs a guest debugger driving DR0+TF — no practical shell probe), the
# hypercall #UD fix (needs a read-execute VMCALL page — same), and UMWAIT/
# TPAUSE (needs WAITPKG exposure). Those three patches are covered by the
# Layer 2 apply matrix + combined compile; their runtime surfaces are v2
# test material.
#
# Requires nested KVM (same as Option B): the test VM gets /dev/kvm when the
# build host has KVM + nested virt. The patched kernel is REUSED from the
# Layer 2 combined compile (same pinned package + same patch list → same
# derivation → shared /nix/store entry), so this test does NOT rebuild the
# kernel — but it still needs nested KVM to RUN. OPT-IN via patchBuilds:
#   nix build .#patchBuilds.x86_64-linux.anti-detection-kernel-boot --no-link -L
#
# The boot machinery (guest image + test VM + driver templating) is shared
# with Option B via common.nix's mkGuestImage / mkBootTest; the driver script
# is REUSED as-is (guest-smbios-boot-driver.py). The only differences from
# Option B: extraTestVMModules enabling patchKernel, the kernel extras probe
# (compiled C probe + F0 extraction), and the kernel diff-harness extras.
{ lib, pkgs }:
with lib;
let
  common = import ./common.nix { inherit lib pkgs; };
  inherit (common)
    baseGuest generateXML
    mkGuestImage mkBootTest mkExpectedValues mkDiffHarness;

  # Same AD-on guest fixture as Option B — the ONLY difference is the test VM
  # runs the patched kernel. The guest XML is identical (the patch is a
  # host-kernel-level change, not a per-guest XML change).
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
  xmlFile = pkgs.writeText "kvm-guest-adon-kernel.xml" generatedXML;

  # ── Compiled kernel probe ────────────────────────────────────────────────
  # CPUID leaf read + apparent-TSC measurement can't be done from pure shell;
  # this tiny binary runs inside the guest via the extras probe script.
  # Dynamically linked: the binary's glibc store-path dep is tracked by Nix
  # and lands in the guest image's closure automatically.
  kernelProbe = pkgs.runCommand "kernel-probe" { nativeBuildInputs = [ pkgs.stdenv.cc ]; } ''
    mkdir -p $out/bin
    cc -O2 -o $out/bin/kernel-probe ${./scripts/guest-kernel-probe.c}
  '';

  # ── Scripts (extracted into ./scripts/ for maintainability) ──────────────
  # Base probe (the 20-field regression captures) LAYERED with the kernel
  # extras probe (F0 extraction + the compiled probe). The extras script has
  # the probe binary's store path substituted in (@KERNEL_PROBE_BIN@).
  baseProbe = pkgs.writeShellScript "guest-probe-base"
    (readFile ./scripts/guest-probe-base.sh);
  kernelExtrasProbe = pkgs.writeShellScript "guest-probe-kernel-extras"
    (replaceStrings
      [ "@KERNEL_PROBE_BIN@" ]
      [ "${kernelProbe}/bin/kernel-probe" ]
      (readFile ./scripts/guest-probe-kernel-extras.sh));
  diffHarness = mkDiffHarness {
    name = "kernel-boot";
    extras = readFile ./scripts/guest-kernel-diff-extras.sh;
  };

  # Expected values: the shared 20-field core PLUS the kernel-patch
  # expectations. The ratio bounds are loose on purpose (divisor default 8;
  # nested-virt + calibration noise) — [5, 12] still proves the divisor is
  # active (unpatched ratio would be ~1).
  expectedValues = mkExpectedValues {
    name = "kernel-boot";
    extraLines = ''
      EXPECTED_kernel_cpuid_signature=GenuineIntel
      EXPECTED_kernel_tsc_ratio_min=5
      EXPECTED_kernel_tsc_ratio_max=12
    '';
  };

  guestImage = mkGuestImage {
    name = "adon";
    probeScripts = [ baseProbe kernelExtrasProbe ];
  };
in
mkBootTest {
  name = "anti-detection-kernel-boot";
  inherit guestImage xmlFile diffHarness expectedValues;
  # Reuse Option B's driver — it's generic (define/start "adon", wait for
  # poweroff, run diff harness on the results disk).
  driverScript = ./scripts/guest-smbios-boot-driver.py;
  # The only behavioral difference from Option B: make the test VM boot the
  # pinned + patched kernel (host/kernel.nix's production wiring). mkForce so
  # it overrides kvmTestModule's patchKernel = false. The kernel is reused
  # from the Layer 2 combined compile (same derivation), not rebuilt.
  extraTestVMModules = [
    ({ lib, ... }: { cfg.kvm.host.antiDetection.patchKernel = lib.mkForce true; })
  ];
}
