# Layer 3 (unpatched) SMBIOS surfacing test — Option A.
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
#     separate bigger-lift test (guest-smbios-boot.nix, Option B).
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
# Scripts are extracted into ./scripts/ (same pattern as Option B):
#   scripts/guest-smbios-probe.sh    — virsh define/dumpxml/domxml-to-native checks
#   scripts/guest-smbios-driver.py   — test driver (Python, @PLACEHOLDER@ tokens)
#
# Standalone build:
#   nix build .#checks.x86_64-linux.anti-detection-guest-smbios --no-link
{ lib, pkgs }:
with lib;
let
  # Shared fixture + expected-value machinery (hwidSeed/hwidSalt/cpuVendor/
  # cpuSocket, baseGuest, module libs, hash derivations, smb, expectedMac,
  # hvVendorId, es). See common.nix for the rationale. This test (Option A)
  # uses the base guest as-is (no disk); Option B merges in a real qcow2.
  common = import ./common.nix { inherit lib pkgs; };
  inherit (common)
    hwidSeed hwidSalt cpuVendor cpuSocket
    baseGuest generateXML kvmTestModule
    smb domainUuid expectedMac hvVendorId es;

  # Option A uses the base guest verbatim (no disk — only XML/argv surfacing
  # is checked, no actual boot).
  fullGuest = baseGuest;

  generatedXML = generateXML "adon" fullGuest;
  xmlFile = pkgs.writeText "kvm-guest-adon.xml" generatedXML;

  # ── Scripts (extracted into ./scripts/ for maintainability) ──────────────
  # Pure shell, read via readFile — no '' escaping issues, proper highlighting.
  probeScript = pkgs.writeShellScript "guest-smbios-probe"
    (readFile ./scripts/guest-smbios-probe.sh);

  # Expected-values file: shell-sourceable assignments generated from the same
  # common.nix expected-value harness. The probe script sources this at runtime,
  # keeping the shell script completely static. Two kinds of values:
  #   EXPECTED_* — shell-quoted values for xpath xcheck() comparisons.
  #   ARGV_*     — raw space-free tokens for qemu-argv substring checks.
  #   EXPECTED_oem_count + EXPECTED_oem_N — OEM strings (Type 11), looped over
  #   by the probe script.
  oemEntries = concatStringsSep "\n"
    (imap0 (i: s: "EXPECTED_oem_${toString (i + 1)}=${es s}") smb.oemStrings);

  expectedValues = pkgs.writeText "guest-smbios-expected-values.sh" ''
    EXPECTED_bios_vendor=${es smb.biosVendor}
    EXPECTED_bios_version=${es smb.biosVersion}
    EXPECTED_bios_date=${es smb.biosDate}
    EXPECTED_bios_release=${es smb.biosRelease}
    EXPECTED_domain_uuid=${es domainUuid}
    EXPECTED_sys_manufacturer=${es smb.systemManufacturer}
    EXPECTED_sys_product=${es smb.systemProduct}
    EXPECTED_sys_version=${es smb.systemVersion}
    EXPECTED_sys_serial=${es smb.systemSerial}
    EXPECTED_sys_sku=${es smb.systemSku}
    EXPECTED_sys_family=${es smb.systemFamily}
    EXPECTED_board_manufacturer=${es smb.boardManufacturer}
    EXPECTED_board_product=${es smb.boardProduct}
    EXPECTED_board_version=${es smb.boardVersion}
    EXPECTED_board_serial=${es smb.boardSerial}
    EXPECTED_chassis_manufacturer=${es smb.chassisManufacturer}
    EXPECTED_chassis_version=${es smb.chassisVersion}
    EXPECTED_chassis_serial=${es smb.chassisSerial}
    EXPECTED_chassis_asset=${es smb.chassisAsset}
    EXPECTED_chassis_sku=${es smb.chassisSku}
    EXPECTED_oem_count=${toString (length smb.oemStrings)}
    ${oemEntries}
    ARGV_bios_version=${smb.biosVersion}
    ARGV_system_serial=${smb.systemSerial}
    ARGV_domain_uuid=${domainUuid}
    ARGV_board_serial=${smb.boardSerial}
    ARGV_expected_mac=${expectedMac}
    ARGV_hv_vendor_id=${hvVendorId}
  '';

  # ── The test VM ──────────────────────────────────────────────────────────
  # Enable the real kvm module's HOST config (libvirtd wiring evals in a real
  # NixOS build). guests={} so the "cpuVendor must be auto when AD on" guard
  # doesn't fire — the AD-on guest XML is produced above via the imported-lib
  # mock config (the same trusted pattern tests/guest/xml.nix uses).
  test = pkgs.testers.runNixOSTest {
    name = "anti-detection-guest-smbios";
    nodes.machine = { pkgs, lib, ... }: {
      imports = [ common.kvmTestModule ];
      environment.systemPackages = [ pkgs.libxml2 ];
    };
    # The test driver script lives in a real .py file (avoids maintaining
    # Python inside a Nix ''...'' string — no escaping issues, proper syntax
    # highlighting). Nix store paths are injected via @PLACEHOLDER@ tokens.
    testScript = replaceStrings
      [ "@PROBE_SCRIPT@" "@XML_FILE@" "@EXPECTED_VALUES@" ]
      [ "${probeScript}"  "${xmlFile}"  "${expectedValues}" ]
      (readFile ./scripts/guest-smbios-driver.py);
  };
in
  test