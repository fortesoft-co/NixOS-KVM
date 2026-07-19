{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.cfg.kvm;
in
{
  config = mkIf (cfg.host.storage.persistentPath != null) {
    systemd.services.kvm-prepare-state-dir = {
      description = "Prepare libvirt state directory on persistent storage";
      wantedBy = [ "multi-user.target" ];
      before = [ "libvirtd.service" "kvm-cleanup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p "${cfg.host.storage.persistentPath}/host"
        mkdir -p "${cfg.host.storage.persistentPath}/guests"
        chown root:root "${cfg.host.storage.persistentPath}/host"
        chmod 755 "${cfg.host.storage.persistentPath}/host"
      '';
    };

    fileSystems."/var/lib/libvirt" = {
      device = "${cfg.host.storage.persistentPath}/host";
      fsType = "none";
      options = [ "bind" ];
    };

    systemd.services.kvm-host-setup = {
      description = "KVM host storage pool setup";
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ config.virtualisation.libvirtd.package ];
      script = ''
        if ! virsh pool-list --all --name 2>/dev/null | grep -qw kvm-guests; then
          virsh pool-define /dev/stdin <<'POOLXML'
        <pool type='dir'>
          <name>kvm-guests</name>
          <target>
            <path>${cfg.host.storage.persistentPath}/guests</path>
          </target>
        </pool>
        POOLXML
        fi
        virsh pool-start kvm-guests 2>/dev/null || true
        virsh pool-autostart kvm-guests 2>/dev/null || true
      '';
    };
  };
}
