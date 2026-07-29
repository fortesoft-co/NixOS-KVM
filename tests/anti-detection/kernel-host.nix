# Layer 3 (PATCHED HOST) runtime-behavior test — non-nested.
#
# Unlike kernel-boot.nix (which nests: test VM runs the patched kernel, inner
# guest probed via libvirt), this test runs the STOCK kernel in the test VM
# and probes it DIRECTLY — no inner guest, no libvirt, no results disk. The
# test VM is a KVM guest of the HOST; its CPUID/RDTSC exits go straight to the
# HOST's (patched) kvm_intel. This tests the ACTUAL running host kernel.
#
# Self-validating: if the host isn't running the patched kernel, the probes
# fail (CPUID = KVMKVMKVM, ratio ≈ 1).
#
# Probes (run inside the test VM via testScript, no results-disk transport):
#   1. CPUID 0x40000000 signature → GenuineIntel (cpuid-signature patch)
#   2. User-mode TSC ratio → ~8 (rdtsc-timing patch, divisor default 8)
#
# What is NOT runtime-tested here (and why):
#   - TF+DR0 trap fix: the patched kvm_vcpu_do_singlestep is in the emulation
#     path. Execute breakpoints are caught by kvm_vcpu_check_code_breakpoint
#     BEFORE the patched handler runs. When the handler does detect BS|B0, it
#     exits to userspace (KVM_EXIT_DEBUG) instead of injecting into the guest —
#     so in-guest ptrace can't observe it. Testing requires KVM_SET_GUEST_DEBUG
#     (QEMU-level guest debugging), not in-guest ptrace. Compile-verified only.
#   - Hypercall #UD fix: emulator_fix_hypercall is only reached via the
#     instruction emulator's em_hypercall (for #UD exits). On Intel VMX, VMCALL
#     always exits via EXIT_REASON_VMCALL → handle_vmcall → kvm_emulate_hypercall
#     (returns -ENOSYS/-EPERM, never reaching the emulator). The patched path
#     is unreachable on Intel. Compile-verified only; runtime test = AMD (v2).
#   - MSR_TSC sync: rdmsr(0x10) runs at CPL 0 where both gates pass through by
#     design — structural, not runtime-observable.
#
# CARVE-OUT: this test requires the BUILD HOST to be running the patched kernel
# (antiDetection.patchKernel = true) AND have KVM. NOT in `checks` — opt-in:
#   nix build .#patchBuilds.x86_64-linux.anti-detection-kernel-host --no-link -L
{ lib, pkgs }:
with lib;
let
  common = import ./common.nix { inherit lib pkgs; };
  inherit (common) kernelProbeExpected;

  kernelProbe = pkgs.runCommand "kernel-probe" { nativeBuildInputs = [ pkgs.stdenv.cc ]; } ''
    mkdir -p $out/bin
    cc -O2 -o $out/bin/kernel-probe ${./scripts/guest-kernel-probe.c}
  '';

  exp = kernelProbeExpected;
in
pkgs.testers.runNixOSTest {
  name = "anti-detection-kernel-host";

  nodes.machine = { ... }: {
    # The test VM is a KVM guest of the HOST (L0→L1, not nested). The NixOS
    # test driver uses KVM automatically when the host has /dev/kvm. The test
    # VM's CPUID/RDTSC exits go to the host's (patched) kvm_intel.
    virtualisation.cores = 2;
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ kernelProbe ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    def parse_kprobe(output, key):
        """Extract a KPROBE:key:value line from probe output."""
        for line in output.strip().split("\n"):
            if line.startswith(f"KPROBE:{key}:"):
                return line.split(":", 2)[2]
        return None

    counts = [0, 0]  # [passed, failed]

    def check(label, got, want):
        if got == want:
            machine.log(f"OK   [{label}]: '{got}'")
            counts[0] += 1
        else:
            machine.log(f"FAIL [{label}]")
            machine.log(f"  got : '{got}'")
            machine.log(f"  want: '{want}'")
            counts[1] += 1

    def check_range(label, got, lo, hi):
        try:
            val = float(got)
        except (TypeError, ValueError):
            machine.log(f"FAIL [{label}]")
            machine.log(f"  got : '{got}' (not a number)")
            counts[1] += 1
            return
        if lo <= val <= hi:
            machine.log(f"OK   [{label}]: {val} in [{lo}, {hi}]")
            counts[0] += 1
        else:
            machine.log(f"FAIL [{label}]")
            machine.log(f"  got : {val}")
            machine.log(f"  want: in [{lo}, {hi}]")
            counts[1] += 1

    # ── CPUID signature + TSC ratio (shared probe, same as nested test) ──
    f0 = machine.succeed(
        "dmesg | sed -n 's/.*tsc: Detected \\([0-9.]*\\) MHz processor.*/\\1/p' | head -1"
    ).strip()
    if not f0:
        f0 = machine.succeed(
            "sed -n 's/^cpu MHz\\s*:\\s*\\([0-9.]*\\)/\\1/p' /proc/cpuinfo | head -1"
        ).strip()
    machine.log(f"info: tsc_kernel_mhz={f0}")

    basic = machine.succeed(f"kernel-probe {f0}")
    machine.log(basic)

    check("kernel.cpuid-signature",
          parse_kprobe(basic, "cpuid_signature"),
          "${exp.cpuid_signature}")
    check_range("kernel.tsc-ratio",
                parse_kprobe(basic, "tsc_ratio"),
                ${toString exp.tsc_ratio_min},
                ${toString exp.tsc_ratio_max})

    # ── Summary ───────────────────────────────────────────────────────────
    machine.log(f"\n=== Summary: {counts[0]} passed, {counts[1]} failed ===")
    assert counts[1] == 0, f"{counts[1]} check(s) failed"
  '';
}