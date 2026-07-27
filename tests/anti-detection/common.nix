# Shared fixture + expected-value machinery for the anti-detection boot tests.
#
# Both `guest-smbios.nix` (Option A — libvirt-argv surfacing, no guest boot) and
# `guest-smbios-boot.nix` (Option B — actual guest-OS boot + dmidecode) need the
# SAME deterministic expected values derived from the same fixture inputs
# (hwidSeed / hwidSalt / cpuVendor / cpuSocket) via the module's own libs. Keeping
# them in one place means a change to the hash format, profile lookup, or
# effective-SMBIOS computation updates both tests in lockstep — no drift risk.
#
# This file is pure (no IFD, no host hardware): every value derives from the
# explicit fixture inputs below. It exposes:
#   - the base guest attrset (Option B merges in a real disk)
#   - the module libs (generateXML, computeEffectiveSmbios, macFor, hexToInt,
#     hostManufacturer) so each test builds its own generatedXML if it customizes
#     the guest
#   - the computed expected values (smb, domainUuid, syntheticSerial,
#     baseboardSerial, expectedMac, hvVendorId) that both probes diff against
#
# `mockConfigFor` lets a test build the raw mock config (no NixOS option
# submodule, no assertions) for a guest attrset — used to import the module libs
# without triggering the "cpuVendor must be auto when AD on" assertion.
{ lib, pkgs }:
with lib;
let
  # ── Fixture inputs (machine-independent: explicit, no IFD) ────────────────
  # hwidSeed must be a valid UUID (the module asserts that format for any
  # enabled guest); using one here keeps the fixture representative.
  hwidSeed  = "12345678-1234-4321-abcd-123456789abc";
  hwidSalt  = "adon-salt-0001";
  cpuVendor = "intel";
  cpuSocket = "LGA1700";

  # Base AD-on synthetic guest. Every field is provided so the mock config fed
  # to generateXML doesn't rely on option submodule defaults (same shape as
  # tests/guest/xml.nix's baseGuest + adOn delta). disks = [] here; Option B
  # merges in a real qcow2 disk via `// { disks = [...]; }` before calling
  # generateXML. The SMBIOS/NIC/CPU expected values do NOT depend on the disk
  # field, so they stay valid for both tests.
  baseGuest = {
    enable = true;
    domainName = "adon";
    inherit hwidSalt;
    memory = 2048;
    vcpus = 2;
    architecture = "x86_64";
    machineType = "q35";
    firmware = "bios";
    secureBoot = false;
    storagePath = null;
    cpu = { sockets = null; cores = null; threads = null; mode = "host-model"; reportedModel = null; flags = []; hidden = false; };
    disks = [];
    cloudInit = { enable = false; };
    networks = [ { type = "bridge"; source = "br0"; model = "virtio"; mac = null; } ];
    passthrough = { pci = []; usb = []; };
    tpm = { enable = false; model = "tpm-crb"; version = "2.0"; };
    graphics = { listen = null; port = null; type = "none"; clipboard = false; fileTransfer = false; };
    paravirtGraphics = { enable = false; backend = "venus"; };
    input = { keyboard = false; mouse = false; tablet = true; };
    video = { model = "qxl"; heads = 1; };
    clock = { offset = "utc"; timezone = null; adjustment = 0; };
    antiDetection = { enable = true; smbiosMode = "synthetic"; patchQemu = false; patchKernel = false; };
    smbios = {
      manufacturer = null; product = null; version = null; family = null; sku = null;
      biosVersion = null; biosDate = null; biosRelease = null; serial = null;
      systemManufacturer = null; systemProduct = null; systemVersion = null; systemFamily = null;
      boardAsset = null; boardLocation = null;
      chassisManufacturer = null; chassisVersion = null; chassisAsset = null; chassisSku = null; chassisSerial = null;
      oemStrings = null;
    };
    agent = { enable = false; };
    rng = { enable = false; rateBytes = null; ratePeriod = null; };
    watchdog = { enable = false; model = "i6300esb"; action = "reset"; };
    audio = { enable = false; model = "ich9"; };
    serial = { enable = true; port = null; };
    extraQemuArgs = [];
    extraXML = null;
  };

  # Mock config builder: takes a guest attrset, returns the raw mock config.
  # This is a raw attrset — no NixOS option submodule, no assertions — so
  # cpuVendor="intel" + AD-on is fine here. The module config on the test VM
  # keeps guests={} precisely so the "cpuVendor must be auto when AD on"
  # assertion doesn't fire.
  mockConfigFor = guest: {
    cfg.kvm = {
      host = {
        inherit hwidSeed cpuVendor cpuSocket;
        antiDetection = { patchQemu = false; patchKernel = false; };
        storage = { persistentPath = null; };
      };
      guests = { adon = guest; };
    };
  };

  mockConfig = mockConfigFor baseGuest;

  guestLib = import ../../modules/kvm/guests/lib.nix { config = mockConfig; inherit lib pkgs; };
  hostLib  = import ../../modules/kvm/host/lib.nix  { config = mockConfig; inherit lib pkgs; };
  inherit (guestLib) generateXML computeEffectiveSmbios macFor hexToInt;
  inherit (hostLib) hostManufacturer;
  allProfiles = import ../../modules/kvm/host/smbios-profiles.nix;

  # ── Expected values, computed from the same libs the module uses ─────────
  # Replicate the deterministic hash derivations that generateXML computes
  # internally (guests/lib.nix L306-347) so computeEffectiveSmbios receives the
  # exact deps (serials / uuid / profileHash) the module would. Pure — no IFD.
  seedPrefix = hwidSeed;
  uuidHash       = builtins.hashString "sha256" "${seedPrefix}-${hwidSalt}-uuid";
  serialHash     = builtins.hashString "sha256" "${seedPrefix}-${hwidSalt}-serial";
  baseSerialHash = builtins.hashString "sha256" "${seedPrefix}-${hwidSalt}-base-serial";
  profileHash    = builtins.hashString "sha256" "${seedPrefix}-${hwidSalt}-profile";

  alnumChars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  serialFromHash = h:
    let bAt = i: hexToInt (substring (i * 2) 2 h);
    in concatStrings (genList (i: substring (lib.mod (bAt i) 36) 1 alnumChars) 14);
  syntheticSerial = serialFromHash serialHash;     # Type 1
  baseboardSerial = serialFromHash baseSerialHash; # Type 2
  domainUuid =
    let
      p1 = substring 0 8 uuidHash;
      p2 = substring 8 4 uuidHash;
      p3 = "4${substring 13 3 uuidHash}";  # force version 4
      variantNibble = let v = hexToInt (substring 16 1 uuidHash); in substring (lib.mod v 4) 1 "89ab";
      p4 = "${variantNibble}${substring 17 3 uuidHash}";
      p5 = substring 20 12 uuidHash;
    in "${p1}-${p2}-${p3}-${p4}-${p5}";

  # Profile list the module would select (mirror guests/lib.nix L141-152).
  validProfiles =
    let m = allProfiles.${hostManufacturer.id} or {};
        v = m.${cpuVendor} or {};
    in v.${cpuSocket} or [];
  fallbackProfile = {
    manufacturerId = hostManufacturer.id;
    manufacturer = hostManufacturer.smbiosManufacturer;
    product = hostManufacturer.defaultProduct;
    version = "1.0"; family = "Default System"; socket = cpuSocket;
    chipset = "Unknown"; cpuVendor = cpuVendor; biosVersion = "1.0.0";
  };
  smbiosProfiles = if validProfiles != [] then validProfiles else [ fallbackProfile ];

  smb = computeEffectiveSmbios {
    guest = baseGuest;
    inherit syntheticSerial domainUuid baseboardSerial profileHash smbiosProfiles hexToInt;
  };
  expectedMac = macFor "adon" { mac = null; } 0;
  # Hyperv vendor_id the module sets (matches guests/lib.nix featuresXML):
  # AuthenticAMD for amd, GenuineIntel otherwise.
  hvVendorId = if cpuVendor == "amd" then "AuthenticAMD" else "GenuineIntel";

  es = lib.escapeShellArg;  # shell-quote expected values (spaces, etc.)

  # Shared NixOS module for the test VM (nodes.machine). Both Layer 3 tests
  # need the same libvirtd wiring + the age.secrets stub (the kvm module's
  # guests/secrets.nix references age.secrets under a false-when-guests={}
  # mkIf; NixOS still requires the option to be DECLARED even when the
  # definition is mkIf-false). guests={} so the "cpuVendor must be auto when
  # AD on" assertion doesn't fire — the AD-on guest XML is produced via the
  # imported-lib mock config, not via the module's own guest handling.
  kvmTestModule = {
    imports = [
      ../../modules/kvm
      { options.age.secrets = lib.mkOption { type = lib.types.attrs; default = {}; }; }
    ];
    cfg.kvm = {
      host = {
        inherit hwidSeed cpuVendor cpuSocket;
        antiDetection = { patchQemu = false; patchKernel = false; };
        storage = { persistentPath = null; };
      };
      guests = {};
    };
  };
in {
  # Fixture inputs
  inherit hwidSeed hwidSalt cpuVendor cpuSocket;
  # Base guest + mock config builder (Option B customizes the guest before
  # calling generateXML)
  inherit baseGuest mockConfigFor;
  # Module libs (so each test can compute its own generatedXML)
  inherit generateXML computeEffectiveSmbios macFor hexToInt hostManufacturer allProfiles;
  # Hash derivations (exposed for debugging / future tests)
  inherit uuidHash serialHash baseSerialHash profileHash;
  # Computed expected values — what both probes diff against
  inherit syntheticSerial baseboardSerial domainUuid;
  inherit validProfiles fallbackProfile smbiosProfiles;
  inherit smb expectedMac hvVendorId;
  inherit es;
  # Shared NixOS module for the test VM (both Layer 3 tests use this via
  # `imports = [ common.kvmTestModule ]` in their nodes.machine config).
  inherit kvmTestModule;
}