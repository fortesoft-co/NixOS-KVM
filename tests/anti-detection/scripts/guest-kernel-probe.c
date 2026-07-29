/*
 * Kernel-patch probe — runs INSIDE the booted guest (Layer 3 kernel
 * patched-boot test, kernel-boot.nix). Emits KPROBE:<key>:<value> lines the
 * host-side diff harness asserts against.
 *
 * Two surfaces:
 *
 *   1. CPUID leaf 0x40000000 hypervisor signature — the kernel patch
 *      (linux-6.18-ad-cpuid-signature.patch) rewrites the leaf content to
 *      "GenuineIntel" at the KVM level.
 *
 *   2. Apparent user-mode TSC frequency — the RDTSC patch
 *      (linux-6.18-ad-rdtsc-timing.patch) scales the user-mode-visible TSC
 *      by rdtsc_user_divisor (default 8). Measuring apparent TSC advance
 *      against CLOCK_MONOTONIC wall time gives an apparent frequency of
 *      ~real_freq/8. The guest kernel's own boot-time TSC calibration
 *      (dmesg "tsc: Detected", passed in as argv[1]) runs at CPL 0 and is
 *      unscaled, so kernel_freq / apparent_freq ~= 8.
 *
 * Dynamically linked; its glibc store-path dependency is tracked by Nix and
 * lands in the guest image closure automatically (see kernel-boot.nix).
 */
#include <cpuid.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static inline uint64_t rdtsc(void)
{
	uint32_t lo, hi;

	__asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
	return ((uint64_t)hi << 32) | lo;
}

static double now_mono(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
	uint32_t eax, ebx, ecx, edx;
	char sig[13];
	double samples[5];
	double apparent_hz;
	int i, j;

	/* ── CPUID 0x40000000 hypervisor signature (ebx, ecx, edx order) ── */
	/* Raw __cpuid_count, NOT __get_cpuid_count: gcc's __get_* guards clamp
	 * the requested leaf to the max basic leaf (cpuid eax=0) and synthesize
	 * zeros WITHOUT executing the instruction for out-of-range leaves —
	 * which would report fake zeros here without ever VM-exiting. */
	eax = 0x40000000;
	__cpuid_count(0x40000000, 0, eax, ebx, ecx, edx);
	memcpy(sig + 0, &ebx, 4);
	memcpy(sig + 4, &ecx, 4);
	memcpy(sig + 8, &edx, 4);
	sig[12] = '\0';
	printf("KPROBE:cpuid_signature:%s\n", sig);

	/* ── Leaf 1 hypervisor bit (ecx bit 31) — informational ── */
	__cpuid_count(1, 0, eax, ebx, ecx, edx);
	printf("KPROBE:hypervisor_bit:%u\n", (ecx >> 31) & 1);

	/* ── Apparent TSC frequency: median of 5 x 100ms wall-clock windows ── */
	for (i = 0; i < 5; i++) {
		struct timespec req = { 0, 100 * 1000 * 1000 };
		double t0, t1;
		uint64_t c0, c1;

		t0 = now_mono();
		c0 = rdtsc();
		nanosleep(&req, NULL);
		c1 = rdtsc();
		t1 = now_mono();
		samples[i] = (double)(c1 - c0) / (t1 - t0);
	}
	/* insertion sort, take median */
	for (i = 0; i < 5; i++)
		for (j = i + 1; j < 5; j++)
			if (samples[j] < samples[i]) {
				double t = samples[i];

				samples[i] = samples[j];
				samples[j] = t;
			}
	apparent_hz = samples[2];
	printf("KPROBE:tsc_apparent_mhz:%.1f\n", apparent_hz / 1e6);

	/* ── Ratio vs the kernel-calibrated (CPL0, unscaled) frequency ── */
	if (argc > 1) {
		double kernel_mhz = atof(argv[1]);

		if (kernel_mhz > 0.0)
			printf("KPROBE:tsc_ratio:%.2f\n",
			       kernel_mhz / (apparent_hz / 1e6));
	}

	return 0;
}
