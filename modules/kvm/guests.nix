{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.cfg.kvm;

  # Guests that are enabled — used to generate per-guest services and the
  # XML-edit watch units. Defined once here so the filter isn't repeated.
  enabledGuests = filterAttrs (_: g: g.enable) cfg.guests;

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

  # ───────── Systemd service generation ─────────

  mkGuestService =
    name: guest:
    let
      xml = generateXML name guest;
      xmlFile = pkgs.writeText "kvm-guest-${name}.xml" xml;
      sdir = storageDir name guest;

      virsh = "${config.virtualisation.libvirtd.package}/bin/virsh";
      qemuImg = "${config.virtualisation.libvirtd.qemu.package}/bin/qemu-img";

      # Create disk images if they don't exist.
      # - CD-ROMs with sourceUrl: download but don't resize (ISOs are fixed-size).
      # - CD-ROMs without sourceUrl: skip creation (empty CD-ROM or error).
      # - Disks with sourceUrl: download and resize if `size` is set.
      # - Disks without sourceUrl: create empty with `qemu-img create`.
      diskCreation = concatMapStrings (
        disk:
        let
          p = resolveDiskPath sdir disk;
          isCdrom = disk.device == "cdrom";
        in
        if isCdrom then
          if disk.sourceUrl != null then
            ''
              path="${p}"
              if [ ! -e "$path" ]; then
                echo "Downloading CD-ROM image: ${disk.sourceUrl}"
                ${pkgs.curl}/bin/curl -LfS -o "$path" "${disk.sourceUrl}"
              fi
            ''
          else
            ""
        else if disk.sourceUrl != null then
          ''
            path="${p}"
            if [ ! -e "$path" ]; then
              echo "Downloading disk image: ${disk.sourceUrl}"
              ${pkgs.curl}/bin/curl -LfS -o "$path" "${disk.sourceUrl}"
              ${optionalString (disk.size != null) ''
                echo "Resizing disk image to ${disk.size}"
                              ${qemuImg} resize "$path" ${disk.size}''}
            fi
          ''
        else
          ''
            path="${p}"
            if [ ! -e "$path" ]; then
              echo "Creating disk image: $path (${disk.size})"
              ${qemuImg} create -f ${disk.format} "$path" ${disk.size}
            fi
          ''
      ) guest.disks;

      # Generate cloud-init seed ISO (at runtime, to inject decrypted password).
      ci = guest.cloudInit;
      cloudInitPasswordSecret = "kvm-guest-${name}-cloudinit-password";
      cloudInitPasswordPath = optionalString (
        ci.passwordAgePath != null
      ) config.age.secrets.${cloudInitPasswordSecret}.path;
      # Build user-data YAML (password section added at runtime if needed).
      userDataYaml = concatStringsSep "\n" (
        [
          "#cloud-config"
          "hostname: ${ci.hostname}"
        ]
        ++ [
          "users:"
          "  - name: ${ci.user}"
          "    sudo: ALL=(ALL) NOPASSWD:ALL"
          "    groups: sudo"
          "    shell: /bin/bash"
        ]
        ++ [
          "    lock_passwd: ${
                if ci.passwordAgePath == null && ci.sshAuthorizedKeys != [ ] then "true" else "false"
              }"
        ]
        ++ (
          if ci.sshAuthorizedKeys != [ ] then
            [ "    ssh_authorized_keys:" ] ++ (map (k: "      - ${k}") ci.sshAuthorizedKeys)
          else
            [ ]
        )
        ++ (if ci.packages != [ ] then [ "packages:" ] ++ (map (p: "  - ${p}") ci.packages) else [ ])
        ++ (if ci.runcmd != [ ] then [ "runcmd:" ] ++ (map (c: "  - ${c}") ci.runcmd) else [ ])
        ++ (if ci.extraConfig != "" then [ ci.extraConfig ] else [ ])
        ++ (
          if ci.passwordAgePath == null && ci.sshAuthorizedKeys == [ ] then
            # No password and no SSH keys — default to username as password.
            [
              ""
              "chpasswd:"
              "  list: |"
              "    ${ci.user}:${ci.user}"
              "  expire: false"
            ]
          else
            [ ]
        )
      );

      # Network configuration for cloud-init (netplan v2). When the user
      # provides ci.networkConfig, use it verbatim (static IPs, custom setup
      # — their intent). Otherwise generate a config that enables DHCP on
      # each declared interface, matched by its deterministic MAC so
      # cloud-init always configures the NIC that matches the MAC the VM
      # actually receives — even if the VM name (and thus the MAC) changes
      # between rebuilds.
      networkConfigYaml =
        if ci.networkConfig != null then
          ci.networkConfig
        else if guest.networks == [ ] then
          ""
        else
          concatStringsSep "\n" (
            [
              "version: 2"
              "ethernets:"
            ]
            ++ concatLists (
              imap0 (
                i: net:
                let
                  m = macFor name net i;
                in
                [
                  "  n${toString i}:"
                  "    match:"
                  "      macaddress: ${m}"
                  "    dhcp4: true"
                ]
              ) guest.networks
            )
          );

      seedISOCreation = optionalString ci.enable ''
        seedDir=$(mktemp -d)
        cat > "$seedDir/user-data" <<'CLOUDCFG'
        ${userDataYaml}
        CLOUDCFG
        ${optionalString (ci.passwordAgePath != null) ''
          echo "" >> "$seedDir/user-data"
          echo "chpasswd:" >> "$seedDir/user-data"
          echo "  list: |" >> "$seedDir/user-data"
          echo "    ${ci.user}:$(cat ${cloudInitPasswordPath})" >> "$seedDir/user-data"
          echo "  expire: false" >> "$seedDir/user-data"
        ''}
        cat > "$seedDir/meta-data" <<'METADATA'
        instance-id: ${guest.domainName}
        local-hostname: ${ci.hostname}
        METADATA
        ${optionalString (networkConfigYaml != "") ''
          cat > "$seedDir/network-config" <<'NETCFG'
          ${networkConfigYaml}
          NETCFG
        ''}
        ${pkgs.cdrtools}/bin/mkisofs -quiet -output "${sdir}/cloud-init-seed.iso" \
          -volid cidata -joliet -rock "$seedDir/"
        rm -rf "$seedDir"
      '';

      # Graphics password setup via agenix (if configured).
      passwordSecret = "kvm-guest-${name}-graphics-password";
      graphicsPasswordSetup = optionalString (guest.graphics.passwordAgePath != null) ''
        # Set graphics password from decrypted age secret
        ${virsh} qemu-monitor-command ${guest.domainName} -- \
          "{\"execute\": \"set_password\", \"arguments\": {\"protocol\": \"${guest.graphics.type}\", \"password\": \"$(cat ${
            config.age.secrets.${passwordSecret}.path
          })\"}}" \
          2>/dev/null || true
      '';
    in
    {
      description = "KVM guest: ${name}";

      wantedBy = optional guest.autoStart "multi-user.target";

      after = [
        "libvirtd.service"
        "kvm-cleanup.service"
      ]
      ++ map (g: "kvm-guest-${g}.service") guest.dependsOn;
      requires = [ "libvirtd.service" ] ++ map (g: "kvm-guest-${g}.service") guest.dependsOn;

      path = [
        config.virtualisation.libvirtd.package
        config.virtualisation.libvirtd.qemu.package
        pkgs.cdrtools
      ];

      preStart = ''
        # Ensure storage directory exists
        mkdir -p "${sdir}"

        ${optionalString guest.paravirtGraphics.enable ''
          # Validate host-side permissions for direct rendering node
          if [ ! -r /dev/dri/renderD128 ] || [ ! -w /dev/dri/renderD128 ]; then
            echo "ERROR: Missing read/write privileges to /dev/dri/renderD128. Paravirtualized Graphics cannot initialize." >&2
            exit 1
          fi
        ''}

        # Create disk images / download CD-ROMs if missing (existing disks are never recreated)
        ${diskCreation}

        # Generate cloud-init seed ISO if enabled
        ${seedISOCreation}

        # Define (or redefine) the domain with libvirt
        ${virsh} define --file "${xmlFile}"

        # Record the stored XML hash so the per-guest watch service can tell
        # our own defines apart from imperative edits (virsh edit /
        # virt-manager). libvirt rewrites the file on every define even when
        # the content is unchanged, so we key on content (sha256), not mtime.
        mkdir -p /var/lib/kvm-sync
        sha256sum /var/lib/libvirt/qemu/${guest.domainName}.xml | cut -d' ' -f1 > /var/lib/kvm-sync/${guest.domainName}.hash
      '';

      script = ''
        # Only start if not already running (avoids error on service restart)
        if ${virsh} domstate ${guest.domainName} 2>/dev/null | grep -q "running"; then
          echo "Domain ${guest.domainName} is already running"
        else
          ${virsh} start ${guest.domainName}
        fi
      '';

      postStart = graphicsPasswordSetup;

      preStop = ''
        ${virsh} shutdown ${guest.domainName} || \
        ${virsh} destroy ${guest.domainName} || true
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStopSec = 120;
      };
    };

  # ───────── XML-edit watch (per guest) ─────────
  # Replaces the old nix-sync hook. A systemd path unit watches each guest's
  # stored libvirt domain XML; on change, the watch service compares the
  # current sha256 against the hash saved after our own `virsh define`. Equal
  # → our own (or libvirt's) write, skip. Differ → an imperative edit (virsh
  # edit / virt-manager) reverted by re-defining from the Nix-generated XML,
  # and the new hash is saved. libvirt always rewrites the file on define, so
  # the hash (not mtime) is what breaks the feedback loop.
  mkWatchService =
    name: guest:
    let
      xml = generateXML name guest;
      xmlFile = pkgs.writeText "kvm-guest-${name}-revert.xml" xml;
      virsh = "${config.virtualisation.libvirtd.package}/bin/virsh";
      storedXml = "/var/lib/libvirt/qemu/${guest.domainName}.xml";
      hashFile = "/var/lib/kvm-sync/${guest.domainName}.hash";
    in
    {
      description = "Revert imperative edits to KVM guest: ${name}";
      after = [ "kvm-guest-${name}.service" ];
      partOf = [ "kvm-guest-${name}.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        if [ ! -f ${storedXml} ]; then exit 0; fi
        current=$(sha256sum ${storedXml} | cut -d' ' -f1)
        saved=$(cat ${hashFile} 2>/dev/null || echo "")
        if [ "$current" = "$saved" ]; then
          exit 0
        fi
        echo "kvm-watch: reverting imperative edit to domain ${guest.domainName}"
        ${virsh} define --file "${xmlFile}"
        sha256sum ${storedXml} | cut -d' ' -f1 > ${hashFile}
      '';
    };

  mkWatchPath =
    name: guest: {
      description = "Watch ${name}'s libvirt domain XML for imperative edits";
      wantedBy = [ "multi-user.target" ];
      after = [ "libvirtd.service" ];
      partOf = [ "kvm-guest-${name}.service" ];
      pathConfig.PathChanged = "/var/lib/libvirt/qemu/${guest.domainName}.xml";
    };
in
{
  config = mkMerge [
    # ───────── Orphan cleanup (always active when module is imported) ─────────
    # Removes libvirt domains that are no longer declared in cfg.kvm.guests.
    # Preserves NVRAM and TPM state so re-adding a guest recovers its UEFI vars.
    {
      systemd.services.kvm-cleanup = {
        description = "Remove orphaned KVM guest definitions";
        after = [ "libvirtd.service" ];
        requires = [ "libvirtd.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ config.virtualisation.libvirtd.package ];
        script =
          let
            declaredGuests = mapAttrsToList (n: g: g.domainName) (filterAttrs (_: g: g.enable) cfg.guests);
            declaredStr = concatStringsSep " " declaredGuests;
          in
          ''
            # Wait for libvirtd to be fully ready
            sleep 2

            DECLARED="${declaredStr}"

            for domain in $(virsh list --all --name 2>/dev/null || true); do
              if echo " $DECLARED " | grep -qw "$domain"; then
                : # domain is declared, keep it
              else
                echo "kvm-cleanup: removing orphaned domain: $domain"
                # --managed-save: remove managed save state (otherwise undefine fails)
                # --keep-nvram: preserve UEFI NVRAM variables
                # --keep-tpm: preserve emulated TPM state
                virsh undefine "$domain" --managed-save --keep-nvram --keep-tpm 2>/dev/null || \
                virsh undefine "$domain" --managed-save --keep-nvram 2>/dev/null || \
                virsh undefine "$domain" --managed-save 2>/dev/null || \
                virsh undefine "$domain" 2>/dev/null || true
              fi
            done
          '';
      };

    }

    # ───────── Per-guest services, secrets, and assertions ─────────
    (mkIf (cfg.guests != { }) {
      systemd.services =
        mapAttrs' (n: g: nameValuePair "kvm-guest-${n}" (mkGuestService n g)) enabledGuests
        // mapAttrs' (n: g: nameValuePair "kvm-guest-${n}-watch" (mkWatchService n g)) enabledGuests;

      systemd.paths = mapAttrs' (
        n: g: nameValuePair "kvm-guest-${n}-watch" (mkWatchPath n g)
      ) enabledGuests;

      # ───────── Secrets via agenix (graphics + cloud-init passwords) ─────────
      age.secrets = mkIf ((filterAttrs (_: g: g.graphics.passwordAgePath != null || (g.cloudInit.enable && g.cloudInit.passwordAgePath != null)) enabledGuests) != {}) (mkMerge (
        mapAttrsToList (
          name: guest:
          (optionalAttrs (guest.graphics.passwordAgePath != null) {
            "kvm-guest-${name}-graphics-password" = {
              file = guest.graphics.passwordAgePath;
            };
          })
          // (optionalAttrs (guest.cloudInit.enable && guest.cloudInit.passwordAgePath != null) {
            "kvm-guest-${name}-cloudinit-password" = {
              file = guest.cloudInit.passwordAgePath;
            };
          })
        ) (filterAttrs (_: g: g.enable) cfg.guests)
      ));

      # ───────── Assertions ─────────
      assertions =
        let
          # Duplicate PCI passthrough across guests
          allPciIds = concatLists (
            mapAttrsToList (_: g: map (d: d.id) g.passthrough.pci) (filterAttrs (_: g: g.enable) cfg.guests)
          );
          
          # Duplicate domainNames across guests
          allDomainNames = mapAttrsToList (_: g: g.domainName) (filterAttrs (_: g: g.enable) cfg.guests);
        in
        [
          {
            assertion = unique allDomainNames == allDomainNames;
            message = "Domain name conflict: multiple guests share the same domainName. Each guest MUST have a globally unique domainName.";
          }
          {
            assertion = unique allPciIds == allPciIds;
            message = ''
              PCI device passthrough conflict: a PCI device is assigned to multiple
              guests. Check all guests' passthrough.pci entries for duplicates.
            '';
          }
        ]
        ++
          # Per-guest assertions
          flatten (
            mapAttrsToList (
              name: g:
              if !g.enable then
                [ ]
              else
                [
                  {
                    assertion = builtins.match "^[a-zA-Z0-9_-]{3,32}$" g.domainName != null;
                    message = "Guest ${name}: domainName '${g.domainName}' is invalid. It must be 3-32 characters long and contain only alphanumeric characters, hyphens, and underscores.";
                  }
                  {
                    assertion = !(g.secureBoot && g.firmware != "uefi");
                    message = "Guest ${name}: secureBoot requires firmware = \"uefi\".";
                  }
                  {
                    assertion = !(g.secureBoot && !g.tpm.enable);
                    message = "Guest ${name}: secureBoot requires tpm.enable = true.";
                  }
                  {
                    assertion = !(g.graphics.type == "none" && g.graphics.passwordAgePath != null);
                    message = "Guest ${name}: graphics.passwordAgePath requires graphics.type != \"none\".";
                  }
                  # CPU topology — all or none, and product must match vcpus
                  {
                    assertion =
                      (g.cpu.sockets != null) == (g.cpu.cores != null)
                      && (g.cpu.cores != null) == (g.cpu.threads != null);
                    message = "Guest ${name}: cpu.sockets, cpu.cores, and cpu.threads must all be set or all be null.";
                  }
                  {
                    assertion = g.cpu.sockets == null || g.cpu.sockets * g.cpu.cores * g.cpu.threads == g.vcpus;
                    message = "Guest ${name}: cpu.sockets * cpu.cores * cpu.threads must equal vcpus (${toString g.vcpus}).";
                  }
                  # reportedModel only meaningful for custom mode
                  {
                    assertion = !(g.cpu.reportedModel != null && g.cpu.mode != "custom");
                    message = "Guest ${name}: cpu.reportedModel requires cpu.mode = \"custom\".";
                  }
                  # Clock — timezone/adjustment require matching offset
                  {
                    assertion = !(g.clock.timezone != null && g.clock.offset != "timezone");
                    message = "Guest ${name}: clock.timezone requires clock.offset = \"timezone\".";
                  }
                  {
                    assertion = !(g.clock.adjustment != null && g.clock.offset != "variable");
                    message = "Guest ${name}: clock.adjustment requires clock.offset = \"variable\".";
                  }
                  # Anti-Detection — enforce valid user overrides
                  {
                    assertion = !(
                      g.antiDetection.enable && 
                      (g.smbios.manufacturer != null || g.smbios.product != null || g.smbios.version != null || g.smbios.family != null) &&
                      !(g.smbios.manufacturer != null && g.smbios.product != null && g.smbios.version != null && g.smbios.family != null)
                    );
                    message = "Guest ${name}: antiDetection is enabled. If you override any of the base SMBIOS fields (manufacturer, product, version, or family), you must provide ALL of them to avoid a mismatched hardware profile.";
                  }
                  # HWID Seed — universally enforce presence and UUID format
                  {
                    assertion = cfg.host.hwidSeed != null && builtins.match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" cfg.host.hwidSeed != null;
                    message = "Guest ${name} requires cfg.kvm.host.hwidSeed to be set to a valid 36-character UUID. Please open a terminal, run `uuidgen`, and paste the output into your host configuration. This guarantees your VM's Hardware IDs and MAC addresses survive host reinstalls.";
                  }
                  # Anti-Detection — Guide-rail for QEMU patching
                  {
                    assertion = !g.antiDetection.patchQemu;
                    message = ''
                      Guest ${name}: 'antiDetection.patchQemu' cannot be set on a per-guest basis. 
                      Because Libvirt relies on a single heavily-wrapped QEMU binary for all virtual machines, 
                      patching QEMU is a global, host-wide operation. 
                      
                      To apply the anti-detection QEMU patches, please remove this option from your guest 
                      config and set `cfg.kvm.host.antiDetection.patchQemu = true` in your host configuration instead.
                      (Note: This will trigger a source compilation of QEMU on your host and will apply to all VMs).
                    '';
                  }
                  # RNG rate limiting — both bytes and period must be set together
                  {
                    assertion = (g.rng.rateBytes != null) == (g.rng.ratePeriod != null);
                    message = "Guest ${name}: rng.rateBytes and rng.ratePeriod must both be set or both be null.";
                  }
                ]
            ) cfg.guests
          );
    })

    # ───────── virt-viewer desktop shortcuts (per guest) ─────────
    # One .desktop entry per enabled guest, launching
    # `virt-viewer --connect qemu:///system <name>`. Only generated when the
    # GUI tools are installed (cfg.host.tools.gui). virt-viewer opens a
    # monitor (read-only) connection, so these shortcuts work for both
    # manage- and monitor-scope users.
    (mkIf (cfg.host.tools.gui && enabledGuests != { }) {
      environment.systemPackages = [
        (pkgs.symlinkJoin {
          name = "kvm-guest-launchers";
          paths = mapAttrsToList (
            name: _:
            pkgs.writeTextDir "share/applications/kvm-guest-${name}.desktop" ''
              [Desktop Entry]
              Type=Application
              Name=VM: ${name}
              Exec=virt-viewer --connect qemu:///system ${name}
              Icon=virt-viewer
              Categories=System;Virtualization;
              Terminal=false
              Comment=Open the ${name} VM console (qemu:///system)
            ''
          ) enabledGuests;
        })
      ];
    })
  ];
}
