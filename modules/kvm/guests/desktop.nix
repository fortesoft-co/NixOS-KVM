{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.cfg.kvm;
  enabledGuests = filterAttrs (_: g: g.enable) cfg.guests;
in
{
  config = mkIf (cfg.host.tools.gui && enabledGuests != { }) {
      environment.systemPackages = [
        (pkgs.symlinkJoin {
          name = "kvm-guest-launchers";
          paths = mapAttrsToList (
            name: guest:
            pkgs.writeTextDir "share/applications/kvm-guest-${name}.desktop" ''
              [Desktop Entry]
              Type=Application
              Name=VM: ${guest.domainName}
              Exec=virt-viewer --connect qemu:///system ${guest.domainName}
              Icon=virt-viewer
              Categories=System;Virtualization;
              Terminal=false
              Comment=Open the ${guest.domainName} VM console (qemu:///system)
            ''
          ) enabledGuests;
        })
      ];
  };
}
