{ config, lib, ... }:
with lib;
let
  cfg = config.cfg.kvm;
in
{
  config = mkIf (cfg.guests != { }) {
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
  };
}
