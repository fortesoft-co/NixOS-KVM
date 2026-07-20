{ config, lib, pkgs }:
with lib;
let
  cfg = config.cfg.kvm;
  hostLib = import ../host/lib.nix { inherit config lib pkgs; };
  cpuVendor = hostLib.cpuVendor;
  cpuSocket = hostLib.cpuSocket;

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

  # Deterministically generates a MAC address for a guest's network interface.
  # Uses the real OUI prefix of the host's selected motherboard manufacturer
  # (not the QEMU 52:54:00 prefix, which is a trivially detectable VM signature).
  # The last 3 bytes are derived from a per-interface hash so the MAC is:
  #   - deterministic (survives rebuilds)
  #   - unique per guest/interface
  #   - consistent with the SMBIOS manufacturer (NIC and board from same vendor)
  # Pinning the MAC (rather than letting libvirt auto-generate) makes `virsh
  # define` produce byte-identical stored XML every time, which the path-unit
  # revert relies on to distinguish our own writes from external edits.
  macFor =
    name: net: i:
    let
      guest = cfg.guests.${name};
      seedPrefix = cfg.host.hwidSeed;
      h = builtins.hashString "sha256" "${seedPrefix}-${guest.hwidSalt}-mac-${toString i}";
      # Use the real manufacturer OUI when anti-detection is active so the NIC
      # matches the SMBIOS manufacturer. Fall back to the standard QEMU prefix
      # when anti-detection is off (normal VM behavior).
      prefix = if guest.antiDetection.enable then
        lib.toLower (hostLib.selectManufacturer seedPrefix).oui
      else
        "52:54:00";
    in
    if net.mac != null then
      net.mac
    else
      "${prefix}:${substring 0 2 h}:${substring 2 2 h}:${substring 4 2 h}";

  # Hex helper — shared implementation lives in host/lib.nix so host-level
  # selection (manufacturer index) and guest-level derivation (UUID variant,
  # serial bytes, profile index) use the same code. Re-exported here to keep
  # the existing `inherit hexToInt` in the module's return value working.
  hexToInt = hostLib.hexToInt;

  # ───────── Motherboard Profile Selection ─────────
  # Imports the O(1) nested dictionary of real motherboard hardware profiles.
  # We filter this library down to only the boards that physically match our
  # host's CPU vendor, host's CPU socket, and the procedurally selected manufacturer.
  allProfiles = import ../host/smbios-profiles.nix;

  hostManufacturer = hostLib.selectManufacturer cfg.host.hwidSeed;

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
      m = allProfiles.${hostManufacturer.id} or {};
      v = m.${cpuVendor} or {};
      s = v.${sock} or [];
    in s;

  # If we successfully parsed matching profiles from the database, use them.
  # Otherwise, fall back to the safe defaults from the manufacturer struct.
  smbiosProfiles = if length validProfiles > 0 then validProfiles else [ fallbackProfile ];

  # ───────── XML generation ─────────

  generateXML =
    name: guest:
    let
      sdir = storageDir name guest;
      
      seedPrefix = cfg.host.hwidSeed;

      # Separate hashes per identifier — prevents correlation attacks.
      # A researcher who knows the method cannot verify UUID ↔ Serial ↔ MAC
      # are from the same source, because each uses an independent hash.
      uuidHash = builtins.hashString "sha256" "${seedPrefix}-${guest.hwidSalt}-uuid";
      serialHash = builtins.hashString "sha256" "${seedPrefix}-${guest.hwidSalt}-serial";
      profileHash = builtins.hashString "sha256" "${seedPrefix}-${guest.hwidSalt}-profile";

      # Deterministic UUID — RFC 4122 v4 compliant.
      # Version nibble forced to 4 (standard).
      # Variant nibble derived from hash (distributes across 8/9/a/b like real hardware).
      domainUuid =
        let
          p1 = substring 0 8 uuidHash;
          p2 = substring 8 4 uuidHash;
          p3 = "4${substring 13 3 uuidHash}"; # Force version 4
          variantNibble = let v = hexToInt (substring 16 1 uuidHash); in substring (lib.mod v 4) 1 "89ab";
          p4 = "${variantNibble}${substring 17 3 uuidHash}"; # Derive variant
          p5 = substring 20 12 uuidHash;
        in
        "${p1}-${p2}-${p3}-${p4}-${p5}";

      # Generates a full-alphanumeric serial (A-Z, 0-9) like real motherboards,
      # not hex-only (A-F, 0-9) which is a detectable pattern.
      alnumChars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
      byteAt = i: hexToInt (substring (i * 2) 2 serialHash);
      syntheticSerial = concatStrings (genList (i: substring (lib.mod (byteAt i) 36) 1 alnumChars) 14);

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
              <vendor_id state='on' value='${if cpuVendor == "amd" then "AuthenticAMD" else "GenuineIntel"}'/>
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
        if guest.antiDetection.smbiosMode == "manual" then
          # MANUAL MODE: Use the user-provided hardware strings from smbios.*.
          # Serial and UUID are always synthetic (never leaked from the physical host).
          {
            manufacturer = guest.smbios.manufacturer;
            product = guest.smbios.product;
            version = guest.smbios.version;
            family = guest.smbios.family;
            serial = syntheticSerial;
            uuid = domainUuid;
            sku = guest.smbios.sku;
            biosVersion = guest.smbios.biosVersion;
          }
        else
          # SYNTHETIC MODE (default): Procedurally select a motherboard profile
          # from the curated database. User smbios overrides are ignored
          # (enforced by assertions — they can't even be set in this mode).
          let
            profileSlice = substring 0 7 profileHash;
            profileIndex = lib.mod (hexToInt profileSlice) (length smbiosProfiles);
            selectedProfile = elemAt smbiosProfiles profileIndex;
          in
          {
            manufacturer = selectedProfile.manufacturer;
            product = selectedProfile.product;
            version = selectedProfile.version;
            family = selectedProfile.family;
            serial = syntheticSerial;
            uuid = domainUuid;
            sku = guest.smbios.sku;
            biosVersion = selectedProfile.biosVersion;
          }
      else
        guest.smbios // { uuid = null; biosVersion = null; }; # domain <uuid> tag handles SMBIOS UUID when antiDetection is off

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
      biosEntries = filter (s: s != "") [
        (optionalString (effectiveSmbios.manufacturer != null) "<entry name='vendor'>${effectiveSmbios.manufacturer}</entry>")
        (optionalString (effectiveSmbios.biosVersion != null) "<entry name='version'>${effectiveSmbios.biosVersion}</entry>")
      ];
      smbiosXML = optionalString (smbiosEntries != [ ]) ''
        <sysinfo type='smbios'>
          <bios>
            ${concatStrings biosEntries}
          </bios>
          <system>
            ${concatStrings smbiosEntries}
          </system>
          <baseBoard>
            ${concatStrings smbiosEntries}
          </baseBoard>
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
