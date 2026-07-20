{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.cfg.kvm;
  enabledGuests = filterAttrs (_: g: g.enable) cfg.guests;
  guestLib = import ./lib.nix { inherit config lib pkgs; };
  inherit (guestLib) storageDir resolveDiskPath generateXML;

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

in
{
  config = mkIf (cfg.guests != { }) {
    systemd.services = mapAttrs' (n: g: nameValuePair "kvm-guest-${n}" (mkGuestService n g)) enabledGuests;
  };
}
