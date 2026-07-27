# Layer 3 (unpatched) SMBIOS guest-OS boot test — Option B.
#
# Option A (guest-smbios.nix) proved via libvirt's PURE argv computation that
# every SMBIOS/NIC/CPU value the module produces would REACH QEMU. It did NOT
# boot the AD-on guest — `virsh domxml-to-native` computes the QEMU command line
# without starting QEMU. This test closes that gap: it boots a real (minimal)
# NixOS guest UNDER libvirt with the AD-on XML, runs the first-party probe sweep
# from INSIDE the guest (dmidecode / /sys/class/dmi/id / lscpu / ip link / lspci
# / acpi tables / block models), gets the results back to the host, and diffs
# against the same expected-value harness Option A uses (shared via common.nix).
#
# This is the only test that catches the rare class where QEMU/SeaBIOS silently
# IGNORES a passed `-smbios` block — the firmware tables the guest OS reads via
# dmidecode / sysfs would not match what libvirt put on the QEMU command line.
#
# Requires nested KVM: the module emits <domain type='kvm'>, which requires
# /dev/kvm inside the test VM. The test VM gets /dev/kvm when the build host has
# KVM + nested virt enabled. We HARD-FAIL if /dev/kvm is missing (CI without
# nested KVM will fail loudly rather than silently skip — per the user's call).
#
# Machine-independence: same explicit fixture as Option A (hwidSeed/hwidSalt/
# cpuVendor/cpuSocket in common.nix). The guest image build uses the same
# make-disk-image.nix machinery the NixOS test framework uses for its own nodes.
#
# Scripts are extracted into ./scripts/ to avoid maintaining shell/Python inside
# Nix ''...'' strings (escaping issues, no syntax highlighting):
#   scripts/guest-smbios-boot-guest-probe.sh  — runs inside the booted guest
#   scripts/guest-smbios-boot-results-diff.sh — host-side diff harness (static)
#   scripts/guest-smbios-boot-driver.py       — test driver (Python, @PLACEHOLDER@ tokens)
#
# Standalone build:
#   nix build .#checks.x86_64-linux.anti-detection-guest-smbios-boot --no-link
{ lib, pkgs }:
with lib;
let
  common = import ./common.nix { inherit lib pkgs; };
  inherit (common)
    hwidSeed hwidSalt cpuVendor cpuSocket
    baseGuest generateXML kvmTestModule
    smb domainUuid expectedMac es;

  # Option B adds a real boot disk (the NixOS qcow2 built below) and a raw
  # results disk to the base guest, and switches the NIC to the libvirt default
  # network (the test VM has no br0 bridge). AD-on forces SATA bus + e1000e NIC
  # regardless of what we set here, so the guest sees /dev/sda (boot) + /dev/sdb
  # (results) and an e1000e interface with the expected MAC.
  fullGuest = baseGuest // {
    vcpus = 1;
    memory = 1024;
    disks = [
      { path = "/var/lib/libvirt/images/adon.qcow2"; format = "qcow2"; device = "disk"; bus = "virtio"; boot = null; cache = null; aio = null; discard = null; iothread = null; ssd = false; serial = null; readOnly = false; size = null; sourceUrl = null; }
      { path = "/var/lib/libvirt/images/adon-results.raw"; format = "raw"; device = "disk"; bus = "virtio"; boot = null; cache = null; aio = null; discard = null; iothread = null; ssd = false; serial = null; readOnly = false; size = null; sourceUrl = null; }
    ];
    networks = [ { type = "network"; source = "default"; model = "virtio"; mac = null; } ];
  };

  generatedXML = generateXML "adon" fullGuest;
  xmlFile = pkgs.writeText "kvm-guest-adon-boot.xml" generatedXML;

  # ── Scripts (extracted into ./scripts/ for maintainability) ──────────────
  # Pure shell, read via readFile — no '' escaping issues, proper highlighting.
  guestProbe = pkgs.writeShellScript "guest-smbios-boot-guest-probe"
    (readFile ./scripts/guest-smbios-boot-guest-probe.sh);
  diffHarness = pkgs.writeShellScript "guest-smbios-boot-results-diff"
    (readFile ./scripts/guest-smbios-boot-results-diff.sh);

  # Expected-values file: shell-sourceable assignments generated from the same
  # common.nix expected-value harness Option A uses. The diff harness sources
  # this at runtime, keeping the shell script completely static.
  expectedValues = pkgs.writeText "guest-smbios-boot-expected-values.sh" ''
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
  '';

  # ── Minimal NixOS guest (BIOS-bootable qcow2) ────────────────────────────
  # Built via make-disk-image.nix — the same machinery the NixOS test framework
  # uses for its own per-node disk images. BIOS boot (image.efiSupport = false)
  # to match the fixture's firmware = "bios". The guest boots under libvirt,
  # runs guestProbe, writes output to the raw results disk, then powers off.
  guestEval = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = "x86_64-linux";
    modules = [
      "${pkgs.path}/nixos/modules/virtualisation/disk-image.nix"
      {
        image.baseName = "adon";
        image.format = "qcow2";
        image.efiSupport = false;  # BIOS — matches fixture firmware="bios"
        virtualisation.diskSize = "auto";  # calculated from closure + 512M slack

        environment.systemPackages = with pkgs; [
          dmidecode pciutils iproute2 util-linux
        ];

        # Silence getty spam on serial/console — we transport results via a
        # raw disk, not serial, and spam would clutter the results disk if the
        # probe wrote to a tty instead.
        systemd.services."serial-getty@ttyS0".enable = false;
        systemd.services."getty@tty1".enable = false;
        systemd.services."autovt@".enable = false;

        # The probe service: runs after multi-user.target, writes the probe
        # output to the raw results disk, syncs, powers off. The results disk
        # is the second SATA disk (AD-on forces SATA bus: sda=boot, sdb=results).
        # We try /dev/sdb first, fall back to /dev/vdb in case bus assignment
        # differs on a future libvirt/qemu.
        systemd.services.adon-probe = {
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
            ${guestProbe} > "$RESULTS_DEV"
            sync
            poweroff
          '';
        };
      }
    ];
  };

  guestImage = guestEval.config.system.build.image;

  # ── The test VM (libvirtd host with nested KVM) ──────────────────────────
  test = pkgs.testers.runNixOSTest {
    name = "anti-detection-guest-smbios-boot";
    nodes.machine = { pkgs, lib, ... }: {
      # Nested KVM needs enough cores + memory for the inner guest. The AD-on
      # guest requests 1 vCPU / 1024 MiB; the test VM itself needs headroom.
      virtualisation.cores = 2;
      virtualisation.memorySize = 4096;
      imports = [ common.kvmTestModule ];
      environment.systemPackages = with pkgs; [ libvirt dmidecode ];
    };
    # The test driver script lives in a real .py file (avoids maintaining
    # Python inside a Nix ''...'' string — no escaping issues, proper syntax
    # highlighting). Nix store paths are injected via @PLACEHOLDER@ tokens.
    testScript = let
      guestImagePath = "${guestImage}/${guestEval.config.image.fileName}";
    in replaceStrings
      [ "@GUEST_IMAGE@" "@XML_FILE@" "@DIFF_HARNESS@" "@EXPECTED_VALUES@" ]
      [ guestImagePath      "${xmlFile}"  "${diffHarness}" "${expectedValues}" ]
      (readFile ./scripts/guest-smbios-boot-driver.py);
  };
in
test