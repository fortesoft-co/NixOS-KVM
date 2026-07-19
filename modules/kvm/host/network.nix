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
  config = {
    networking.bridges = listToAttrs (
      map (
        b:
        nameValuePair b.name {
          interfaces = optional (b.interface != null) b.interface;
        }
      ) cfg.host.networking.bridges
    );

    networking.interfaces = listToAttrs (
      flatten (
        map (
          b:
          optional (b.address != null) (
            nameValuePair b.name {
              ipv4.addresses = [
                {
                  address = b.address;
                  prefixLength = b.prefixLength;
                }
              ];
            }
          )
        ) cfg.host.networking.bridges
      )
    );
  };
}
