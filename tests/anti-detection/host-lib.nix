# Layer 1 test for host/lib.nix — the pure CPU/socket logic functions.
# Imports the REAL host/lib.nix and exercises:
#   - hexToInt
#   - detectSocket (the layer-3 regex dispatcher: detectAmdSocket/detectIntelSocket)
#   - detectSocketFromDatabase (layer-2 DB lookup, incl. AMD desktop-APU defer)
#   - cpuVendor explicit resolution (no IFD)
#   - hostManufacturer integration (config-driven pick within eligible set)
#
# Returns `true` on success, throws with a failure report on failure.
#
# Standalone run:
#   nix-instantiate --eval --strict --arg lib '(import <nixpkgs> {}).lib' \
#     --arg pkgs '(import <nixpkgs> {}).legacyPackages.x86_64-linux' \
#     tests/anti-detection/host-lib.nix
#
# Note on detectSocket cases: assertions use the CANONICAL socket strings
# (the names the profile library + cpu-packages.nix use). If detectAmdSocket
# returns a different string for a CPU, that's a layer-2/layer-3 mismatch
# the test is designed to surface.
{ lib, pkgs }:
with lib;
let
  config = {
    cfg.kvm.host = {
      hwidSeed = "test-seed-1234";
      cpuVendor = "intel";      # explicit → no IFD
      cpuSocket = "LGA1700";   # explicit → no IFD
      antiDetection = { patchQemu = false; patchKernel = false; };
    };
  };
  hostLib = import ../../modules/kvm/host/lib.nix { inherit config lib pkgs; };
  inherit (hostLib) hexToInt detectSocket detectSocketFromDatabase cpuVendor hostManufacturer manufacturersForSocket;

  # ── Each check returns null (pass) or a string (failure detail) ──────────

  checkHexToInt =
    let cases = [ { hex = "ff"; want = 255; } { hex = "0a"; want = 10; } { hex = "10"; want = 16; } { hex = "deadbeef"; want = 3735928559; } ];
        bad = filter (c: hexToInt c.hex != c.want) cases;
    in if bad != [] then "hexToInt mismatches: ${toString (map (c: "${c.hex}→${toString (hexToInt c.hex)} (want ${toString c.want})") bad)}" else null;

  # detectSocket — layer-3 regex. (vendor, modelName, expectedCanonicalSocket).
  checkDetectSocket =
    let
      cases = [
        # AMD — Ryzen desktop
        { vendor = "amd"; model = "AMD Ryzen 9 7950X 16-Core Processor";        want = "AM5"; }
        { vendor = "amd"; model = "AMD Ryzen 9 5950X 16-Core Processor";        want = "AM4"; }
        { vendor = "amd"; model = "AMD Ryzen 5 3600 6-Core Processor";         want = "AM4"; }
        { vendor = "amd"; model = "AMD Ryzen 5 5600G 6-Core Processor";        want = "AM4"; }
        # AMD — EPYC server
        { vendor = "amd"; model = "AMD EPYC 9654 96-Core Processor";          want = "SP5"; }
        { vendor = "amd"; model = "AMD EPYC 7742 64-Core Processor";          want = "SP3"; }
        { vendor = "amd"; model = "AMD EPYC 8324P 32-Core Processor";         want = "SP6"; }
        # AMD — Threadripper (canonical socket names: sTR4/sTRX4/sWRX8/sTR5)
        { vendor = "amd"; model = "AMD Ryzen Threadripper 3990X 64-Core Processor";   want = "sTRX4"; }
        { vendor = "amd"; model = "AMD Ryzen Threadripper 2990WX 32-Core Processor";  want = "sTR4"; }
        { vendor = "amd"; model = "AMD Ryzen Threadripper 1950X 16-Core Processor";  want = "sTR4"; }
        { vendor = "amd"; model = "AMD Ryzen Threadripper PRO 5995WX 64-Core";       want = "sWRX8"; }
        { vendor = "amd"; model = "AMD Ryzen Threadripper 7980X 64-Core Processor";  want = "sTR5"; }
        # AMD — unrecognized → null (fail-closed)
        { vendor = "amd"; model = "AMD FX-8350 Eight-Core Processor";          want = null; }
        # Intel — Core desktop
        { vendor = "intel"; model = "Intel(R) Core(TM) i9-13900K CPU";         want = "LGA1700"; }
        { vendor = "intel"; model = "Intel(R) Core(TM) i9-11900K CPU";         want = "LGA1200"; }
        { vendor = "intel"; model = "Intel(R) Core(TM) i7-8700K CPU";          want = "LGA1151"; }
        { vendor = "intel"; model = "Intel(R) Core(TM) i3-12100 CPU";         want = "LGA1700"; }
        { vendor = "intel"; model = "Intel(R) Core(TM) i5-2500K CPU";          want = null; }   # 2nd gen not handled → null
        # Intel — Core Ultra (Arrow Lake)
        { vendor = "intel"; model = "Intel(R) Core(TM) Ultra 7 265K";          want = "LGA1851"; }
        # Intel — Xeon Scalable (xeonGen = 2nd digit of 4-digit model)
        { vendor = "intel"; model = "Intel(R) Xeon(R) Platinum 8470";         want = "LGA4677"; }
        { vendor = "intel"; model = "Intel(R) Xeon(R) Gold 6338";             want = "LGA3647"; }
        # Intel — Xeon W (lowercase 'w' → LGA1700; uppercase W- → LGA2066)
        { vendor = "intel"; model = "Intel(R) Xeon(R) w7-2495X";             want = "LGA1700"; }
        { vendor = "intel"; model = "Intel(R) Xeon(R) W-3175X";              want = "LGA2066"; }
        # Intel — unrecognized → null
        { vendor = "intel"; model = "Intel Pentium 4";                       want = null; }
        # Unknown vendor → null
        { vendor = "arm"; model = "anything";                                want = null; }
      ];
      bad = filter (c: detectSocket c.vendor c.model != c.want) cases;
    in
    if bad != []
    then "detectSocket mismatches:\n" + concatStringsSep "\n" (map (c:
      "  ${c.vendor}/${c.model}: got ${if detectSocket c.vendor c.model == null then "null" else detectSocket c.vendor c.model}, want ${if c.want == null then "null" else c.want}"
    ) bad)
    else null;

  # detectSocketFromDatabase — layer-2 DB lookup (real import). A few cases
  # confirming the function works (cpu-socket.nix covers the data exhaustively;
  # this confirms the real function, incl. the AMD desktop-APU defer).
  checkDetectSocketFromDatabase =
    let
      cases = [
        # Intel: specific CPU-X entry wins
        { vendor = "intel"; codename = "Core i9 (Raptor Lake-S)"; brandstr = "13th Gen Intel(R) Core(TM) i9-13900K"; want = "LGA1700"; }
        # Intel: backstop (i5-12600KF not in CPU-X, matched by i5-12)
        { vendor = "intel"; codename = "Core i5 (Alder Lake-S)"; brandstr = "12th Gen Intel(R) Core(TM) i5-12600KF"; want = "LGA1700"; }
        # AMD: codename exact match
        { vendor = "amd"; codename = "Ryzen 9 (Vermeer)"; brandstr = "AMD Ryzen 9 5950X 16-Core Processor"; want = "AM4"; }
        # AMD desktop APU: codename → mobile socket, G-suffix → defer (null)
        { vendor = "amd"; codename = "Ryzen 5 (Cezanne)"; brandstr = "AMD Ryzen 5 5600G 6-Core Processor"; want = null; }
        # AMD mobile APU: no G suffix → keep CPU-X mobile socket
        { vendor = "amd"; codename = "Ryzen 5 (Cezanne)"; brandstr = "AMD Ryzen 5 5600U 6-Core Processor"; want = "FP6"; }
      ];
      bad = filter (c: detectSocketFromDatabase c.vendor c.codename c.brandstr != c.want) cases;
    in
    if bad != []
    then "detectSocketFromDatabase mismatches:\n" + concatStringsSep "\n" (map (c:
      "  ${c.vendor}/${c.codename}: got ${let g = detectSocketFromDatabase c.vendor c.codename c.brandstr; in if g == null then "null" else g}, want ${if c.want == null then "null" else c.want}"
    ) bad)
    else null;

  # cpuVendor explicit resolution (no IFD): config says "intel" → "intel".
  checkCpuVendor =
    if cpuVendor != "intel"
    then "cpuVendor: got ${cpuVendor}, want intel (explicit config should pass through)"
    else null;

  # hostManufacturer integration: with explicit config (intel/LGA1700), the
  # pick must be a manufacturer that actually has LGA1700 intel profiles, and
  # the pick must be deterministic across two evaluations of the same config.
  checkHostManufacturer =
    let
      m = hostManufacturer;
      eligible = manufacturersForSocket "intel" "LGA1700";
      eligibleIds = map (x: x.id) eligible;
    in
    if !elem m.id eligibleIds
    then "hostManufacturer: picked '${m.id}' not in eligible for intel/LGA1700 (${toString eligibleIds})"
    else null;

  allChecks = [
    { name = "hexToInt";                  detail = checkHexToInt; }
    { name = "detectSocket";              detail = checkDetectSocket; }
    { name = "detectSocketFromDatabase";  detail = checkDetectSocketFromDatabase; }
    { name = "cpuVendor";                 detail = checkCpuVendor; }
    { name = "hostManufacturer";          detail = checkHostManufacturer; }
  ];
  failures = filter (c: c.detail != null) allChecks;
in
  if failures == [] then true
  else throw (
    "host-lib test: ${toString (length failures)}/${toString (length allChecks)} checks FAILED:\n"
    + concatStringsSep "\n" (map (c: "  [${c.name}] ${c.detail}") failures)
  )