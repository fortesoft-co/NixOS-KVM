{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.cfg.kvm;
in
{
  config = {
    environment.systemPackages =
      optionals cfg.host.tools.enable (
        with pkgs; [ qemu libguestfs pciutils python3 iproute2 ]
      )
      ++ optionals (cfg.host.tools.enable && cfg.host.tools.gui) (
        with pkgs; [ virt-manager virt-viewer dconf ]
      )
      ++ cfg.host.tools.extraPackages;

    services.xrdp.enable = cfg.host.xrdp.enable;
    systemd.services.pcscd.enable = mkIf cfg.host.xrdp.enable false;
    systemd.sockets.pcscd.enable = mkIf cfg.host.xrdp.enable false;
  };
}
