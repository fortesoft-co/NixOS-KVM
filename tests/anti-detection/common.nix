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
#   - mkGuestImage / mkBootTest: reusable boot-test machinery (image build +
#     runNixOSTest assembly) so the future patched-QEMU / RDTSC boot variants
#     reuse Option B's results-transport + nested-KVM scaffolding without
#     rewriting it
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
  #
  # This seed selects GIGABYTE (patchToken GBTC) for (intel, LGA1700) — a
  # NON-template manufacturer. That's deliberate: the patched-QEMU tests (the
  # compile test's static binary check + this boot test's runtime checks) can
  # only PROVE the dynamic sed ran if the selected token differs from the patch's
  # ASUS template (ASUS→ASUS is a no-op). With GBTC, GBTC-strings-present +
  # ASUS-template-absent is real proof. The compile test (qemu-patch-build.nix)
  # imports this same seed so both build the SAME manufacturer's patched QEMU —
  # single source, no drift, no separate recompile for a different manufacturer.
  hwidSeed  = "00000000-0000-4000-8000-000000000000";
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
  guestAd = import ../../modules/kvm/guests/anti-detection.nix { config = mockConfig; inherit lib pkgs; };
  inherit (guestLib) generateXML macFor;
  inherit (guestAd) computeEffectiveSmbios hexToInt smbiosProfiles;

  # Host-side manufacturer the fixture seed selects — the patched-QEMU boot
  # test needs the patchToken to assert the patched strings surfaced inside
  # the guest (the token is seed-selected on the host and baked into the
  # patched QEMU binary via the dynamic sed). Pure here: cpuVendor/cpuSocket
  # are explicit in the fixture, so no cpuid_tool IFD.
  hostAd = import ../../modules/kvm/host/anti-detection.nix { config = mockConfig; inherit lib pkgs; };
  hostManufacturer = hostAd.hostManufacturer;

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

  # Profile list the module would select — from the AD module (no duplication).

  smb = computeEffectiveSmbios {
    guest = baseGuest;
    inherit syntheticSerial domainUuid baseboardSerial profileHash smbiosProfiles hexToInt;
  };
  expectedMac = macFor "adon" { mac = null; } 0;
  # Hyperv vendor_id the module sets (matches guests/lib.nix featuresXML):
  # AuthenticAMD for amd, GenuineIntel otherwise.
  hvVendorId = if cpuVendor == "amd" then "AuthenticAMD" else "GenuineIntel";

  es = lib.escapeShellArg;  # shell-quote expected values (spaces, etc.)

  # ── Boot-test reuse helpers ─────────────────────────────────────────────
  # Layer 3 boot tests (Option B + the future patched-QEMU / RDTSC variants)
  # share the same machinery: build a bootable NixOS guest image that runs a
  # probe on boot + writes to a raw results disk + powers off, then assemble a
  # runNixOSTest that boots it under libvirt with nested KVM and runs a
  # host-side diff. Extracted here so each boot test supplies only its own
  # guest config, probe script, expected values, and diff harness.

  # Build a minimal BIOS-bootable NixOS guest (qcow2 via make-disk-image.nix)
  # that runs a LIST of probe scripts after multi-user.target, concatenates
  # their stdout between a single ===PROBE-START/END=== marker pair, writes it
  # to a raw results disk (/dev/sdb under AD-on's forced SATA bus, /dev/vdb
  # fallback), syncs, and powers off. Taking a LIST (not one script) lets each
  # boot test compose its probe from a shared base + test-specific extras with
  # no duplication (Option B = [ base ]; patched = [ base, patchedExtras ]). The
  # individual probe scripts emit only their `--- section ---` blocks — NO
  # markers — so they compose cleanly. `extraGuestConfig` is extra NixOS config
  # merged in (e.g. extra packages for a patched-string probe). Returns
  # { eval, image } — callers need `eval.config.image.fileName` for the path.
  mkGuestImage = { name, probeScripts, extraGuestConfig ? {} }:
    let
      eval = import "${pkgs.path}/nixos/lib/eval-config.nix" {
        system = "x86_64-linux";
        modules = [
          "${pkgs.path}/nixos/modules/virtualisation/disk-image.nix"
          {
            image.baseName = name;
            image.format = "qcow2";
            image.efiSupport = false;  # BIOS — matches fixture firmware="bios"
            virtualisation.diskSize = "auto";  # closure + 512M slack

            environment.systemPackages = with pkgs; [
              dmidecode pciutils iproute2 util-linux
            ];

            # Silence getty spam — results transport is a raw disk, not serial.
            systemd.services."serial-getty@ttyS0".enable = false;
            systemd.services."getty@tty1".enable = false;
            systemd.services."autovt@".enable = false;

            # The probe service: run after multi-user.target, run every probe
            # script in sequence inside one marker pair, write the concat to
            # the results disk, sync, power off. The results disk is the second
            # SATA disk (AD-on forces SATA: sda=boot, sdb=results); /dev/vdb
            # fallback covers a future bus assignment change. Each `${s}` is a
            # store path; a failing script (set -e inside it) exits non-zero but
            # the next still runs (separate process invocations, no `&&`), so a
            # partial probe still yields the END marker + whatever captured.
            systemd.services."${name}-probe" = {
              wantedBy = [ "multi-user.target" ];
              after = [ "multi-user.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              path = with pkgs; [ dmidecode pciutils iproute2 util-linux ];
              script = ''
                RESULTS_DEV=""
                for dev in /dev/sdb /dev/vdb; do
                  if [ -b "$dev" ]; then RESULTS_DEV="$dev"; break; fi
                done
                if [ -z "$RESULTS_DEV" ]; then
                  echo "FAIL: no results disk found (tried /dev/sdb /dev/vdb)" >&2
                  poweroff
                fi
                {
                  echo "===PROBE-START==="
                  ${concatMapStringsSep "\n                  " (s: "${s}") probeScripts}
                  echo "===PROBE-END==="
                } > "$RESULTS_DEV"
                sync
                poweroff
              '';
            };
          }
          extraGuestConfig
        ];
      };
    in { inherit eval; image = eval.config.system.build.image; };

  # Assemble a Layer-3-style boot test (runNixOSTest) from a guest image + the
  # libvirt domain XML + the probe/diff scripts. Reuses kvmTestModule for the
  # test VM's libvirtd wiring and sizes the VM for nested KVM headroom.
  # `extraTestVMModules` is a list of extra NixOS modules for the test VM
  # (e.g. enabling patched QEMU via antiDetection.patchQemu = true for the
  # patched-boot variant). `driverScript` is a path to a Python file with
  # @GUEST_IMAGE@ / @XML_FILE@ / @DIFF_HARNESS@ / @EXPECTED_VALUES@ tokens
  # (the existing guest-smbios-boot-driver.py works as-is for any test that
  # keeps the domain name "adon").
  mkBootTest = {
    name, guestImage, xmlFile, driverScript, diffHarness, expectedValues,
    extraTestVMModules ? []
  }:
    pkgs.testers.runNixOSTest {
      inherit name;
      nodes.machine = { pkgs, lib, ... }: {
        # Nested KVM headroom — the AD-on guest requests 1 vCPU / 1024 MiB;
        # the test VM itself needs the rest. Default 1c/2G causes
        # "cannot set up guest memory" + "SMP exceeds KVM recommended".
        virtualisation.cores = 2;
        virtualisation.memorySize = 4096;
        # kvmTestModule = libvirtd wiring + age.secrets stub (see below).
        # extraTestVMModules lets a caller extend the test VM — e.g. the
        # patched-boot variant passes
        #   [ { cfg.kvm.host.antiDetection.patchQemu = true; } ]
        # to make libvirtd use the dynamically-patched QEMU.
        imports = [ kvmTestModule ] ++ extraTestVMModules;
        environment.systemPackages = with pkgs; [ libvirt dmidecode ];
      };
      testScript = let
        guestImagePath = "${guestImage.image}/${guestImage.eval.config.image.fileName}";
      in replaceStrings
        [ "@GUEST_IMAGE@" "@XML_FILE@" "@DIFF_HARNESS@" "@EXPECTED_VALUES@" ]
        [ guestImagePath      "${xmlFile}"  "${diffHarness}" "${expectedValues}" ]
        (readFile driverScript);
    };

  # ── Expected-values + diff-harness builders (shared 20-field core) ────────
  # The 20 SMBIOS/NIC/CPU regression checks AND their expected values are
  # identical across the boot tests (Option B + patched). Each lives in ONE
  # place here; a test supplies only its extras, so the core can't drift.
  # Option A is NOT a consumer — it uses a different probe style (virsh
  # xpath/argv, no results-disk diff harness) and different EXPECTED_* key names
  # (sys_manufacturer vs sys_vendor, etc.), so it's intentionally left out.

  # Shell-sourceable expected-values file: the 20 standard EXPECTED_* lines
  # (Option B naming) + caller-supplied extra lines. Values are Nix-computed
  # (smb/domainUuid/expectedMac), so this can't be a static shell script — it
  # must be a Nix helper.
  mkExpectedValues = { name, extraLines ? "" }:
    pkgs.writeText "${name}-expected-values.sh" ''
      EXPECTED_bios_vendor=${es smb.biosVendor}
      EXPECTED_bios_version=${es smb.biosVersion}
      EXPECTED_bios_date=${es smb.biosDate}
      EXPECTED_sys_vendor=${es smb.systemManufacturer}
      EXPECTED_product_name=${es smb.systemProduct}
      EXPECTED_product_version=${es smb.systemVersion}
      EXPECTED_product_serial=${es smb.systemSerial}
      EXPECTED_product_uuid=${es domainUuid}
      EXPECTED_product_family=${es smb.systemFamily}
      EXPECTED_product_sku=${es smb.systemSku}
      EXPECTED_board_vendor=${es smb.boardManufacturer}
      EXPECTED_board_name=${es smb.boardProduct}
      EXPECTED_board_version=${es smb.boardVersion}
      EXPECTED_board_serial=${es smb.boardSerial}
      EXPECTED_chassis_vendor=${es smb.chassisManufacturer}
      EXPECTED_chassis_version=${es smb.chassisVersion}
      EXPECTED_chassis_serial=${es smb.chassisSerial}
      EXPECTED_chassis_asset_tag=${es smb.chassisAsset}
      EXPECTED_nic_mac=${es expectedMac}
      EXPECTED_cpu_hypervisor_present=0
      ${extraLines}
    '';

  # Host-side diff harness: concatenates the shared base fragment (boilerplate
  # + 20 checks — defines check()/dmi()/PROBE/PASS/FAIL) + caller-supplied
  # extras + the shared summary fragment into one writeShellScript (which adds
  # the shebang). Mirrors the probe composition (mkGuestImage's probeScripts
  # list) but at eval time — one assembled script, not a runtime list. The
  # extras are in scope for check()/PROBE/etc. via concatenation.
  mkDiffHarness = { name, extras ? "" }:
    pkgs.writeShellScript "${name}-results-diff"
      (concatStringsSep "\n" [
        (readFile ./scripts/guest-smbios-diff-base.sh)
        extras
        (readFile ./scripts/guest-smbios-diff-summary.sh)
      ]);

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
  inherit generateXML computeEffectiveSmbios macFor hexToInt smbiosProfiles;
  # Hash derivations (exposed for debugging / future tests)
  inherit uuidHash serialHash baseSerialHash profileHash;
  # Computed expected values — what both probes diff against
  inherit syntheticSerial baseboardSerial domainUuid;
  inherit smb expectedMac hvVendorId;
  inherit es;
  # Host-level manufacturer record the fixture selects (patchToken etc.) —
  # used by the patched-QEMU boot test to know which token should surface.
  inherit hostManufacturer;
  # Boot-test reuse machinery (Layer 3 Option B + future patched variants)
  inherit mkGuestImage mkBootTest;
  # Shared 20-field expected-values + diff-harness builders (Option B + patched)
  inherit mkExpectedValues mkDiffHarness;
  # Shared NixOS module for the test VM (both Layer 3 tests use this via
  # `imports = [ common.kvmTestModule ]` in their nodes.machine config).
  inherit kvmTestModule;
}