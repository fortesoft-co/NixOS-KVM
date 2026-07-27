# General XML-generation test for guests/lib.nix generateXML.
# Lives under tests/guest/ (not anti-detection) because XML generation is a
# general concern; anti-detection is one thing it must handle correctly.
#
# This is a BUILD-TIME check (not eval-time): it returns a runCommand derivation
# that pipes the generated XML through xmllint (libxml2). xmllint --noout checks
# well-formedness; --xpath checks structural correctness + the cheap high-value
# value assertions (AD on → <smbios mode='sysinfo'/> present, <hyperv>, host-
# passthrough cpu; AD off → none of those). No regex on XML.
#
# Per the testing strategy: this is the safety net for generateXML. The
# computeEffectiveSmbios extraction (done in guests/lib.nix) is unit-tested
# separately in tests/anti-detection/guest-lib.nix; this test covers the full
# XML assembly + the other sections end-to-end via xpath, without extracting them.
#
# Standalone build:
#   nix build .#checks.x86_64-linux.guest.xml --no-link
{ lib, pkgs }:
with lib;
let
  # Minimal mock config. Explicit cpuVendor/cpuSocket (no IFD). generateXML
  # reads cfg.host.{hwidSeed,cpuVendor,cpuSocket,antiDetection,storage} and
  # cfg.guests.${name} (macFor reads the config's guest, so each variant must
  # be registered under the name passed to generateXML).
  mkConfig = guests: {
    cfg.kvm = {
      host = {
        hwidSeed = "host-seed-xml-test";
        cpuVendor = "intel";
        cpuSocket = "LGA1700";
        antiDetection = { patchQemu = false; patchKernel = false; };
        storage = { persistentPath = null; };
      };
      guests = guests;
    };
  };
  guestLib = import ../../modules/kvm/guests/lib.nix { config = mkConfig baseGuests; inherit lib pkgs; };
  inherit (guestLib) generateXML;

  # ── Composed fixtures: one baseGuest + small deltas per scenario ─────────
  # Verbose once; each variant is baseGuest // { ...small override... }.

  baseGuest = {
    enable = true;
    domainName = "base";
    hwidSalt = "base-salt-0001";
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
    antiDetection = { enable = false; smbiosMode = "synthetic"; patchQemu = false; patchKernel = false; };
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

  # Variant: anti-detection ON (synthetic). Registered under "adon".
  adOnGuest = baseGuest // {
    domainName = "adon";
    hwidSalt = "adon-salt-0002";
    antiDetection = baseGuest.antiDetection // { enable = true; smbiosMode = "synthetic"; };
  };
  # Variant: anti-detection OFF. Registered under "adoff".
  adOffGuest = baseGuest // {
    domainName = "adoff";
    hwidSalt = "adoff-salt-0003";
  };
  # Variant: AD on + a disk (exercises disk boot-order assignment + SATA rewrite).
  adOnWithDisksGuest = adOnGuest // {
    domainName = "adon-disks";
    hwidSalt = "adon-disks-salt-0004";
    disks = [
      { device = "disk"; format = "qcow2"; path = "disk0"; bus = "virtio"; boot = null; cache = null; aio = null; discard = null; iothread = null; ssd = false; serial = null; readOnly = false; }
      { device = "cdrom"; format = "raw"; path = "seed.iso"; bus = "sata"; boot = null; cache = null; aio = null; discard = null; iothread = null; ssd = false; serial = null; readOnly = true; }
    ];
  };
  # Variant: AD on + PCI passthrough (exercises hostdev XML).
  adOnWithPassthroughGuest = adOnGuest // {
    domainName = "adon-pt";
    hwidSalt = "adon-pt-salt-0005";
    passthrough = { pci = [ { id = "0000:01:00.0"; romBar = false; } ]; usb = []; };
  };

  baseGuests = {
    adon = adOnGuest;
    adoff = adOffGuest;
    "adon-disks" = adOnWithDisksGuest;
    "adon-pt" = adOnWithPassthroughGuest;
  };

  # Generate each variant's XML.
  xmlFiles = {
    adon = pkgs.writeText "adon.xml" (generateXML "adon" adOnGuest);
    adoff = pkgs.writeText "adoff.xml" (generateXML "adoff" adOffGuest);
    "adon-disks" = pkgs.writeText "adon-disks.xml" (generateXML "adon-disks" adOnWithDisksGuest);
    "adon-pt" = pkgs.writeText "adon-pt.xml" (generateXML "adon-pt" adOnWithPassthroughGuest);
  };

  # A bash assertion helper: each line is `assert_xpath <file> "<xpath>" "<expected>"`.
  # xmllint --xpath prints the match (or nothing); we compare to expected. For
  # count() queries expected is the count as a string. For absence, expected "".
  assertNoout = file: "xmllint --noout ${file} || { echo 'FAIL: ${file} not well-formed XML' >&2; exit 1; }";
  assertXpath = file: xpath: expected:
    # xmllint --xpath returns 0 even if no match (prints nothing); we compare output.
    # Shell-double-quote the xpath arg so xpaths containing single quotes (e.g.
    # [@type='kvm']) survive — our xpaths use single quotes for attr values, never double.
    let xp = ''result=$(xmllint --xpath "${xpath}" ${file} 2>/dev/null); if [ "$result" != "${expected}" ]; then echo "FAIL: ${file} xpath '${xpath}' got '$result' want '${expected}'" >&2; exit 1; fi'';
    in xp;

  # Structural checks applied to every variant.
  structChecks = file: [
    (assertNoout file)
    (assertXpath file "count(/domain)" "1")
    (assertXpath file "count(/domain[@type='kvm'])" "1")
    (assertXpath file "count(/domain/name)" "1")
    (assertXpath file "count(/domain/uuid)" "1")
    (assertXpath file "count(/domain/memory)" "1")
    (assertXpath file "count(/domain/vcpu)" "1")
    (assertXpath file "count(/domain/os)" "1")
    (assertXpath file "count(/domain/devices)" "1")
    (assertXpath file "count(/domain/devices/interface)" "1")
  ];

  # AD-on value checks (cheap, high-value).
  adOnChecks = file: [
    (assertXpath file "count(/domain/os/smbios[@mode='sysinfo'])" "1")
    (assertXpath file "count(/domain/sysinfo[@type='smbios'])" "1")
    (assertXpath file "count(/domain/features/hyperv/vendor_id)" "1")
    (assertXpath file "count(/domain/cpu[@mode='host-passthrough'])" "1")
    (assertXpath file "count(/domain/devices/interface/model[@type='e1000e'])" "1")
    (assertXpath file "count(/domain/devices/memballoon[@model='none'])" "1")
    # CPU hypervisor flag disabled when AD on
    (assertXpath file "count(/domain/cpu/feature[@name='hypervisor' and @policy='disable'])" "1")
  ];

  # AD-off value checks (absence).
  adOffChecks = file: [
    (assertXpath file "count(/domain/os/smbios)" "0")
    (assertXpath file "count(/domain/sysinfo)" "0")
    (assertXpath file "count(/domain/features/hyperv)" "0")
    (assertXpath file "count(/domain/cpu[@mode='host-model'])" "1")
    (assertXpath file "count(/domain/cpu[@mode='host-passthrough'])" "0")
    (assertXpath file "count(/domain/devices/memballoon[@model='none'])" "0")
    (assertXpath file "count(/domain/devices/interface/model[@type='virtio'])" "1")  # virtio NOT rewritten when AD off
  ];

  disksChecks = file: [
    (assertXpath file "count(/domain/devices/disk)" "2")
    (assertXpath file "count(/domain/devices/disk/boot)" "2")  # boot orders assigned to both
    (assertXpath file "count(/domain/devices/disk[@device='disk']/target[@bus='sata'])" "1")  # virtio→sata rewrite when AD on
    (assertXpath file "count(/domain/devices/disk[@device='cdrom']/target[@bus='sata'])" "1")
  ];

  passthroughChecks = file: [
    (assertXpath file "count(/domain/devices/hostdev[@type='pci' and @managed='yes'])" "1")
    (assertXpath file "count(/domain/devices/hostdev/driver[@name='vfio-pci'])" "1")
    (assertXpath file "count(/domain/devices/hostdev/source/address)" "1")
  ];

  allAssertions =
       concatMap structChecks [ xmlFiles.adon xmlFiles.adoff xmlFiles."adon-disks" xmlFiles."adon-pt" ]
    ++ adOnChecks xmlFiles.adon
    ++ adOffChecks xmlFiles.adoff
    ++ disksChecks xmlFiles."adon-disks"
    ++ passthroughChecks xmlFiles."adon-pt";

  script = ''
    set -e
    ${concatStringsSep "\n" allAssertions}
    touch $out
  '';
in
  pkgs.runCommand "check-guest-xml" { nativeBuildInputs = [ pkgs.libxml2 ]; } script