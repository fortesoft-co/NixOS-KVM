{ config, lib, ... }:
with lib;
let
  cfg = config.cfg.kvm;
  enabledGuests = filterAttrs (_: g: g.enable) cfg.guests;
in
{
  config = mkIf (cfg.guests != { }) {
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

  };
}
