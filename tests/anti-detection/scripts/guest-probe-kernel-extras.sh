#!/bin/sh
# Kernel-patch extras probe — runs INSIDE the booted guest (kernel patched-boot
# test only), layered AFTER guest-probe-base.sh in the probe list. Extracts the
# guest kernel's boot-time TSC calibration (CPL 0 — unscaled by the patch) and
# hands it to the compiled kernel probe, which measures the user-mode apparent
# TSC frequency and the CPUID 0x40000000 signature.
#
# @KERNEL_PROBE_BIN@ is substituted at eval time with the store path of the
# statically-linked probe binary (see kernel-boot.nix) — the store path is
# referenced by the probe service, so it's in the guest closure.
#
# Emits ONLY its `--- section ---` block (no ===PROBE-START/END=== markers —
# mkGuestImage wraps the concatenated probe list in one marker pair).
set -e

echo "--- kernel-patch ---"

# Kernel-calibrated TSC frequency (guest kernel, CPL 0 — the patch's gate
# leaves kernel-mode reads unscaled). dmesg line: "tsc: Detected 3800.000 MHz
# processor". Fall back to /proc/cpuinfo's cpu MHz (same calibration).
F0=$(dmesg | sed -n 's/.*tsc: Detected \([0-9.]*\) MHz processor.*/\1/p' | head -1)
[ -z "$F0" ] && F0=$(sed -n 's/^cpu MHz[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' /proc/cpuinfo | head -1)
echo "KPROBE:tsc_kernel_mhz:$F0"

@KERNEL_PROBE_BIN@ "$F0"
