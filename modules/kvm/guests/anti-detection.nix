# Anti-detection: SMBIOS profile selection, serial generation, SMBIOS
# computation, and SMBIOS XML assembly for guests.
#
# Separated from guests/lib.nix so the general XML generation code stays clean.
# This module is imported by guests/lib.nix (generateXML calls its functions
# when antiDetection.enable is true) and by tests/anti-detection/guest-lib.nix
# (which exercises computeEffectiveSmbios directly with mock deps).
#
# Depends on host/lib.nix (hexToInt, cpuVendor, cpuSocket) and
# host/anti-detection.nix (hostManufacturer, nicOui, smbiosProfiles).
{ config, lib, pkgs }:
with lib;
let
  cfg = config.cfg.kvm;
  hostLib = import ../host/lib.nix { inherit config lib pkgs; };
  hostAd = import ../host/anti-detection.nix { inherit config lib pkgs; };
  inherit (hostLib) cpuVendor cpuSocket hexToInt;
  inherit (hostAd) hostManufacturer nicOui;

  # ───────── Motherboard Profile Selection ─────────
  allProfiles = import ../host/smbios-profiles.nix;

  fallbackProfile = {
    manufacturerId = hostManufacturer.id;
    manufacturer = hostManufacturer.smbiosManufacturer;
    product = hostManufacturer.defaultProduct;
    version = "1.0";
    family = "Default System";
    socket = if cpuSocket != null then cpuSocket else "Unknown";
    chipset = "Unknown";
    cpuVendor = cpuVendor;
    biosVersion = "1.0.0";
  };

  validProfiles =
    let
      sock = if cpuSocket != null then cpuSocket else "unknown";
      m = allProfiles.${hostManufacturer.id} or { };
      v = m.${cpuVendor} or { };
      s = v.${sock} or [ ];
    in
    s;

  # If we successfully parsed matching profiles from the database, use them.
  # Otherwise, fall back to the safe defaults from the manufacturer struct.
  smbiosProfiles = if length validProfiles > 0 then validProfiles else [ fallbackProfile ];

  # ───────── Serial generation ─────────
  # Generates the synthetic serials + profile hash from the guest's
  # hwidSeed + hwidSalt. Called by generateXML (guests/lib.nix) which passes
  # the results to computeEffectiveSmbios.
  generateSerials = { seedPrefix, hwidSalt }:
    let
      serialHash = builtins.hashString "sha256" "${seedPrefix}-${hwidSalt}-serial";
      baseSerialHash = builtins.hashString "sha256" "${seedPrefix}-${hwidSalt}-base-serial";
      profileHash = builtins.hashString "sha256" "${seedPrefix}-${hwidSalt}-profile";
      # Full-alphanumeric serial (A-Z, 0-9) like real motherboards, not hex-only.
      alnumChars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
      serialFromHash =
        h:
        let bAt = i: hexToInt (substring (i * 2) 2 h);
        in concatStrings (genList (i: substring (lib.mod (bAt i) 36) 1 alnumChars) 14);
    in {
      syntheticSerial = serialFromHash serialHash;     # Type 1 (System)
      baseboardSerial = serialFromHash baseSerialHash;   # Type 2 (Baseboard)
      inherit profileHash;
    };

  # ───────── SMBIOS computation ─────────
  # Compute the effective SMBIOS values for a guest: manual / synthetic / off
  # branching + per-type field mapping. Extracted from generateXML so it's
  # directly testable (tests/anti-detection/guest-lib.nix exercises it with
  # mock deps). generateXML calls this with the real computed serials/uuid/
  # profileHash and the host-filtered smbiosProfiles. Taking the deps as args
  # (rather than reading module-level bindings) lets the test control all
  # inputs and assert the branching in isolation from profile selection.
  computeEffectiveSmbios =
    { guest, syntheticSerial, domainUuid, baseboardSerial, profileHash, smbiosProfiles, hexToInt }:
    if guest.antiDetection.enable then
      if guest.antiDetection.smbiosMode == "manual" then
        # MANUAL MODE: Use the user-provided hardware strings from smbios.*.
        # Serial and UUID are always synthetic (never leaked from the host).
        # Type 1 (system*) fields fall back to the Type 2 (baseboard) values
        # when not provided. Type 3 (chassis*) and Type 11 (oemStrings) are only
        # emitted when the user provides them (all-or-nothing per group,
        # enforced by assertions). The chassis serial is always "--" (real
        # desktop boards almost universally emit that placeholder).
        let
          g = guest.smbios;
          sysMfr = if g.systemManufacturer != null then g.systemManufacturer else g.manufacturer;
          sysProd = if g.systemProduct != null then g.systemProduct else g.product;
          sysVer = if g.systemVersion != null then g.systemVersion else g.version;
          sysFam = if g.systemFamily != null then g.systemFamily else g.family;
          hasChassis = g.chassisManufacturer != null;
        in
        {
          biosVendor = g.manufacturer;
          biosVersion = g.biosVersion;
          biosDate = g.biosDate;
          biosRelease = g.biosRelease;
          systemManufacturer = sysMfr;
          systemProduct = sysProd;
          systemVersion = sysVer;
          systemSerial = syntheticSerial;
          systemUuid = domainUuid;
          systemSku = g.sku;
          systemFamily = sysFam;
          boardManufacturer = g.manufacturer;
          boardProduct = g.product;
          boardVersion = g.version;
          boardSerial = baseboardSerial;
          boardAsset = g.boardAsset;
          boardLocation = g.boardLocation;
          chassisManufacturer = g.chassisManufacturer;
          chassisVersion = g.chassisVersion;
          chassisSerial = if hasChassis then "--" else "";
          chassisAsset = g.chassisAsset;
          chassisSku = g.chassisSku;
          oemStrings = g.oemStrings;
        }
      else
        # SYNTHETIC MODE (default): Procedurally select a motherboard profile
        # from the curated database. User smbios overrides are ignored
        # (enforced by assertions — they can't even be set in this mode),
        # except `sku` which carries no profiling risk.
        let
          profileSlice = substring 0 7 profileHash;
          profileIndex = lib.mod (hexToInt profileSlice) (length smbiosProfiles);
          p = elemAt smbiosProfiles profileIndex;
          f = name: p.${name} or "";
        in
        {
          biosVendor = p.manufacturer;
          biosVersion = p.biosVersion;
          biosDate = f "biosDate";
          biosRelease = f "biosRelease";
          systemManufacturer = f "systemManufacturer";
          systemProduct = f "systemProduct";
          systemVersion = f "systemVersion";
          systemSerial = syntheticSerial;
          systemUuid = domainUuid;
          systemSku = f "systemSku";
          systemFamily = f "systemFamily";
          boardManufacturer = p.manufacturer;
          boardProduct = p.product;
          boardVersion = p.version;
          boardSerial = baseboardSerial;
          boardAsset = f "boardAsset";
          boardLocation = f "boardLocation";
          chassisManufacturer = f "chassisManufacturer";
          chassisVersion = f "chassisVersion";
          chassisSerial = f "chassisSerial";
          chassisAsset = f "chassisAsset";
          chassisSku = f "chassisSku";
          oemStrings = p.oemStrings or [ ];
        }
    else
      # antiDetection OFF — flat guest.smbios, no Type 3/11, Type 1 == Type 2.
      # biosVersion null so the <bios> version entry is omitted; the domain
      # <uuid> tag handles the SMBIOS UUID, so systemUuid is null here.
      let
        g = guest.smbios;
      in
      {
        biosVendor = g.manufacturer;
        biosVersion = null;
        biosDate = "";
        biosRelease = "";
        systemManufacturer = g.manufacturer;
        systemProduct = g.product;
        systemVersion = g.version;
        systemSerial = g.serial;
        systemUuid = null;
        systemSku = g.sku;
        systemFamily = g.family;
        boardManufacturer = g.manufacturer;
        boardProduct = g.product;
        boardVersion = g.version;
        boardSerial = g.serial;
        boardAsset = "";
        boardLocation = "";
        chassisManufacturer = "";
        chassisVersion = "";
        chassisSerial = "";
        chassisAsset = "";
        chassisSku = "";
        oemStrings = [ ];
      };

  # ───────── SMBIOS XML assembly ─────────
  # Builds the <sysinfo type='smbios'> XML block from the effective SMBIOS
  # values. Returns "" if the system block is empty (AD off or no entries),
  # so generateXML can use it as a gating condition for smbiosOsEntry.
  buildSmbiosXML = effectiveSmbios:
    let
      smbiosEntry = name: val:
        if val == null || val == "" then "" else "<entry name='${name}'>${val}</entry>";

      biosEntries = filter (s: s != "") [
        (smbiosEntry "vendor" effectiveSmbios.biosVendor)
        (smbiosEntry "version" effectiveSmbios.biosVersion)
        (smbiosEntry "date" effectiveSmbios.biosDate)
        (smbiosEntry "release" effectiveSmbios.biosRelease)
      ];
      systemEntries = filter (s: s != "") [
        (smbiosEntry "manufacturer" effectiveSmbios.systemManufacturer)
        (smbiosEntry "product" effectiveSmbios.systemProduct)
        (smbiosEntry "version" effectiveSmbios.systemVersion)
        (smbiosEntry "serial" effectiveSmbios.systemSerial)
        (smbiosEntry "uuid" effectiveSmbios.systemUuid)
        (smbiosEntry "sku" effectiveSmbios.systemSku)
        (smbiosEntry "family" effectiveSmbios.systemFamily)
      ];
      baseBoardEntries = filter (s: s != "") [
        (smbiosEntry "manufacturer" effectiveSmbios.boardManufacturer)
        (smbiosEntry "product" effectiveSmbios.boardProduct)
        (smbiosEntry "version" effectiveSmbios.boardVersion)
        (smbiosEntry "serial" effectiveSmbios.boardSerial)
        (smbiosEntry "asset" effectiveSmbios.boardAsset)
        (smbiosEntry "location" effectiveSmbios.boardLocation)
      ];
      chassisEntries = filter (s: s != "") [
        (smbiosEntry "manufacturer" effectiveSmbios.chassisManufacturer)
        (smbiosEntry "version" effectiveSmbios.chassisVersion)
        (smbiosEntry "serial" effectiveSmbios.chassisSerial)
        (smbiosEntry "asset" effectiveSmbios.chassisAsset)
        (smbiosEntry "sku" effectiveSmbios.chassisSku)
      ];
      oemStringEntries = map (s: "<entry>${s}</entry>") effectiveSmbios.oemStrings;

      smbiosBlock = tag: entries:
        if entries == [ ] then ""
        else "          <${tag}>\n            ${concatStrings entries}\n          </${tag}>";
    in
    optionalString (systemEntries != [ ]) (
      concatStringsSep "\n" (
        filter (s: s != "") [
          "        <sysinfo type='smbios'>"
          (smbiosBlock "bios" biosEntries)
          (smbiosBlock "system" systemEntries)
          (smbiosBlock "baseBoard" baseBoardEntries)
          (smbiosBlock "chassis" chassisEntries)
          (smbiosBlock "oemStrings" oemStringEntries)
          "        </sysinfo>"
        ]
      )
    );
in
{
  inherit
    computeEffectiveSmbios
    smbiosProfiles
    hostManufacturer
    nicOui
    hexToInt
    generateSerials
    buildSmbiosXML
    ;
}