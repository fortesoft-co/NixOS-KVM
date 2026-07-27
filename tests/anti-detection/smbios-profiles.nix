# Layer 1 test for the SMBIOS profile library + selection logic.
# Imports the REAL host/lib.nix functions (manufacturersForSocket,
# selectManufacturerForSocket, selectManufacturer) and the REAL
# smbios-profiles.nix data, then asserts coverage, selection correctness,
# fallback behavior, determinism, and profile well-formedness.
#
# Returns `true` on success, throws with a failure report on failure, so it
# can be wired as an eval-time flake check (see flake.nix checks output).
#
# Standalone run (for dev iteration):
#   nix-instantiate --eval --strict --arg lib '(import <nixpkgs> {}).lib' \
#     --arg pkgs '(import <nixpkgs> {}).legacyPackages.x86_64-linux' \
#     tests/anti-detection/smbios-profiles.nix
#
# Unlike cpu-socket.nix (which replicates the matching logic), this test
# imports the real lib.nix functions directly — no replication drift. The
# functions under test are pure (they take args, don't read config/pkgs), so
# the mock config below only needs to satisfy lib.nix's import shape; the
# cpuid_tool/proc/cpuinfo IFD bindings are lazy and never forced (explicit
# non-"auto" cpuVendor/cpuSocket values guarantee they wouldn't fire even if
# forced).
#
# This is the second module of the Layer 1 testing strategy in CONTEXT.md.
{ lib, pkgs }:
with lib;
let
  # Minimal mock config. Explicit (non-"auto") cpuVendor/cpuSocket so the IFD
  # bindings in lib.nix stay lazy / non-firing. The functions under test don't
  # read these, but lib.nix's `let` bindings reference them lazily.
  config = {
    cfg.kvm.host = {
      hwidSeed = "test-seed-1234";
      cpuVendor = "intel";
      cpuSocket = "LGA1700";
      antiDetection = { patchQemu = false; patchKernel = false; };
    };
  };
  hostLib = import ../../modules/kvm/host/lib.nix { inherit config lib pkgs; };
  inherit (hostLib) manufacturers selectManufacturer selectManufacturerForSocket manufacturersForSocket;
  smbiosProfiles = import ../../modules/kvm/host/smbios-profiles.nix;

  testSeed = "test-seed-1234";
  altSeeds = [ "seed-a" "seed-b" "seed-c" "seed-d" ];

  # Sockets that SHOULD have profiles (common modern hardware). If any of
  # these has no manufacturer, that's a real coverage gap worth surfacing.
  shouldHave = [
    { vendor = "amd";   socket = "AM4"; }
    { vendor = "amd";   socket = "AM5"; }
    { vendor = "amd";   socket = "sTR4"; }
    { vendor = "amd";   socket = "sTRX4"; }
    { vendor = "amd";   socket = "sTR5"; }
    { vendor = "amd";   socket = "sWRX8"; }
    { vendor = "amd";   socket = "SP3"; }
    { vendor = "amd";   socket = "SP5"; }
    { vendor = "intel"; socket = "LGA1151"; }
    { vendor = "intel"; socket = "LGA1200"; }
    { vendor = "intel"; socket = "LGA1700"; }
    { vendor = "intel"; socket = "LGA1851"; }
    { vendor = "intel"; socket = "LGA2011-3"; }
    { vendor = "intel"; socket = "LGA2066"; }
    { vendor = "intel"; socket = "LGA3647"; }
    { vendor = "intel"; socket = "LGA4677"; }
  ];

  # Sockets that should have NO profiles — intentional gaps where no vendor
  # ships a consumer board (see fallback-smbios.py intentional omissions).
  # The system must degrade gracefully: selectManufacturerForSocket falls back
  # to the unconstrained selectManufacturer. Locking these in as empty
  # catches a future sync that accidentally fabricates a board for them.
  shouldBeEmpty = [
    { vendor = "amd";   socket = "SP6"; }      # EPYC Siena — no vendor profile
    { vendor = "intel"; socket = "LGA4710"; }  # Granite Rapids — no vendor profile
  ];

  requiredFields = [ "manufacturer" "product" "version" "family" "socket" "chipset" "cpuVendor" "biosVersion" ];

  # ── Each check returns null (pass) or a string (failure detail) ──────────

  # 0. Structure: 4 manufacturers with the expected ids, and smbiosProfiles
  # has exactly those 4 top-level keys.
  checkStructure =
    if length manufacturers != 4
    then "expected 4 manufacturers, got ${toString (length manufacturers)}"
    else if sort (a: b: a < b) (map (m: m.id) manufacturers) != [ "asrock" "asus" "gigabyte" "msi" ]
    then "manufacturer ids mismatch: ${toString (map (m: m.id) manufacturers)}"
    else if sort (a: b: a < b) (attrNames smbiosProfiles) != [ "asrock" "asus" "gigabyte" "msi" ]
    then "smbiosProfiles top-level keys mismatch: ${toString (attrNames smbiosProfiles)}"
    else null;

  # 1+2. Coverage (shouldHave non-empty) + known gaps (shouldBeEmpty empty).
  checkCoverage =
    let
      missing = filter (c: length (manufacturersForSocket c.vendor c.socket) == 0) shouldHave;
      unexpectedlyFilled = filter (c: length (manufacturersForSocket c.vendor c.socket) != 0) shouldBeEmpty;
    in
    if missing != []
    then "coverage gaps (expected profiles): ${toString (map (c: "${c.vendor}/${c.socket}") missing)}"
    else if unexpectedlyFilled != []
    then "unexpected profiles for known-gap sockets: ${toString (map (c: "${c.vendor}/${c.socket}") unexpectedlyFilled)}"
    else null;

  # 3. Selection correctness: the pick is within the eligible set.
  checkSelection =
    let
      bad = flatten (map (c:
        let
          eligible = manufacturersForSocket c.vendor c.socket;
          pick = selectManufacturerForSocket testSeed c.vendor c.socket;
          eligibleIds = map (m: m.id) eligible;
        in
        if !elem pick.id eligibleIds
        then [ "${c.vendor}/${c.socket}: picked '${pick.id}' not in eligible ${toString eligibleIds}" ]
        else []
      ) shouldHave);
    in
    if bad != [] then "selection out-of-bounds:\n" + concatStringsSep "\n" (map (s: "  " + s) bad) else null;

  # 4. Fallback path: empty eligible → unconstrained selectManufacturer.
  checkFallback =
    let bad = filter (c:
      selectManufacturerForSocket testSeed c.vendor c.socket != selectManufacturer testSeed
    ) shouldBeEmpty;
    in
    if bad != []
    then "fallback path broken (expected selectManufacturer): ${toString (map (c: "${c.vendor}/${c.socket}") bad)}"
    else null;

  # 5. Seed distribution: across 4 seeds for a well-covered socket, the hash
  # mod should produce >=2 distinct picks (not a degenerate constant).
  checkDistribution =
    let
      picks = map (s: (selectManufacturerForSocket s "intel" "LGA1700").id) altSeeds;
      distinct = unique picks;
    in
    if length distinct < 2
    then "degenerate distribution for LGA1700 across ${toString altSeeds}: ${toString picks}"
    else null;

  # 6+7. Profile well-formedness + bucket consistency for the selected mfr of
  # each shouldHave case: profiles exist, required fields present, and the
  # socket/vendor/manufacturerId/manufacturer-string match the bucket.
  checkProfiles =
    let
      problems = flatten (map (c:
        let
          pick = selectManufacturerForSocket testSeed c.vendor c.socket;
          byMfr = smbiosProfiles.${pick.id} or {};
          byVendor = byMfr.${c.vendor} or {};
          profiles = byVendor.${c.socket} or [];
        in
        if profiles == []
        then [ "${c.vendor}/${c.socket}: selected mfr '${pick.id}' has no profiles" ]
        else flatten (imap0 (i: p:
          let
            missingFields = filter (f: !hasAttr f p) requiredFields;
            wrongSocket = if p.socket != c.socket then "socket='${p.socket}' (expected ${c.socket})" else null;
            wrongVendor = if p.cpuVendor != c.vendor then "cpuVendor='${p.cpuVendor}' (expected ${c.vendor})" else null;
            wrongMfrId = if p.manufacturerId != null && p.manufacturerId != pick.id then "manufacturerId='${p.manufacturerId}' (expected ${pick.id})" else null;
            wrongMfrStr = if p.manufacturer != pick.smbiosManufacturer then "manufacturer='${p.manufacturer}' (expected '${pick.smbiosManufacturer}')" else null;
            fieldProblems = filter (x: x != null) [ wrongSocket wrongVendor wrongMfrId wrongMfrStr ];
            idx = "[${toString i}]";
          in
          (if missingFields == [] then [] else [ "${c.vendor}/${c.socket}${idx}: missing fields ${toString missingFields}" ])
          ++ (if fieldProblems == [] then [] else [ "${c.vendor}/${c.socket}${idx}: ${toString fieldProblems}" ])
        ) profiles)
      ) shouldHave);
    in
    if problems != []
    then "profile data problems:\n" + concatStringsSep "\n" (map (s: "  " + s) problems)
    else null;

  allChecks = [
    { name = "structure";    detail = checkStructure; }
    { name = "coverage";     detail = checkCoverage; }
    { name = "selection";    detail = checkSelection; }
    { name = "fallback";     detail = checkFallback; }
    { name = "distribution"; detail = checkDistribution; }
    { name = "profiles";     detail = checkProfiles; }
  ];
  failures = filter (c: c.detail != null) allChecks;
in
  if failures == [] then true
  else throw (
    "smbios-profiles test: ${toString (length failures)}/${toString (length allChecks)} checks FAILED:\n"
    + concatStringsSep "\n" (map (c: "  [${c.name}] ${c.detail}") failures)
  )