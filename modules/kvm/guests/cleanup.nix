{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.cfg.kvm;
in
{
  config = {
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
  };
}
