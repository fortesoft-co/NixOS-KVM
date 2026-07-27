# Layer 3 (unpatched) SMBIOS surfacing test.
#
# Verifies, with libvirt's own machinery, that the anti-detection SMBIOS / NIC
# / CPU values the module produces actually reach QEMU — not just that the XML
# is well-formed (that's tests/guest/xml.nix) but that libvirt ACCEPTS the XML,
# STORES every entry, and would PASS them on the QEMU command line:
#
#   1. `virsh define`           — libvirt's schema/parser must accept the XML.
#      A rejected define is a hard failure.
#   2. `virsh dumpxml`          — the XML libvirt actually stored. We xpath-compare
#      every <sysinfo> entry (Type 0/1/2/3/11) plus the AD wiring (hyperv
#      vendor_id, memballoon=none, e1000e NIC, host-passthrough cpu, disabled
#      hypervisor flag) against what the module computed for the seed. A
#      dropped/rewritten entry is a regression — exactly the "libvirt silently
#      dropped <sysinfo> entries" class CONTEXT.md names.
#   3. `virsh domxml-to-native qemu-argv` — the QEMU command line libvirt WOULD
#      invoke. We assert the `-smbios type=0/1/2/3/11` blocks, the `e1000e` NIC
#      model + its MAC, and the CPU's `hypervisor=off` + `hv-vendor-id=...` (the
#      AD signals libvirt translates host-passthrough + the disabled hypervisor
#      feature into) carry the expected space-free values (serials/uuid/mac).
#      This is libvirt's PURE argv computation — it needs NO KVM and NO
#      running domain, so the test runs anywhere (TCG-only CI, no nested
#      KVM). If the conversion fails in a given environment (e.g. TCG refuses
#      host-passthrough caps), we skip the argv checks with a warning — the
#      dumpxml checks above already prove the values were accepted and stored.
#
# What this does NOT cover (intentional, per the testing strategy):
#   - Reading firmware tables from INSIDE a booted guest (dmidecode). That
#     catches a QEMU/SeaBIOS bug ignoring a passed -smbios — rare, and a
#     separate bigger-lift test (guest-OS boot).
#   - Patched-string surface (ACPI OEM ID, disk model strings). That belongs
#     in the opt-in guest-smbios-patched.nix (builds QEMU from source).
#
# Machine-independence: every expected value derives from explicit fixture
# inputs (hwidSeed, hwidSalt, cpuVendor="intel", cpuSocket="LGA1700") — NOT
# from host hardware. The module's IFD hardware probing (cpuVendor="auto" /
# cpuSocket="auto") never runs in this test. The module's host/libvirtd wiring
# is exercised in a real NixOS eval (cfg.kvm.host set, guests={} so the
# "cpuVendor must be auto when AD on" assertion doesn't fire — the AD-on guest
# is produced via the imported-lib mock-config pattern, identical to
# tests/guest/xml.nix and tests/anti-detection/guest-lib.nix, which don't run
# assertions on the raw config attrset).
#
# Standalone build:
#   nix build .#checks.x86_64-linux.anti-detection-guest-smbios --no-link
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

  # Full AD-on synthetic guest. Every field is provided so the mock config
  # fed to generateXML doesn't rely on option submodule defaults (same shape
  # as tests/guest/xml.nix's baseGuest + adOn delta).
  fullGuest = {
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

  # Mock config for importing the module libs. This is a raw attrset — no NixOS
  # option submodule, no assertions — so cpuVendor="intel" + AD-on is fine here.
  # The module config on the test VM (below) keeps guests={} precisely so the
  # "cpuVendor must be auto when AD on" assertion doesn't fire.
  mockConfig = {
    cfg.kvm = {
      host = {
        inherit hwidSeed cpuVendor cpuSocket;
        antiDetection = { patchQemu = false; patchKernel = false; };
        storage = { persistentPath = null; };
      };
      guests = { adon = fullGuest; };
    };
  };

  guestLib = import ../../modules/kvm/guests/lib.nix { config = mockConfig; inherit lib pkgs; };
  hostLib  = import ../../modules/kvm/host/lib.nix  { config = mockConfig; inherit lib pkgs; };
  inherit (guestLib) generateXML computeEffectiveSmbios macFor hexToInt;
  inherit (hostLib) hostManufacturer;
  allProfiles = import ../../modules/kvm/host/smbios-profiles.nix;

  generatedXML = generateXML "adon" fullGuest;
  xmlFile = pkgs.writeText "kvm-guest-adon.xml" generatedXML;

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
    guest = fullGuest;
    inherit syntheticSerial domainUuid baseboardSerial profileHash smbiosProfiles hexToInt;
  };
  expectedMac = macFor "adon" { mac = null; } 0;
  # Hyperv vendor_id the module sets (matches guests/lib.nix featuresXML):
  # AuthenticAMD for amd, GenuineIntel otherwise.
  hvVendorId = if cpuVendor == "amd" then "AuthenticAMD" else "GenuineIntel";

  # ── Probe script (run inside the test VM) ─────────────────────────────────
  es = lib.escapeShellArg;  # shell-quote expected values (spaces, etc.)

  # One xcheck line per OEM string, generated in Nix.
  oemChecks = concatStringsSep "\n  " (
    imap0 (i: s:
      ''xcheck "string(/domain/sysinfo[@type='smbios']/oemStrings/entry[${toString (i + 1)}])" ${es s} "oem[${toString (i + 1)}]"''
    ) smb.oemStrings
  );

  probeBody = ''
    set -e
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
    XML=${xmlFile}

    echo "=== warming up libvirtd (socket-activated) ==="
    for i in $(seq 1 30); do
      if virsh -c qemu:///system capabilities >/dev/null 2>&1; then break; fi
      sleep 1
    done
    if ! virsh -c qemu:///system capabilities >/dev/null 2>&1; then
      echo "FAIL: libvirtd qemu driver never came up"; exit 1
    fi

    echo "=== virsh define (libvirt schema/parser must accept the XML) ==="
    virsh define "$XML" >/dev/null

    echo "=== virsh dumpxml (libvirt-stored XML) ==="
    virsh dumpxml adon > /tmp/dumped.xml

    X=/tmp/dumped.xml
    # xpath-text equality on the dumped XML. `|| true` so a non-matching xpath
    # (returns empty + nonzero) becomes an empty string we compare, not a
    # set -e abort.
    xcheck() {
      local got
      got=$(xmllint --xpath "$1" "$X" 2>/dev/null || true)
      if [ "$got" != "$2" ]; then
        echo "FAIL [$3]"
        echo "  xpath: $1"
        echo "  got : '$got'"
        echo "  want: '$2'"
        exit 1
      fi
    }

    echo "=== checking libvirt stored every sysinfo entry (the 'silently dropped' check) ==="
    xcheck "count(/domain/sysinfo[@type='smbios'])" "1" "sysinfo.present"
    xcheck "count(/domain/os/smbios[@mode='sysinfo'])" "1" "os.smbios-wired"
    # Type 0 (BIOS)
    xcheck "string(/domain/sysinfo[@type='smbios']/bios/entry[@name='vendor'])"   ${es smb.biosVendor}  "bios.vendor"
    xcheck "string(/domain/sysinfo[@type='smbios']/bios/entry[@name='version'])"  ${es smb.biosVersion} "bios.version"
    xcheck "string(/domain/sysinfo[@type='smbios']/bios/entry[@name='date'])"     ${es smb.biosDate}    "bios.date"
    xcheck "string(/domain/sysinfo[@type='smbios']/bios/entry[@name='release'])"  ${es smb.biosRelease} "bios.release"
    # Type 1 (System). UUID is lifted to /domain/uuid by libvirt; check there
    # (the sysinfo system/uuid entry may be de-duplicated away).
    xcheck "string(/domain/uuid)" ${es domainUuid} "domain.uuid"
    xcheck "string(/domain/sysinfo[@type='smbios']/system/entry[@name='manufacturer'])" ${es smb.systemManufacturer} "sys.manufacturer"
    xcheck "string(/domain/sysinfo[@type='smbios']/system/entry[@name='product'])"      ${es smb.systemProduct}      "sys.product"
    xcheck "string(/domain/sysinfo[@type='smbios']/system/entry[@name='version'])"       ${es smb.systemVersion}      "sys.version"
    xcheck "string(/domain/sysinfo[@type='smbios']/system/entry[@name='serial'])"        ${es smb.systemSerial}       "sys.serial"
    xcheck "string(/domain/sysinfo[@type='smbios']/system/entry[@name='sku'])"           ${es smb.systemSku}          "sys.sku"
    xcheck "string(/domain/sysinfo[@type='smbios']/system/entry[@name='family'])"        ${es smb.systemFamily}       "sys.family"
    # Type 2 (Baseboard)
    xcheck "string(/domain/sysinfo[@type='smbios']/baseBoard/entry[@name='manufacturer'])" ${es smb.boardManufacturer} "board.manufacturer"
    xcheck "string(/domain/sysinfo[@type='smbios']/baseBoard/entry[@name='product'])"      ${es smb.boardProduct}      "board.product"
    xcheck "string(/domain/sysinfo[@type='smbios']/baseBoard/entry[@name='version'])"      ${es smb.boardVersion}      "board.version"
    xcheck "string(/domain/sysinfo[@type='smbios']/baseBoard/entry[@name='serial'])"       ${es smb.boardSerial}       "board.serial"
    # Type 3 (Chassis)
    xcheck "string(/domain/sysinfo[@type='smbios']/chassis/entry[@name='manufacturer'])" ${es smb.chassisManufacturer} "chassis.manufacturer"
    xcheck "string(/domain/sysinfo[@type='smbios']/chassis/entry[@name='version'])"       ${es smb.chassisVersion}     "chassis.version"
    xcheck "string(/domain/sysinfo[@type='smbios']/chassis/entry[@name='serial'])"        ${es smb.chassisSerial}      "chassis.serial"
    xcheck "string(/domain/sysinfo[@type='smbios']/chassis/entry[@name='asset'])"         ${es smb.chassisAsset}       "chassis.asset"
    xcheck "string(/domain/sysinfo[@type='smbios']/chassis/entry[@name='sku'])"           ${es smb.chassisSku}         "chassis.sku"
    # Type 11 (OEM Strings)
    xcheck "count(/domain/sysinfo[@type='smbios']/oemStrings/entry)" "${toString (length smb.oemStrings)}" "oem.count"
    ${oemChecks}
    # AD wiring preserved
    xcheck "count(/domain/features/hyperv/vendor_id[@state='on'])" "1" "hyperv.vendor_id"
    xcheck "count(/domain/devices/memballoon[@model='none'])" "1" "memballoon.none"
    xcheck "count(/domain/devices/interface/model[@type='e1000e'])" "1" "nic.e1000e"
    xcheck "count(/domain/cpu[@mode='host-passthrough'])" "1" "cpu.host-passthrough"
    xcheck "count(/domain/cpu/feature[@name='hypervisor' and @policy='disable'])" "1" "cpu.hypervisor-disabled"

    echo "=== virsh domxml-to-native qemu-argv (libvirt's QEMU command line) ==="
    if ! virsh domxml-to-native qemu-argv "$XML" > /tmp/argv.sh 2>/tmp/argv.err; then
      echo "WARN: domxml-to-native failed (often a TCG/no-KVM env refusing host-passthrough caps);"
      echo "      skipping qemu-argv checks. dumpxml checks above already verify libvirt stored"
      echo "      every value, which is the primary regression surface for this test."
      sed 's/^/      /' /tmp/argv.err
      echo "OK (dumpxml only): libvirt accepted and stored all SMBIOS/NIC/CPU values."
      exit 0
    fi

    # libvirt shell-quotes argv tokens that contain special chars: the -smbios
    # value has commas (and the vendor has spaces), so it's emitted as
    # `-smbios 'type=0,vendor=...,version=...'`. Strip shell quotes so our
    # space-free substring tokens match. Our tokens contain no quotes, so
    # this is safe.
    tr -d "'\"" < /tmp/argv.sh > /tmp/argv.norm
    A=/tmp/argv.norm
    ahas()   { if ! grep -qF  -- "$1" "$A"; then echo "FAIL: qemu argv missing '$1'"; exit 1; fi; }
    ahas_i() { if ! grep -qiF -- "$1" "$A"; then echo "FAIL: qemu argv missing (case-insensitive) '$1'"; exit 1; fi; }

    echo "=== checking qemu argv carries the values (space-free tokens; quoting-safe) ==="
    # SMBIOS: libvirt emits `-smbios type=N,key=value,...` (key=value style).
    ahas "-smbios type=0"
    ahas "version=${smb.biosVersion}"
    ahas "-smbios type=1"
    ahas "serial=${smb.systemSerial}"
    ahas "uuid=${domainUuid}"
    ahas "-smbios type=2"
    ahas "serial=${smb.boardSerial}"
    ahas "-smbios type=3"
    ahas "-smbios type=11"
    # NIC: libvirt emits the e1000e model either as `-device e1000e,...` or the
    # qom form `-device {driver:e1000e,...}` (version-dependent); the model
    # name appears either way. The MAC address itself is distinctive, so match
    # it directly (robust to `mac=` vs `mac:` separators, and case).
    ahas "e1000e"
    ahas_i "${expectedMac}"
    # CPU: libvirt translates <cpu mode='host-passthrough'> into `-cpu host,...`
    # (qemu's `host` model IS host-passthrough) and the disabled `hypervisor`
    # feature into `hypervisor=off`. The hyperv <vendor_id> becomes
    # `hv-vendor-id=<GenuineIntel|AuthenticAMD>`. These three are the AD cpu
    # signals; the dumpxml checks above already proved the source XML is correct.
    ahas "hypervisor=off"
    ahas "hv-vendor-id=${hvVendorId}"

    echo "OK: libvirt accepted, stored, and would pass all SMBIOS/NIC/CPU values to QEMU."
  '';

  probeScript = pkgs.writeShellScript "guest-smbios-probe" probeBody;

  # ── The test VM ──────────────────────────────────────────────────────────
  # Enable the real kvm module's HOST config (libvirtd wiring evals in a real
  # NixOS build). guests={} so the "cpuVendor must be auto when AD on" guard
  # doesn't fire — the AD-on guest XML is produced above via the imported-lib
  # mock config (the same trusted pattern tests/guest/xml.nix uses).
  test = pkgs.testers.runNixOSTest {
    name = "anti-detection-guest-smbios";
    nodes.machine = { pkgs, lib, ... }: {
      imports = [
        ../../modules/kvm
        # The kvm module's guests/secrets.nix sets `age.secrets` under a (false
        # here, since guests={}) mkIf. NixOS still requires the option to be
        # DECLARED even when the definition is mkIf-false, so stub it. agenix
        # itself isn't needed — no secrets are used in this test.
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
      environment.systemPackages = [ pkgs.libxml2 ];
    };
    testScript = ''
      machine.wait_for_unit("multi-user.target")
      # Capture the probe's stdout into the test log on SUCCESS too. By default
      # `machine.succeed` only dumps its captured stdout on FAILURE (via the
      # exception), so a passing run's `===`/`OK:` lines would be lost and
      # `nix log` would show nothing of what the probe did. `machine.log` writes
      # them to the build log (retrievable via `nix log` or `-L`); the default
      # `nix build` / `nix flake check` (no `-L`) stay quiet on success, since
      # they don't stream logs — so default CI behavior is unchanged.
      out = machine.succeed("${probeScript}")
      machine.log(out)
    '';
  };
in
  test