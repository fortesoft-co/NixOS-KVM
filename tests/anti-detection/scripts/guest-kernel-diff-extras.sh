# Kernel-patch extras fragment — the patched-kernel assertions, layered BETWEEN
# the shared 20-field regression checks (guest-smbios-diff-base.sh) and the
# summary (guest-smbios-diff-summary.sh) by mkDiffHarness. Uses check()/PROBE/
# PASS/FAIL from the base fragment (in scope via concatenation).
#
# Asserts the two runtime surfaces of the bespoke kernel patch set
# (BESPOKE-PATCH-DESIGN.md §8 stage 4 a/b):
#   a. CPUID 0x40000000 signature rewritten to "GenuineIntel"
#      (linux-6.18-ad-cpuid-signature.patch)
#   b. user-mode apparent TSC frequency compressed by rdtsc_user_divisor
#      (default 8) vs the kernel-calibrated frequency
#      (linux-6.18-ad-rdtsc-timing.patch)
#
# The §3.7 "MSR path matches RDTSC path" sync is STRUCTURAL (both paths carry
# the same gate + divisor constant — verifiable by reading the patches): a
# guest rdmsr(0x10) executes at CPL 0, where BOTH gates pass the real scaled
# TSC through by design, so no userspace-observable runtime check can
# distinguish them. The ratio check below is the runtime half.
echo "=== KERNEL PATCH — CPUID signature + RDTSC scaling ==="

# Extract a KPROBE:<key>:<value> line from the probe payload.
kprobe() { printf '%s\n' "$PROBE" | awk -F':' -v k="$1" '$1=="KPROBE" && $2==k {sub("^KPROBE:"k":",""); print; exit}'; }

# Informational context (not asserted): kernel-calibrated MHz, apparent MHz,
# hypervisor bit state.
echo "  info: tsc_kernel_mhz=$(kprobe tsc_kernel_mhz) tsc_apparent_mhz=$(kprobe tsc_apparent_mhz) hypervisor_bit=$(kprobe hypervisor_bit)"

# a. CPUID signature — exact match.
check "kernel.cpuid-signature" "$(kprobe cpuid_signature)" "$EXPECTED_kernel_cpuid_signature"

# b. TSC ratio — range check (divisor default 8; loose bounds for nested-virt
# and calibration noise: [5, 12] still proves the divisor is active vs 1).
RATIO=$(kprobe tsc_ratio)
if [ -z "$RATIO" ]; then
  echo "FAIL [kernel.tsc-ratio]"
  echo "  got : no KPROBE:tsc_ratio line (probe could not read kernel-calibrated freq)"
  echo "  want: ratio in [$EXPECTED_kernel_tsc_ratio_min, $EXPECTED_kernel_tsc_ratio_max]"
  FAIL=$((FAIL + 1))
elif awk -v r="$RATIO" -v lo="$EXPECTED_kernel_tsc_ratio_min" -v hi="$EXPECTED_kernel_tsc_ratio_max" 'BEGIN { exit !(r+0 >= lo+0 && r+0 <= hi+0) }'; then
  echo "OK   [kernel.tsc-ratio]: $RATIO in [$EXPECTED_kernel_tsc_ratio_min, $EXPECTED_kernel_tsc_ratio_max] (divisor 8 active)"
  PASS=$((PASS + 1))
else
  echo "FAIL [kernel.tsc-ratio]"
  echo "  got : $RATIO"
  echo "  want: in [$EXPECTED_kernel_tsc_ratio_min, $EXPECTED_kernel_tsc_ratio_max] (divisor 8)"
  FAIL=$((FAIL + 1))
fi
