{ config, lib, pkgs }:
with lib;
let
  cfg = config.cfg.kvm;

  # ───────── Hex helper ─────────
  # Converts a hexadecimal string slice (up to ~14 chars max) to a Base-10 Integer.
  # Pure utility shared by host-level selection (manufacturer index) and guest-level
  # derivation (UUID variant nibble, serial bytes, profile index). Defined here so
  # both host/*.nix and guests/lib.nix (which imports this file) share one implementation.
  hexToInt = hex:
    let
      hexMap = {
        "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4; "5" = 5; "6" = 6; "7" = 7;
        "8" = 8; "9" = 9; "a" = 10; "b" = 11; "c" = 12; "d" = 13; "e" = 14; "f" = 15;
      };
      chars = stringToCharacters (toLower hex);
      folder = acc: char: (acc * 16) + hexMap.${char};
    in
    foldl' folder 0 chars;

  # ───────── CPU vendor detection ─────────
  # Resolves "auto" to "intel" or "amd" from boot.kernelModules,
  # falling back to /proc/cpuinfo probing.
  cpuVendor =
    let
      v = cfg.host.cpuVendor;
    in
    if v != "auto" then
      v
    else if builtins.elem "kvm-intel" config.boot.kernelModules then
      "intel"
    else if builtins.elem "kvm-amd" config.boot.kernelModules then
      "amd"
    else
      builtins.readFile (
        pkgs.runCommand "cpu-vendor.txt" { } ''
          ((cat /proc/cpuinfo | grep vendor | head -n 1 | grep -i intel > /dev/null 2>&1) \
            && echo -n 'intel' || echo -n 'amd') > $out
        ''
      );

  # ───────── CPU socket auto-detection ─────────
  # Parses the CPU model name from /proc/cpuinfo and maps it to a socket family.
  # This is a heuristic — /proc/cpuinfo doesn't expose the socket directly, so we
  # pattern-match known CPU model naming conventions.
  #
  # Used by step 5 (profile filtering) to ensure the selected motherboard profile
  # matches the host CPU's socket. An EPYC on an AM4 board, or a Threadripper on
  # an LGA1700 board, is an impossible hardware combination that fingerprinting
  # tools cross-reference and flag.
  #
  # Coverage (consumer + workstation):
  #   AMD:  AM4, AM5, sTRX4, WRX80, sTR5, SP3, SP5, SP6
  #   Intel: LGA1151, LGA1200, LGA1700, LGA1851, LGA3647, LGA4677
  #
  # Fallback: latest consumer socket for the detected vendor when the model
  # isn't recognized. Users with unrecognized CPUs can override via
  # cfg.kvm.host.cpuSocket (set to a specific socket string).

  # Extract the first 4-5 digit model number from a CPU model name string.
  # e.g. "AMD Ryzen 9 7950X 16-Core Processor" → "7950"
  #      "Intel(R) Core(TM) i9-14900K"        → "14900"
  extractModelNum = modelName:
    let m = builtins.match ".*[^0-9]([0-9]{4,5})[^0-9].*" modelName;
    in if m != null then builtins.elemAt m 0 else "";

  # Decimal string → integer (builtins.fromJSON parses bare JSON numbers).
  toInt10 = s: builtins.fromJSON s;

  detectAmdSocket = modelName:
    let
      modelNum = extractModelNum modelName;
      firstDigit = if modelNum != "" then builtins.substring 0 1 modelNum else "";
      isPro = hasInfix "PRO" modelName;
    in
    if hasInfix "EPYC" modelName then
      if firstDigit == "9" then "SP5"          # Genoa/Bergamo/Turin (9004/9005)
      else if firstDigit == "8" then "SP6"      # Siena (8004)
      else if firstDigit == "7" then "SP3"      # Naples/Rome/Milan (7001-7003)
      else "SP5"                                 # fallback for unrecognized EPYC
    else if hasInfix "Threadripper" modelName then
      if firstDigit == "7" || firstDigit == "8" || firstDigit == "9" then "sTR5"  # 7000+
      else if isPro then "WRX80"                  # PRO 3xxx/5xxx (WRX80; non-PRO is sTRX4)
      else "sTRX4"                                # non-PRO 3xxx/5xxx or unknown
    else if hasInfix "Ryzen" modelName then
      if firstDigit == "7" || firstDigit == "8" || firstDigit == "9" then "AM5"  # Zen 4+
      else "AM4"                                  # Zen 1/+/2/3 (1xxx-5xxx)
    else
      "AM5";                                     # generic AMD fallback (latest consumer)

  detectIntelSocket = modelName:
    let
      modelNum = extractModelNum modelName;
      # Core iX-NNNNN: extract the number after "iN-" and take 1-2 leading digits as gen.
      #   i9-14900K → "14900" (5 chars) → gen "14"
      #   i7-7700K  → "7700"  (4 chars) → gen "7"
      coreGenMatch = builtins.match ".*i[3579]-([0-9]+).*" modelName;
      coreGenStr = if coreGenMatch != null then builtins.elemAt coreGenMatch 0 else "";
      coreGen = if builtins.stringLength coreGenStr >= 5 then builtins.substring 0 2 coreGenStr
                else if coreGenStr != "" then builtins.substring 0 1 coreGenStr
                else "";
      coreGenInt = if coreGen != "" then toInt10 coreGen else 0;
      # Xeon Scalable: 2nd digit of 4-digit model number is the generation.
      #   Platinum 8470 → "8470" → gen "4" (4th gen)
      #   Gold 6338      → "6338" → gen "3" (3rd gen)
      xeonGen = if builtins.stringLength modelNum >= 2 then builtins.substring 1 1 modelNum else "";
      # Xeon W: matches both old "W-NNNN" and new "wN-NNNN" naming conventions.
      isXeonW = builtins.match ".*[Ww][0-9]*-[0-9]+.*" modelName != null;
    in
    if hasInfix "Ultra" modelName then
      "LGA1851"                                   # Core Ultra (Arrow Lake)
    else if hasInfix "Xeon" modelName then
      if isXeonW then "LGA1700"                    # Xeon W-2xxx/3xxx (W790)
      else if xeonGen == "4" || xeonGen == "5" then "LGA4677"   # 4th/5th gen Scalable
      else if xeonGen == "6" then "LGA4710"             # 6th gen (Granite Rapids)
      else if xeonGen == "1" || xeonGen == "2" || xeonGen == "3" then "LGA3647"  # 1st-3rd gen
      else "LGA4677"                               # fallback for unrecognized Xeon
    else if hasInfix "Core" modelName then
      if coreGenInt >= 12 && coreGenInt <= 14 then "LGA1700"   # 12th-14th gen
      else if coreGenInt == 10 || coreGenInt == 11 then "LGA1200"  # 10th-11th gen
      else if coreGenInt >= 6 && coreGenInt <= 9 then "LGA1151"  # 6th-9th gen
      else "LGA1700"                               # fallback
    else
      "LGA1851";                                   # generic Intel fallback (latest consumer)

  # Pure dispatcher — takes a resolved vendor and a model name string.
  # Exported so it can be unit-tested without touching /proc/cpuinfo.
  detectSocket = vendor: modelName:
    if vendor == "amd" then detectAmdSocket modelName
    else if vendor == "intel" then detectIntelSocket modelName
    else "unknown";

  # ───────── CPU socket detection: layer 2 (libcpuid + CPU-X databases.h) ───
  # Uses libcpuid's `cpuid_tool` to identify the CPU codename from the CPUID
  # instruction (sandbox-safe, no /sys or root needed), then looks up the
  # codename/brand in our Nix translation of CPU-X's `databases.h` to find the
  # socket. Falls through to the regex heuristic (layer 3) if no match.

  # The translated CPU-X codename→socket database.
  cpuPackages = import ./cpu-packages.nix { inherit lib; };

  # Run cpuid_tool --codename in the Nix sandbox (CPUID instruction, no /sys).
  # Returns the libcpuid codename, e.g. "Core i9 (Raptor Lake-S)" or "Ryzen 9 (Raphael)".
  cpuidCodename = builtins.readFile (pkgs.runCommand "cpuid-codename.txt" {
    nativeBuildInputs = [ pkgs.libcpuid ];
  } ''
    ${pkgs.libcpuid}/bin/cpuid_tool --codename --quiet 2>/dev/null | head -n 1 | tr -d '\n' > $out
  '');

  # Run cpuid_tool --brandstr in the Nix sandbox.
  # Returns the CPU brand string, e.g. "13th Gen Intel(R) Core(TM) i9-13900KS".
  cpuidBrandstr = builtins.readFile (pkgs.runCommand "cpuid-brandstr.txt" {
    nativeBuildInputs = [ pkgs.libcpuid ];
  } ''
    ${pkgs.libcpuid}/bin/cpuid_tool --brandstr --quiet 2>/dev/null | head -n 1 | tr -d '\n' > $out
  '');

  # Strip trailing uppercase letters after the last digit (suffixes like K, KS, KF, F, T, H).
  # "Intel(R) Core(TM) i9-13900KS" → "Intel(R) Core(TM) i9-13900"
  # "Intel(R) Xeon(R) Platinum 84" → "Intel(R) Xeon(R) Platinum 84" (no trailing letters)
  stripSuffix = s:
    let m = builtins.match "^(.*[0-9])[A-Z]*$" s;
    in if m != null then builtins.elemAt m 0 else s;

  # Extract the codename from the parenthesized form "Ryzen 9 (Raphael)" → "Raphael".
  extractCodename = s:
    let m = builtins.match ".*[(]([^)]+)[)].*" s;
    in if m != null then builtins.elemAt m 0 else s;

  # Strip the "Nth Gen " prefix from Intel brand strings.
  # "13th Gen Intel(R) Core(TM) i9-13900KS" → "Intel(R) Core(TM) i9-13900KS"
  stripGenPrefix = s:
    let m = builtins.match "^[0-9]+th Gen (.*)" s;
    in if m != null then builtins.elemAt m 0 else s;

  # Look up the socket from the translated CPU-X database.
  # AMD: extract codename from parens, exact-match against packageAmd[].codename.
  # Intel: strip "Nth Gen" prefix + suffix letters, prefix-match against packageIntel[].model.
  # Returns the socket string, or null if no match.
  detectSocketFromDatabase = vendor: codename: brandstr:
    if vendor == "amd" then
      let
        cn = extractCodename codename;
        found = findFirst (e: e.codename != null && e.codename == cn) null cpuPackages.packageAmd;
      in
      if found != null then found.socket else null
    else if vendor == "intel" then
      let
        stripped = stripSuffix (stripGenPrefix brandstr);
        found = findFirst (e:
          e.model != null && hasPrefix (stripSuffix e.model) stripped
        ) null cpuPackages.packageIntel;
      in
      if found != null then found.socket else null
    else
      null;

  # ───────── CPU socket auto-detection: resolver ─────────
  # Layer 1: user override (cfg.host.cpuSocket)
  # Layer 2: libcpuid codename → CPU-X databases.h lookup (sandbox-safe, ~98%)
  # Layer 3: /proc/cpuinfo brand → regex heuristic (~85%)
  # Layer 4: vendor-specific fallback (AM5 / LGA1851)
  # Lazily evaluated — the IFDs only trigger when a caller actually reads this.
  cpuSocket =
    let
      v = cfg.host.cpuSocket;
      vendor = if cfg.host.cpuVendor != "auto" then cfg.host.cpuVendor else cpuVendor;
    in
    if v != "auto" then
      v
    else
      let dbResult = detectSocketFromDatabase vendor cpuidCodename cpuidBrandstr; in
      if dbResult != null then
        dbResult
      else
        detectSocket vendor (builtins.readFile (pkgs.runCommand "cpu-model.txt" { } ''
          awk -F': ' '/^model name/ {printf "%s", $2; exit}' /proc/cpuinfo > $out
        ''));

  # ───────── Manufacturer registry ─────────
  # The set of consumer motherboard manufacturers eligible for seed-based
  # selection. Constraint (see CONTEXT.md): only manufacturers that produce
  # BOTH AMD and Intel consumer motherboards qualify, so the seed's choice
  # works regardless of the host's CPU vendor.
  #
  # Each record carries the strings consumed by later steps:
  #   - smbiosManufacturer: full SMBIOS manufacturer string (step 5 profile filter)
  #   - patchToken: 4-char token for QEMU source patches — ACPI HID "XXXX0002"
  #     and per-device strings like "ASUS Keyboard" (step 7 dynamic sed)
  #   - defaultProduct: legacy QEMU x86 fallback product (step 7)
  #   - realMachine: replaces "QEMU Virtual Machine" / "KVM Virtual Machine"
  #     in QEMU source (step 7)
  manufacturers = [
    {
      id = "asus";
      smbiosManufacturer = "ASUSTeK COMPUTER INC.";
      patchToken = "ASUS";
      defaultProduct = "M4A88TD-M";
      realMachine = "ASUS Real Machine";
    }
    {
      id = "msi";
      smbiosManufacturer = "Micro-Star International Co., Ltd.";
      patchToken = "MSIC";
      defaultProduct = "MS-7C37";
      realMachine = "MSI Real Machine";
    }
    {
      id = "gigabyte";
      smbiosManufacturer = "Gigabyte Technology Co., Ltd.";
      patchToken = "GBTC";
      defaultProduct = "X570 AORUS ELITE";
      realMachine = "Gigabyte Real Machine";
    }
    {
      id = "asrock";
      smbiosManufacturer = "ASRock";
      patchToken = "ASRK";
      defaultProduct = "X570 Taichi";
      realMachine = "ASRock Real Machine";
    }
  ];

  # Deterministically select one manufacturer for the entire host.
  #
  # Why host-level: QEMU is a host-level binary shared across all guests, so
  # the patched strings (keyboard names, ACPI OEM, drive models) must match
  # the SMBIOS manufacturer — and SMBIOS filtering (step 5) must use the same
  # brand for every guest on a host to keep the QEMU↔SMBIOS story consistent.
  #
  # Why seed-based: different installations get different brands based on
  # their hwidSeed, avoiding a "NixOS-KVM always picks ASUS" signature that
  # could be blocklisted. A physical PC has one motherboard brand — a virtual
  # host should too.
  #
  # Formula: sha256(seed + "-manufacturer")[0:7] mod N
  # The 7-char hex slice gives 0x0000000..0xFFFFFFF (16^7 ≈ 268M values),
  # plenty for unbiased mod-4 distribution.
  selectManufacturer = seed:
    let
      h = builtins.hashString "sha256" "${seed}-manufacturer";
      idx = lib.mod (hexToInt (substring 0 7 h)) (length manufacturers);
    in
    elemAt manufacturers idx;
in
{
  inherit hexToInt cpuVendor cpuSocket detectSocket detectSocketFromDatabase manufacturers selectManufacturer;
}