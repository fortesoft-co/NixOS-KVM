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
    let
      m = builtins.match ".*[^0-9]([0-9]{4,5})[^0-9].*" modelName;
      mEnd = builtins.match ".*[^0-9]([0-9]{4,5})$" modelName;
    in
    if m != null then builtins.elemAt m 0 else if mEnd != null then builtins.elemAt mEnd 0 else "";

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
      else null                                # unrecognized EPYC — fail, don't guess
    else if hasInfix "Threadripper" modelName then
      if firstDigit == "7" || firstDigit == "8" || firstDigit == "9" then "sTR5"  # 7000/8000/9000
      else if isPro then "sWRX8"                  # PRO 3xxx/5xxx (sWRX8 socket)
      else if firstDigit == "3" then "sTRX4"      # Threadripper 3000 (Castle Peak)
      else if firstDigit == "1" || firstDigit == "2" then "sTR4"  # Threadripper 1000/2000 (Whitehaven/Colfax)
      else null                                   # unrecognized Threadripper — fail, don't guess
    else if hasInfix "Ryzen" modelName then
      if firstDigit == "7" || firstDigit == "8" || firstDigit == "9" then "AM5"  # Zen 4+
      else "AM4"                                  # Zen 1/+/2/3 (1xxx-5xxx)
    else
      null;                                       # unrecognized AMD — fail, don't guess

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
      # Xeon W: distinguish old uppercase "W-NNNN" (LGA2066) from new lowercase
      # "wN-NNNN" (Sapphire Rapids-WS, LGA4677). The old isXeonW regex matched
      # both and returned LGA1700 for both, which was wrong on both counts.
      isXeonWOld = builtins.match ".*[W]-[0-9]+.*" modelName != null;
      isXeonWNew = builtins.match ".*[w][0-9]+-[0-9]+.*" modelName != null;
    in
    if hasInfix "Ultra" modelName then
      "LGA1851"                                   # Core Ultra (Arrow Lake)
    else if hasInfix "Xeon" modelName then
      if isXeonWOld then "LGA2066"                 # old Xeon W-2100..3175X (LGA2066)
      else if isXeonWNew then "LGA4677"             # new Xeon w-2xxx/3xxx (W790, LGA4677)
      else if xeonGen == "4" || xeonGen == "5" then "LGA4677"   # 4th/5th gen Scalable
      else if xeonGen == "6" then "LGA4710"             # 6th gen (Granite Rapids)
      else if xeonGen == "1" || xeonGen == "2" || xeonGen == "3" then "LGA3647"  # 1st-3rd gen
      else null                                   # unrecognized Xeon — fail, don't guess
    else if hasInfix "Core" modelName then
      if coreGenInt >= 12 && coreGenInt <= 14 then "LGA1700"   # 12th-14th gen
      else if coreGenInt == 10 || coreGenInt == 11 then "LGA1200"  # 10th-11th gen
      else if coreGenInt >= 6 && coreGenInt <= 9 then "LGA1151"  # 6th-9th gen
      else null                                   # unrecognized Core — fail, don't guess
    else
      null;                                       # unrecognized Intel — fail, don't guess

  # Pure dispatcher — takes a resolved vendor and a model name string.
  # Exported so it can be unit-tested without touching /proc/cpuinfo.
  # Returns null if the socket cannot be determined (no fallback guessing).
  detectSocket = vendor: modelName:
    if vendor == "amd" then detectAmdSocket modelName
    else if vendor == "intel" then detectIntelSocket modelName
    else null;

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
        result = if found != null then found.socket else null;
        # Desktop-APU disambiguation: Cezanne/Renoir/Picasso/Raven Ridge/Phoenix
        # codenames cover BOTH desktop G-suffix APUs (AM4/AM5) and mobile
        # U/H-suffix APUs (FP5/FP6/FP7/...). CPU-X maps these to the MOBILE
        # socket, so a desktop 5600G would wrongly get FP6. A 4-digit model
        # number followed by 'G' in the brand string (5600G, 8600G) is a
        # desktop APU. When the codename match returns a mobile socket AND the
        # brand string shows this pattern, return null so the resolver falls
        # through to layer 3 (detectAmdSocket), which has the Ryzen
        # generation → AM4/AM5 logic. Mobile CPUs (out of scope) keep CPU-X's
        # mobile socket unchanged.
        isMobileSocket = s: s != null && builtins.match "F[LPT][0-9].*" s != null;
        isDesktopApu = builtins.match ".*[0-9]{4}G.*" brandstr != null;
      in
      if result != null && isMobileSocket result && isDesktopApu then null else result
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
  # Layer 4: FAIL — build fails with a helpful message if all layers miss.
  #
  # Design principle: fail closed, not open. A wrong socket guess is worse than
  # no socket — it creates impossible hardware combinations (e.g., EPYC + AM4
  # motherboard) that fingerprinting tools detect. When detection fails, the
  # build fails and tells the user to set cfg.host.cpuSocket manually.
  #
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
        # Real OUI registered to ASUSTek Computer Inc. (IEEE OUI registry).
        # Board vendor OUI — kept for reference/validation.
        oui = "04:D9:F5";
      }
      {
        id = "msi";
        smbiosManufacturer = "Micro-Star International Co., Ltd.";
        patchToken = "MSIC";
        defaultProduct = "MS-7C37";
        realMachine = "MSI Real Machine";
        # Real OUI registered to Micro-Star International Co., Ltd.
        # Board vendor OUI (see ASUS entry for rationale).
        oui = "00:01:6C";
      }
      {
        id = "gigabyte";
        smbiosManufacturer = "Gigabyte Technology Co., Ltd.";
        patchToken = "GBTC";
        defaultProduct = "X570 AORUS ELITE";
        realMachine = "Gigabyte Real Machine";
        # Real OUI registered to Gigabyte Technology Co., Ltd.
        # Board vendor OUI (see ASUS entry for rationale).
        oui = "00:13:20";
      }
      {
        id = "asrock";
        smbiosManufacturer = "ASRock";
        patchToken = "ASRK";
        defaultProduct = "X570 Taichi";
        realMachine = "ASRock Real Machine";
        # Real OUI registered to ASRock Inc.
        # Board vendor OUI (see ASUS entry for rationale).
        oui = "00:13:74";
      }
    ];

  # NIC vendor OUI — used for MAC address generation when antiDetection is on.
  # The emulated NIC is always e1000e (Intel 82574L) when AD is on, so the MAC
  # uses Intel's OUI. On real hardware, the MAC is assigned by the NIC chip
  # vendor (Intel), so an ASUS board with an Intel NIC has an Intel OUI MAC +
  # ASUS SMBIOS.
  nicOui = "00:1B:21";  # Intel Corporation (IEEE OUI registry)

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

  # ───────── Socket-aware manufacturer selection ─────────
  # The curated profile library, imported here so manufacturer selection can be
  # constrained to vendors that actually ship a board for the host's socket.
  # (Plain attrset — lazily forced, so importing it is cheap; only the
  # vendor/socket paths we touch get evaluated.)
  smbiosProfiles = import ./smbios-profiles.nix;

  # Manufacturers that have at least one profile for (vendor, socket), in
  # registry order. The seed-based pick is constrained to this set so we never
  # choose a vendor with no matching profile — which would otherwise fall to
  # the weak fallbackProfile and emit a thin, socket-mismatched SMBIOS while
  # the QEMU patch and MAC OUI still used that vendor's strings.
  manufacturersForSocket = vendor: socket:
    let
      sock = if socket != null then socket else "unknown";
      profilesFor = m:
        let byVendor = smbiosProfiles.${m.id} or {};
        in (byVendor.${vendor} or {}).${sock} or [];
    in
    filter (m: (profilesFor m) != []) manufacturers;

  # Deterministically select a manufacturer that has profiles for the host's
  # (vendor, socket). Among the eligible vendors, the same sha256-mod formula
  # as selectManufacturer picks one — just over the smaller eligible set, so
  # the choice stays seed-stable and unbiased. If NO vendor has a profile for
  # the socket (e.g. SP6 / LGA4710, where none of the four ship boards), fall
  # back to the unconstrained seed-based pick; the guest then uses
  # fallbackProfile, and the user should pick a supported socket or use manual
  # mode.
  selectManufacturerForSocket = seed: vendor: socket:
    let
      eligible = manufacturersForSocket vendor socket;
    in
    if eligible == [] then
      selectManufacturer seed
    else
      let
        h = builtins.hashString "sha256" "${seed}-manufacturer";
        idx = lib.mod (hexToInt (substring 0 7 h)) (length eligible);
      in
      elemAt eligible idx;

  # The single host-level manufacturer used by the QEMU patch (host/libvirtd.nix)
  # and the SMBIOS profile selection (guests/lib.nix) — so the brand is consistent
  # across those surfaces. The MAC OUI is separate (nicOui, above). Socket-aware:
  # constrained to vendors with a profile for the host's socket.
  #
  # NOTE: this forces cpuVendor/cpuSocket. When cpuSocket = "auto" it runs
  # cpuid_tool during eval, which reads the BUILD machine's CPU — so for
  # remote/cross builds you should set cfg.kvm.host.cpuSocket explicitly (the
  # same requirement already applies to guest profile selection).
  hostManufacturer = selectManufacturerForSocket cfg.host.hwidSeed cpuVendor cpuSocket;
in
{
  inherit hexToInt cpuVendor cpuSocket detectSocket detectSocketFromDatabase manufacturers selectManufacturer selectManufacturerForSocket manufacturersForSocket hostManufacturer nicOui;
}