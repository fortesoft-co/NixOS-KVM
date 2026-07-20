{ config, lib, pkgs }:
with lib;
let
  cfg = config.cfg.kvm;

  # ───────── Helpers ─────────

  # Resolve a guest's storage directory.
  storageDir =
    name: guest:
    if cfg.host.storage.persistentPath != null then
      "${cfg.host.storage.persistentPath}/guests/${
        if guest.storagePath != null then guest.storagePath else guest.domainName
      }"
    else
      "/var/lib/libvirt/qemu/${guest.domainName}";

  # Resolve a disk path — relative name joins with storage dir + format extension,
  # absolute paths are used as-is.
  resolveDiskPath =
    sdir: disk: if hasPrefix "/" disk.path then disk.path else "${sdir}/${disk.path}.${disk.format}";

  # Convert Proxmox/Linux BDF "0000:01:00.0" to libvirt address XML.
  pciBdfToXml =
    bdf:
    let
      parts = splitString ":" bdf;
      domain = elemAt parts 0;
      bus = elemAt parts 1;
      slotFunc = elemAt parts 2;
      sfParts = splitString "." slotFunc;
      slot = elemAt sfParts 0;
      func = elemAt sfParts 1;
    in
    "<address domain='0x${domain}' bus='0x${bus}' slot='0x${slot}' function='0x${func}'/>";

  # Generate the target dev name for a disk (vda, sdb, hdc, ...).
  indexToLetter = i: substring i 1 "abcdefghijklmnopqrstuvwxyz";
  diskDev =
    bus: index:
    let
      prefix =
        {
          virtio = "vd";
          sata = "sd";
          ide = "hd";
          scsi = "sd";
        }
        .${bus};
    in
    "${prefix}${indexToLetter index}";

  # Auto-assign boot orders: explicit orders keep their value,
  # un-set disks get assigned after the max explicit order, in list order.
  # If no disk has an explicit order, assign sequentially starting from 1.
  assignBootOrders =
    disks:
    let
      explicitMax = foldl' (acc: d: if d.boot != null && d.boot > acc then d.boot else acc) 0 disks;
      result =
        foldl'
          (
            acc: d:
            let
              nextBoot = if d.boot != null then d.boot else (acc.nextMax + 1);
              newMax = if nextBoot > acc.nextMax then nextBoot else acc.nextMax;
            in
            {
              nextMax = newMax;
              disks = acc.disks ++ [ (d // { assignedBoot = nextBoot; }) ];
            }
          )
          {
            nextMax = explicitMax;
            disks = [ ];
          }
          disks;
    in
    result.disks;

  # Deterministic MAC for a network interface — derived from the domain
  # name and interface index so it survives rebuilds. Uses the QEMU/KVM
  # locally-administered prefix 52:54:00. Pinning the MAC (rather than
  # letting libvirt auto-generate a random one) makes `virsh define`
  # produce byte-identical stored XML every time, which the path-unit
  # revert relies on to distinguish our own writes from external edits.
  # Shared by generateXML (domain XML) and mkGuestService (cloud-init
  # network-config) so both reference the exact MAC the NIC receives.
  macFor =
    name: net: i:
    let
      guest = cfg.guests.${name};
      seedPrefix = cfg.host.hwidSeed;
      h = builtins.hashString "sha256" "${seedPrefix}-${guest.domainName}-${toString i}";
    in
    if net.mac != null then
      net.mac
    else
      "52:54:00:${substring 0 2 h}:${substring 2 2 h}:${substring 4 2 h}";

  # Converts a hexadecimal string slice (up to ~14 chars max) to a Base-10 Integer.
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

  # A dictionary of authentic, consumer-grade motherboard profiles to randomize between.
  smbiosProfiles = [
    { manufacturer = "ASUSTeK COMPUTER INC."; product = "ROG STRIX B550-F GAMING"; version = "Rev X.0x"; family = "ROG System"; }
    { manufacturer = "Micro-Star International Co., Ltd."; product = "MAG B650 TOMAHAWK WIFI"; version = "1.0"; family = "MSI MB"; }
    { manufacturer = "Gigabyte Technology Co., Ltd."; product = "B650 AORUS ELITE AX"; version = "x.x"; family = "AORUS MB"; }
    { manufacturer = "ASRock"; product = "X670E Taichi"; version = "Any"; family = "ASRock MB"; }
    { manufacturer = "ASUSTeK COMPUTER INC."; product = "TUF GAMING X570-PLUS (WI-FI)"; version = "Rev X.0x"; family = "TUF System"; }
    { manufacturer = "Micro-Star International Co., Ltd."; product = "PRO Z790-A WIFI"; version = "1.0"; family = "MSI MB"; }
  ];

  # ───────── XML generation ─────────

  generateXML =
    name: guest:
    let
      sdir = storageDir name guest;
      
      seedPrefix = cfg.host.hwidSeed;
      baseHash = builtins.hashString "sha256" "${seedPrefix}-${guest.domainName}";

      # Deterministic UUID from domain name — stable across rebuilds so
      # virsh define updates the existing domain instead of creating a new one.
      domainUuid =
        let
          p1 = substring 0 8 baseHash;
          p2 = substring 8 4 baseHash;
          p3 = "4${substring 13 3 baseHash}"; # Force UUID v4 format
          p4 = "8${substring 17 3 baseHash}"; # Force RFC 4122 variant
          p5 = substring 20 12 baseHash;
        in
        "${p1}-${p2}-${p3}-${p4}-${p5}";

      # OS / firmware
      osXML =
        if guest.firmware == "uefi" then
          if guest.secureBoot then
            ''
              <os firmware='efi'>
                <type arch='${guest.architecture}' machine='${guest.machineType}'>hvm</type>
                <feature name='secure-boot'/>
              </os>''
          else
            ''
              <os firmware='efi'>
                <type arch='${guest.architecture}' machine='${guest.machineType}'>hvm</type>
              </os>''
        else
          ''
            <os>
              <type arch='${guest.architecture}' machine='${guest.machineType}'>hvm</type>
            </os>'';

      # Features
      featuresXML = ''
        <features>
          <acpi/>
          <apic/>
          ${optionalString guest.secureBoot "<smm state='on'/>"}
          ${optionalString (guest.cpu.hidden || guest.antiDetection.enable) "<kvm><hidden state='on'/></kvm>"}
          ${optionalString guest.antiDetection.enable ''
            <hyperv>
              <vendor_id state='on' value='GenuineIntel'/>
            </hyperv>
          ''}
        </features>'';

      # CPU
      topologyXML =
        if guest.cpu.sockets != null && guest.cpu.cores != null && guest.cpu.threads != null then
          "<topology sockets='${toString guest.cpu.sockets}' cores='${toString guest.cpu.cores}' threads='${toString guest.cpu.threads}'/>"
        else
          "";
      cpuModelXML =
        if guest.cpu.mode == "custom" && guest.cpu.reportedModel != null then
          "<model>${guest.cpu.reportedModel}</model>"
        else
          "";
      effectiveCpuFlags = guest.cpu.flags ++ (optionals guest.antiDetection.enable [{ name = "hypervisor"; policy = "disable"; }]);
      cpuFlagsXML = concatMapStrings (
        f: "<feature policy='${f.policy}' name='${f.name}'/>"
      ) effectiveCpuFlags;
      
      effectiveCpuMode = if guest.antiDetection.enable then "host-passthrough" else guest.cpu.mode;
      cpuXML = ''
        <cpu mode='${effectiveCpuMode}' check='none'>
          ${cpuModelXML}
          ${topologyXML}
          ${cpuFlagsXML}
        </cpu>'';

      # Hard disks + CD-ROMs (boot orders auto-assigned)
      effectiveDisks = if guest.antiDetection.enable then
        map (d: d // { 
          bus = "sata";
          # Strip VirtIO-specific performance flags that cause SATA validation failures
          iothread = null;
          aio = null;
          discard = null;
        }) guest.disks
      else
        guest.disks;
      disksWithBoot = assignBootOrders effectiveDisks;
      diskEntries = imap0 (
        i: disk:
        let
          isCdrom = disk.device == "cdrom";
          driverAttrs = concatStringsSep " " (
            filter (s: s != "") [
              "name='qemu'"
              "type='${disk.format}'"
              (optionalString (disk.cache != null) "cache='${disk.cache}'")
              (optionalString (disk.aio != null) "aio='${disk.aio}'")
              (optionalString (disk.discard != null) "discard='${disk.discard}'")
              (optionalString (disk.iothread != null) "iothread='${toString disk.iothread}'")
              (optionalString disk.ssd "ssd='yes'")
              (optionalString (disk.serial != null) "serial='${disk.serial}'")
            ]
          );
          effectiveReadOnly = disk.readOnly || isCdrom;
        in
        ''
          <disk type='file' device='${disk.device}'>
            <driver ${driverAttrs}/>
            <source file='${resolveDiskPath sdir disk}'/>
            <target dev='${diskDev disk.bus i}' bus='${disk.bus}'/>
            <boot order='${toString disk.assignedBoot}'/>
            ${optionalString effectiveReadOnly "<readonly/>"}
          </disk>''
      ) disksWithBoot;

      # Cloud-init seed ISO CD-ROM (generated at runtime in preStart).
      # No boot order — this is a data disk, not bootable media.
      # Target dev is computed based on the total number of user-defined disks.
      seedISOEntry = optionalString guest.cloudInit.enable ''
        <disk type='file' device='cdrom'>
          <driver name='qemu' type='raw'/>
          <source file='${sdir}/cloud-init-seed.iso'/>
          <target dev='${diskDev "sata" (length guest.disks)}' bus='sata'/>
          <readonly/>
        </disk>'';

      # Network interfaces
      effectiveNetworks = if guest.antiDetection.enable then
        map (n: n // { model = if n.model == "virtio" then "e1000e" else n.model; }) guest.networks
      else
        guest.networks;

      ifaceEntries = imap0 (i: net: ''
        <interface type='${net.type}'>
          ${optionalString (net.type == "bridge") "<source bridge='${net.source}'/>"}
          ${optionalString (net.type == "network") "<source network='${net.source}'/>"}
          ${optionalString (net.type == "direct") "<source dev='${net.source}' mode='bridge'/>"}
          <mac address='${macFor name net i}'/>
          <model type='${net.model}'/>
        </interface>'') effectiveNetworks;

      # PCI passthrough
      pciEntries = map (dev: ''
        <hostdev mode='subsystem' type='pci' managed='yes'>
          <driver name='vfio-pci'/>
          <source>
            ${pciBdfToXml dev.id}
          </source>
          ${optionalString (!dev.romBar) "<rom bar='off'/>"}
        </hostdev>'') guest.passthrough.pci;

      # USB 3.0 controller — added once if any USB passthrough device requests usb3.
      hasUsb3 = any (dev: dev.usb3) guest.passthrough.usb;
      usbControllerXML = optionalString hasUsb3 "<controller type='usb' model='qemu-xhci'/>";

      # USB passthrough
      usbEntries = map (dev: ''
        <hostdev mode='subsystem' type='usb' managed='yes'>
          <source>
            <vendor id='0x${dev.vendor}'/>
            <product id='0x${dev.product}'/>
          </source>
        </hostdev>'') guest.passthrough.usb;

      # TPM
      tpmEntry = optionalString guest.tpm.enable ''
        <tpm model='${guest.tpm.model}'>
          <backend type='emulator' version='${guest.tpm.version}'/>
        </tpm>'';

      # Graphics
      listenAddr = if guest.graphics.listen != null then guest.graphics.listen else "127.0.0.1";
      portAttr =
        if guest.graphics.port != null then "port='${toString guest.graphics.port}'" else "autoport='yes'";
      graphicsEntry =
        if guest.paravirtGraphics.enable then
          ""
        else if guest.graphics.type == "none" then
          ""
        else
          let
            spiceExtras = optionalString (guest.graphics.type == "spice") ''
              ${optionalString guest.graphics.clipboard "<clipboard copypaste='yes'/>"}
              ${optionalString guest.graphics.fileTransfer "<filetransfer enable='yes'/>"}'';
          in
          ''
            <graphics type='${guest.graphics.type}' ${portAttr} listen='${listenAddr}'>
              <listen type='address' address='${listenAddr}'/>
              ${spiceExtras}
            </graphics>'';

      # Input devices
      # If antiDetection is enabled, we completely avoid adding explicit USB tablets
      # since libvirt will default to PS/2 which is stealthier than VirtIO/USB descriptors.
      inputEntries = if guest.antiDetection.enable then
        (optional guest.input.keyboard "<input type='keyboard' bus='ps2'/>")
        ++ (optional guest.input.mouse "<input type='mouse' bus='ps2'/>")
      else
        (optional guest.input.tablet "<input type='tablet' bus='usb'/>")
        ++ (optional guest.input.keyboard "<input type='keyboard' bus='ps2'/>")
        ++ (optional guest.input.mouse "<input type='mouse' bus='ps2'/>");

      # Video
      # Anti-Detection: Avoid QXL and VirtIO, fallback to generic VGA if no proxying is used
      effectiveVideoModel = if guest.antiDetection.enable && guest.video.model == "qxl" then
        "vga"
      else if guest.antiDetection.enable && guest.video.model == "virtio" then
        "vga"
      else
        guest.video.model;

      videoEntry =
        if guest.paravirtGraphics.enable then
          ""
        else if guest.graphics.type == "none" && effectiveVideoModel == "qxl" then
          "<video><model type='none'/></video>"
        else
          "<video><model type='${effectiveVideoModel}' heads='${toString guest.video.heads}'/></video>";

      # Clock
      clockXML =
        let
          attrs =
            if guest.clock.offset == "timezone" then
              "offset='timezone' timezone='${guest.clock.timezone}'"
            else if guest.clock.offset == "variable" then
              "offset='variable' adjustment='${toString guest.clock.adjustment}'"
            else
              "offset='${guest.clock.offset}'";
        in
        "<clock ${attrs}/>";

      # SMBIOS
      effectiveSmbios = if guest.antiDetection.enable then
        let
          syntheticSerial = toUpper (substring 32 14 baseHash);
          
          # Procedurally select a Motherboard Profile from the dictionary
          slice = substring 46 7 baseHash;
          profileIndex = lib.mod (hexToInt slice) (length smbiosProfiles);
          selectedProfile = elemAt smbiosProfiles profileIndex;
        in
        {
          manufacturer = if guest.smbios.manufacturer != null then guest.smbios.manufacturer else selectedProfile.manufacturer;
          product = if guest.smbios.product != null then guest.smbios.product else selectedProfile.product;
          version = if guest.smbios.version != null then guest.smbios.version else selectedProfile.version;
          family = if guest.smbios.family != null then guest.smbios.family else selectedProfile.family;
          serial = if guest.smbios.serial != null then guest.smbios.serial else syntheticSerial;
          uuid = domainUuid;
          sku = guest.smbios.sku;
        }
      else
        guest.smbios;

      smbiosEntries = filter (s: s != "") [
        (optionalString (
          effectiveSmbios.manufacturer != null
        ) "<entry name='manufacturer'>${effectiveSmbios.manufacturer}</entry>")
        (optionalString (
          effectiveSmbios.product != null
        ) "<entry name='product'>${effectiveSmbios.product}</entry>")
        (optionalString (
          effectiveSmbios.version != null
        ) "<entry name='version'>${effectiveSmbios.version}</entry>")
        (optionalString (effectiveSmbios.serial != null) "<entry name='serial'>${effectiveSmbios.serial}</entry>")
        (optionalString (effectiveSmbios.uuid != null) "<entry name='uuid'>${effectiveSmbios.uuid}</entry>")
        (optionalString (effectiveSmbios.family != null) "<entry name='family'>${effectiveSmbios.family}</entry>")
        (optionalString (effectiveSmbios.sku != null) "<entry name='sku'>${effectiveSmbios.sku}</entry>")
      ];
      smbiosXML = optionalString (smbiosEntries != [ ]) ''
        <sysinfo type='smbios'>
          <system>
            ${concatStrings smbiosEntries}
          </system>
        </sysinfo>'';

      # Serial console
      serialXML = optionalString guest.serial.enable (
        if guest.serial.port != null then
          ''
            <serial type='tcp'>
              <source mode='bind' host='127.0.0.1' service='${toString guest.serial.port}'/>
              <target port='0'/>
            </serial>
            <console type='tcp'>
              <source mode='bind' host='127.0.0.1' service='${toString guest.serial.port}'/>
              <target type='serial' port='0'/>
            </console>''
        else
          ''
            <serial type='pty'>
              <target port='0'/>
            </serial>
            <console type='pty'>
              <target type='serial' port='0'/>
            </console>''
      );

      # Audio
      audioXML = optionalString guest.audio.enable "<sound model='${guest.audio.model}'/>";

      # VirtIO RNG
      rngRateXML =
        if guest.rng.rateBytes != null && guest.rng.ratePeriod != null then
          "<rate bytes='${toString guest.rng.rateBytes}' period='${toString guest.rng.ratePeriod}'/>"
        else
          "";
      rngXML = optionalString (guest.rng.enable && !guest.antiDetection.enable) ''
        <rng model='virtio'>
          ${rngRateXML}
          <backend model='random'>/dev/urandom</backend>
        </rng>'';

      # Hardware watchdog
      watchdogXML = optionalString guest.watchdog.enable "<watchdog model='${guest.watchdog.model}' action='${guest.watchdog.action}'/>";

      # QEMU guest agent
      agentXML = optionalString (guest.agent.enable && !guest.antiDetection.enable) ''
        <channel type='unix'>
          <target type='virtio' name='org.qemu.guest_agent.0'/>
        </channel>'';

      # IOThreads — auto-create from the highest iothread number used by any disk
      maxIothread = foldl' (
        acc: disk: if disk.iothread != null && disk.iothread > acc then disk.iothread else acc
      ) 0 guest.disks;
      iothreadsXML = optionalString (maxIothread > 0) "<iothreads>${toString maxIothread}</iothreads>";

      # Extra QEMU args
      effectiveQemuArgs = if guest.paravirtGraphics.enable then
        guest.extraQemuArgs ++ [
          "-display" "egl-headless,rendernode=/dev/dri/renderD128"
          "-device" "virtio-vga-gl,blob=on,${guest.paravirtGraphics.backend}=on,hostmem=1024M"
        ]
      else
        guest.extraQemuArgs;

      qemuCmdline = optionalString (effectiveQemuArgs != [ ]) ''
        <qemu:commandline>
          ${concatMapStrings (a: "<qemu:arg value='${a}'/>") effectiveQemuArgs}
        </qemu:commandline>'';

      # Domain type attribute — use qemu namespace if we have extra args
      domainAttrs = optionalString (
        effectiveQemuArgs != [ ]
      ) " xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'";
    in
    ''
      <domain type='kvm'${domainAttrs}>
        <name>${guest.domainName}</name>
        <uuid>${domainUuid}</uuid>
        <description>DECLARATIVELY MANAGED by NixOS (cfg.kvm.guests.${name}). Edits made here (virsh edit / virt-manager) are automatically reverted to the Nix-defined config within seconds and will NOT take effect. To change this VM, edit the NixOS configuration and run `nixos-rebuild switch`. (virt-manager may briefly show a stale edited config for a running VM even after it has been reverted; the real configuration is always the Nix one — verify with `virsh dumpxml ${guest.domainName}`.)</description>
        <memory unit='MiB'>${toString guest.memory}</memory>
        <vcpu>${toString guest.vcpus}</vcpu>
        ${iothreadsXML}
        ${osXML}
        ${featuresXML}
        ${smbiosXML}
        ${cpuXML}
        ${clockXML}
        <devices>
          ${iothreadsXML}
          ${concatStrings diskEntries}
          ${seedISOEntry}
          ${concatStrings ifaceEntries}
          ${usbControllerXML}
          ${concatStrings pciEntries}
          ${concatStrings usbEntries}
          ${tpmEntry}
          ${graphicsEntry}
          ${concatStringsSep "\n          " inputEntries}
          ${videoEntry}
          ${serialXML}
          ${audioXML}
          ${rngXML}
          ${watchdogXML}
          ${agentXML}
          ${optionalString guest.antiDetection.enable "<memballoon model='none'/>"}
        </devices>
        ${optionalString (guest.extraXML != null) guest.extraXML}
        ${qemuCmdline}
      </domain>'';

in
{
  inherit storageDir resolveDiskPath pciBdfToXml diskDev assignBootOrders macFor hexToInt smbiosProfiles generateXML;
}
