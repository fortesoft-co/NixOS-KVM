# Single source of truth for the exact kernel the vendored anti-detection
# patches (linux-6.18-ad-*.patch, this directory) were generated against,
# and for the patch set itself. Imported by BOTH the production wiring
# (host/kernel.nix) and the patch-build test
# (tests/anti-detection/kernel-patch-build.nix) so the two can never drift.
#
# The patches' context is anchored to this EXACT version. A plain
# pkgs.linuxPackages_6_18 tracks the newest 6.18.x stable in nixpkgs and
# would drift out from under the patches on a nixpkgs bump, so the tarball
# is fetched directly and hash-verified instead.
{ pkgs }:
rec {
  version = "6.18.38";

  src = pkgs.fetchurl {
    url = "mirror://kernel/linux/kernel/v6.x/linux-${version}.tar.xz";
    sha256 = "0igh9xy1lk2hv2jni00dqyy27j4zqh86waw7i65ryvnmmc4fa9mc";
  };

  # Five files, split by detection vector (BESPOKE-PATCH-DESIGN.md §3.6).
  # Disjoint source sites — apply order is irrelevant; each file applies
  # and builds standalone (no cross-file symbols).
  antiDetectionPatches = [
    { name = "ad-rdtsc-timing";    patch = ./linux-6.18-ad-rdtsc-timing.patch; }
    { name = "ad-msr-tsc-read";    patch = ./linux-6.18-ad-msr-tsc-read.patch; }
    { name = "ad-cpuid-signature"; patch = ./linux-6.18-ad-cpuid-signature.patch; }
    { name = "ad-debug-trap-fix";  patch = ./linux-6.18-ad-debug-trap-fix.patch; }
    { name = "ad-hypercall-ud";    patch = ./linux-6.18-ad-hypercall-ud.patch; }
  ];
}
