# Layer 1 test for guests/lib.nix — MAC generation + effective SMBIOS branching.
# Imports the REAL guests/lib.nix (and thus host/lib.nix) and exercises:
#   - macFor: anti-detection on → manufacturer OUI; off → 52:54:00;
#     deterministic; explicit net.mac override; per-interface uniqueness.
#   - computeEffectiveSmbios: the manual / synthetic / off branching + field
#     mapping (extracted from generateXML so it's directly callable). Tested
#     with mock deps (serials/uuid/profileHash/profiles) so the branching is
#     asserted in isolation from profile selection and serial derivation.
#
# Returns `true` on success, throws with a failure report on failure.
#
# Standalone run:
#   nix-instantiate --eval --strict --arg lib '(import <nixpkgs> {}).lib' \
#     --arg pkgs '(import <nixpkgs> {}).legacyPackages.x86_64-linux' \
#     tests/anti-detection/guest-lib.nix
{ lib, pkgs }:
with lib;
let
  # Mock config. Explicit cpuVendor/cpuSocket (no IFD). macFor reads
  # cfg.guests.${name}, cfg.host.hwidSeed, and hostManufacturer.oui (which
  # resolves via cpuVendor/cpuSocket/hwidSeed — all explicit here, no IFD).
  config = {
    cfg.kvm = {
      host = {
        hwidSeed = "host-seed-1234";
        cpuVendor = "intel";
        cpuSocket = "LGA1700";
        antiDetection = { patchQemu = false; patchKernel = false; };
        storage = { persistentPath = null; };
      };
      guests = {
        adOn  = { hwidSalt = "salt-on";  antiDetection = { enable = true;  }; };
        adOff = { hwidSalt = "salt-off"; antiDetection = { enable = false; }; };
      };
    };
  };
  guestLib = import ../../modules/kvm/guests/lib.nix { inherit config lib pkgs; };
  inherit (guestLib) macFor computeEffectiveSmbios hexToInt;
  # hostManufacturer's OUI (lowercased) is what macFor uses when AD is on.
  hostLib = import ../../modules/kvm/host/lib.nix { inherit config lib pkgs; };
  expectedOui = lib.toLower hostLib.hostManufacturer.oui;

  # ── Mock deps for computeEffectiveSmbios ─────────────────────────────────
  mockSyntheticSerial = "SYNTHETIC-SERIAL-MOCK";
  mockDomainUuid = "mock-uuid-1234-5678";
  mockBaseboardSerial = "BASEBOARD-SERIAL-MOCK";
  # profileHash of all zeros → profileSlice "0000000" → hexToInt 0 → index 0.
  mockProfileHash = "0000000000000000000000000000000000000000000000000000000000000000";

  profileA = {
    manufacturerId = "asus";
    manufacturer = "ASUSTeK COMPUTER INC.";
    product = "ROG MAXIMUS Z790 HERO";
    version = "Rev 1.xx";
    family = "ASUSTeK System";
    socket = "LGA1700";
    chipset = "Z790";
    cpuVendor = "intel";
    biosVersion = "1001";
    biosDate = "12/07/2018";
    biosRelease = "5.13";
    systemManufacturer = "System manufacturer";
    systemProduct = "System Product Name";
    systemVersion = "System Version";
    systemFamily = "To be filled by O.E.M.";
    systemSku = "SKU";
    boardAsset = "--";
    boardLocation = "Default string";
    chassisManufacturer = "Default string";
    chassisVersion = "Default string";
    chassisSerial = "--";
    chassisAsset = "--";
    chassisSku = "Default string";
    oemStrings = [ "Default string" "Default string" ];
  };
  profileB = profileA // { product = "OTHER BOARD"; };
  mockProfiles = [ profileA profileB ];

  # ── Mock guests ──────────────────────────────────────────────────────────
  manualGuestNoSystem = {
    antiDetection = { enable = true; smbiosMode = "manual"; };
    smbios = {
      manufacturer = "ASUSTeK COMPUTER INC."; product = "ROG MAXIMUS Z790 HERO";
      version = "Rev 1.xx"; family = "ASUSTeK System"; sku = "SKU";
      biosVersion = "1001"; biosDate = "12/07/2018"; biosRelease = "5.13";
      systemManufacturer = null; systemProduct = null; systemVersion = null; systemFamily = null;
      boardAsset = "--"; boardLocation = "Default string";
      chassisManufacturer = null; chassisVersion = null; chassisAsset = null; chassisSku = null;
      oemStrings = null; serial = null;
    };
  };
  manualGuestWithSystemChassis = manualGuestNoSystem // {
    smbios = manualGuestNoSystem.smbios // {
      systemManufacturer = "Sys Mfr"; systemProduct = "Sys Product";
      systemVersion = "Sys Version"; systemFamily = "Sys Family";
      chassisManufacturer = "Chassis Mfr"; chassisVersion = "Chassis Ver";
      chassisAsset = "Chassis Asset"; chassisSku = "Chassis SKU";
      oemStrings = [ "OEM1" "OEM2" ];
    };
  };
  syntheticGuest = {
    antiDetection = { enable = true; smbiosMode = "synthetic"; };
    smbios = { manufacturer = null; product = null; version = null; family = null; sku = null;
               biosVersion = null; biosDate = null; biosRelease = null;
               systemManufacturer = null; systemProduct = null; systemVersion = null; systemFamily = null;
               boardAsset = null; boardLocation = null;
               chassisManufacturer = null; chassisVersion = null; chassisAsset = null; chassisSku = null;
               chassisSerial = null; oemStrings = null; serial = null; };
  };
  offGuest = {
    antiDetection = { enable = false; smbiosMode = "synthetic"; };
    smbios = {
      manufacturer = "Generic Co."; product = "Generic Board"; version = "v1";
      family = "Generic Family"; sku = "GENERIC-SKU"; serial = "REAL-SERIAL-XYZ";
      biosVersion = "2.0"; biosDate = "01/01/2020"; biosRelease = "1.0";
      systemManufacturer = null; systemProduct = null; systemVersion = null; systemFamily = null;
      boardAsset = null; boardLocation = null;
      chassisManufacturer = null; chassisVersion = null; chassisAsset = null; chassisSku = null;
      oemStrings = null;
    };
  };

  call = guest: computeEffectiveSmbios {
    inherit guest;
    syntheticSerial = mockSyntheticSerial;
    domainUuid = mockDomainUuid;
    baseboardSerial = mockBaseboardSerial;
    profileHash = mockProfileHash;
    smbiosProfiles = mockProfiles;
    inherit hexToInt;
  };

  # ── Each check returns null (pass) or a string (failure detail) ──────────

  checkMacFor =
    let
      macOn  = macFor "adOn"  { mac = null; } 0;
      macOff = macFor "adOff" { mac = null; } 0;
      macOn1 = macFor "adOn"  { mac = null; } 1;
      macExplicit = macFor "adOn" { mac = "aa:bb:cc:dd:ee:ff"; } 0;
      macOnRepeat = macFor "adOn" { mac = null; } 0;
      problems = filter (x: x != null) [
        (if hasPrefix expectedOui macOn then null else "adOn MAC '${macOn}' should start with OUI '${expectedOui}'")
        (if hasPrefix "52:54:00" macOff then null else "adOff MAC '${macOff}' should start with 52:54:00")
        (if macOn == macOnRepeat then null else "macFor not deterministic: '${macOn}' vs '${macOnRepeat}'")
        (if macOn != macOn1 then null else "macFor not unique per interface: i=0 and i=1 both '${macOn}'")
        (if macExplicit == "aa:bb:cc:dd:ee:ff" then null else "explicit net.mac override ignored: got '${macExplicit}'")
      ];
    in if problems != [] then "macFor problems:\n" + concatStringsSep "\n" (map (s: "  " + s) problems) else null;

  checkManualNoSystem =
    let s = call manualGuestNoSystem; g = manualGuestNoSystem.smbios;
        problems = filter (x: x != null) [
          (if s.systemManufacturer == g.manufacturer then null else "systemManufacturer: got '${toString s.systemManufacturer}', want fallback '${g.manufacturer}'")
          (if s.systemProduct == g.product then null else "systemProduct fallback wrong")
          (if s.systemSerial == mockSyntheticSerial then null else "systemSerial: got '${toString s.systemSerial}', want synthetic '${mockSyntheticSerial}'")
          (if s.systemUuid == mockDomainUuid then null else "systemUuid: got '${toString s.systemUuid}', want '${mockDomainUuid}'")
          (if s.boardSerial == mockBaseboardSerial then null else "boardSerial: got '${toString s.boardSerial}', want '${mockBaseboardSerial}'")
          (if s.chassisSerial == "" then null else "chassisSerial: got '${toString s.chassisSerial}', want '' (no chassis group)")
          (if s.oemStrings == null then null else "oemStrings: got '${toString s.oemStrings}', want null (no oem)")
          (if s.biosVendor == g.manufacturer then null else "biosVendor wrong")
        ];
    in if problems != [] then "manual (no system*):\n" + concatStringsSep "\n" (map (s2: "  " + s2) problems) else null;

  checkManualWithSystemChassis =
    let s = call manualGuestWithSystemChassis;
        problems = filter (x: x != null) [
          (if s.systemManufacturer == "Sys Mfr" then null else "systemManufacturer: got '${toString s.systemManufacturer}', want 'Sys Mfr'")
          (if s.systemProduct == "Sys Product" then null else "systemProduct wrong")
          (if s.chassisManufacturer == "Chassis Mfr" then null else "chassisManufacturer wrong")
          (if s.chassisSerial == "--" then null else "chassisSerial: got '${toString s.chassisSerial}', want '--' (chassis group active)")
          (if s.oemStrings == [ "OEM1" "OEM2" ] then null else "oemStrings: got '${toString s.oemStrings}', want [OEM1 OEM2]")
        ];
    in if problems != [] then "manual (with system*+chassis):\n" + concatStringsSep "\n" (map (s2: "  " + s2) problems) else null;

  checkSynthetic =
    let s = call syntheticGuest;
        problems = filter (x: x != null) [
          (if s.biosVendor == profileA.manufacturer then null else "biosVendor: got '${toString s.biosVendor}', want profileA.manufacturer")
          (if s.biosVersion == profileA.biosVersion then null else "biosVersion: got '${toString s.biosVersion}', want '${profileA.biosVersion}'")
          (if s.systemManufacturer == profileA.systemManufacturer then null else "systemManufacturer: got '${toString s.systemManufacturer}', want profileA value")
          (if s.systemProduct == profileA.systemProduct then null else "systemProduct: got '${toString s.systemProduct}', want profileA value")
          (if s.boardProduct == profileA.product then null else "boardProduct: got '${toString s.boardProduct}', want '${profileA.product}'")
          (if s.systemSerial == mockSyntheticSerial then null else "systemSerial: got '${toString s.systemSerial}', want synthetic")
          (if s.systemUuid == mockDomainUuid then null else "systemUuid: got '${toString s.systemUuid}', want '${mockDomainUuid}'")
          (if s.boardSerial == mockBaseboardSerial then null else "boardSerial: got '${toString s.boardSerial}', want baseboard")
          (if s.chassisSerial == profileA.chassisSerial then null else "chassisSerial: got '${toString s.chassisSerial}', want profile placeholder '${profileA.chassisSerial}' (NOT synthesized)")
          (if s.oemStrings == profileA.oemStrings then null else "oemStrings: got '${toString s.oemStrings}', want profile list")
        ];
    in if problems != [] then "synthetic:\n" + concatStringsSep "\n" (map (s2: "  " + s2) problems) else null;

  checkOff =
    let s = call offGuest; g = offGuest.smbios;
        problems = filter (x: x != null) [
          (if s.biosVersion == null then null else "biosVersion: got '${toString s.biosVersion}', want null (omitted when AD off)")
          (if s.systemUuid == null then null else "systemUuid: got '${toString s.systemUuid}', want null (domain <uuid> handles it)")
          (if s.systemManufacturer == g.manufacturer then null else "systemManufacturer: got '${toString s.systemManufacturer}', want g.manufacturer (Type 1 == Type 2)")
          (if s.boardManufacturer == g.manufacturer then null else "boardManufacturer wrong")
          (if s.systemManufacturer == s.boardManufacturer then null else "Type 1 != Type 2 when AD off: system='${toString s.systemManufacturer}' board='${toString s.boardManufacturer}'")
          (if s.systemSerial == g.serial then null else "systemSerial: got '${toString s.systemSerial}', want g.serial '${g.serial}' (NOT synthetic when AD off)")
          (if s.chassisManufacturer == "" then null else "chassisManufacturer: got '${toString s.chassisManufacturer}', want '' (no chassis when AD off)")
          (if s.oemStrings == [] then null else "oemStrings: got '${toString s.oemStrings}', want [] (no oem when AD off)")
        ];
    in if problems != [] then "off:\n" + concatStringsSep "\n" (map (s2: "  " + s2) problems) else null;

  allChecks = [
    { name = "macFor";                  detail = checkMacFor; }
    { name = "manualNoSystem";         detail = checkManualNoSystem; }
    { name = "manualWithSystemChassis"; detail = checkManualWithSystemChassis; }
    { name = "synthetic";              detail = checkSynthetic; }
    { name = "off";                    detail = checkOff; }
  ];
  failures = filter (c: c.detail != null) allChecks;
in
  if failures == [] then true
  else throw (
    "guest-lib test: ${toString (length failures)}/${toString (length allChecks)} checks FAILED:\n"
    + concatStringsSep "\n" (map (c: "  [${c.name}] ${c.detail}") failures)
  )