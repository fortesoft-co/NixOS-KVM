{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.cfg.kvm;
  enabledGuests = filterAttrs (_: g: g.enable) cfg.guests;
  guestLib = import ./lib.nix { inherit config lib pkgs; };
  inherit (guestLib) generateXML;

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
  config = mkIf (cfg.guests != { }) {
    systemd.services = mapAttrs' (n: g: nameValuePair "kvm-guest-${n}-watch" (mkWatchService n g)) enabledGuests;
    systemd.paths = mapAttrs' (n: g: nameValuePair "kvm-guest-${n}-watch" (mkWatchPath n g)) enabledGuests;
  };
}
