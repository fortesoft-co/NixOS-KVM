{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.cfg.kvm;
  hostLib = import ../host/lib.nix { inherit config lib pkgs; };
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

        # Duplicate hwidSalts across guests
        allHwidSalts = mapAttrsToList (_: g: g.hwidSalt) (filterAttrs (_: g: g.enable) cfg.guests);

        # Whether any anti-detection feature is active
        anyAntiDetection =
          cfg.host.antiDetection.patchQemu
          || cfg.host.antiDetection.patchKernel
          || lib.any (g: g.antiDetection.enable) (builtins.attrValues cfg.guests);

        # Whether any enabled guest runs AD in synthetic mode — the only mode that
        # requires a matching motherboard profile from the curated library.
        anySyntheticAdGuest =
          lib.any (g: g.enable && g.antiDetection.enable && g.antiDetection.smbiosMode == "synthetic")
            (builtins.attrValues cfg.guests);

        # Guest AD module — gives hasValidProfile (profile-library coverage for
        # the host's selected manufacturer + CPU vendor + socket) and
        # hostManufacturer, for the no-profile assertion below.
        guestAd = import ./anti-detection.nix { inherit config lib pkgs; };
      in
      [
        {
          assertion = !(anyAntiDetection && cfg.host.cpuVendor != "auto");
          message = "cfg.kvm.host.cpuVendor must be \"auto\" when anti-detection is enabled. Manual vendor override risks a CPUID/SMBIOS mismatch that fingerprinting tools can detect.";
        }
        {
          assertion = unique allDomainNames == allDomainNames;
          message = "Domain name conflict: multiple guests share the same domainName. Each guest MUST have a globally unique domainName.";
        }
        {
          assertion = unique allHwidSalts == allHwidSalts;
          message = "hwidSalt conflict: multiple guests share the same hwidSalt. Each guest MUST have a globally unique hwidSalt to prevent hardware ID collisions.";
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
        # CPU socket detection — fail closed when auto-detection misses
        (optionals anyAntiDetection [
          {
            assertion = cfg.host.cpuSocket != "auto" || hostLib.cpuSocket != null;
            message = ''
              Could not auto-detect CPU socket for vendor '${
                if cfg.host.cpuVendor != "auto" then cfg.host.cpuVendor else hostLib.cpuVendor
              }'.
              Both the CPU-X database lookup (layer 2) and the regex heuristic (layer 3) failed.

              To fix this, set cfg.kvm.host.cpuSocket manually in your host configuration.
              Common values: AM4, AM5, LGA1700, LGA1851, sTR5, SP3, SP5, etc.

              To identify your CPU, run:
                nix-shell -p libcpuid --run "cpuid_tool --codename"
              or check your motherboard manual for the socket type.
            '';
          }
        ])
      ++
        # Synthetic AD — fail (do NOT silently fall back) when no motherboard
        # profile matches the host's (manufacturer, CPU vendor, socket). Without
        # this, a synthetic guest would silently get a generic placeholder board
        # while the user believes they're getting a curated, socket-matched one.
        # hasValidProfile is host-level (depends on the seed-selected manufacturer
        # + CPU, not per-guest hwidSalt), so one assertion covers all synthetic
        # guests on the host. Only gated when a synthetic AD-on guest exists.
        (optionals anySyntheticAdGuest [
          {
            assertion = guestAd.hasValidProfile;
            message = ''
              Anti-detection synthetic mode requires a motherboard profile for the
              host's CPU in the curated profile library
              (modules/kvm/host/smbios-profiles.nix), but none was found for:
                manufacturer = ${guestAd.hostManufacturer.smbiosManufacturer}
                              (seed-selected from cfg.kvm.host.hwidSeed)
                CPU vendor   = ${hostLib.cpuVendor}
                CPU socket   = ${hostLib.cpuSocket}

              The library has no entry for this (manufacturer, CPU vendor, socket)
              combination across any of the four supported brands, so synthetic
              mode cannot produce a plausible, socket-matched board. It will NOT
              silently fall back to a generic board — that would present an
              implausible/wrong-socket identity to fingerprinting tools.

              To fix this, either:
                1. Add matching profiles to the library (run
                   scripts/sync-motherboard-db.py with a linuxhw/DMI dump for this
                   socket), or
                2. Set antiDetection.smbiosMode = "manual" on the synthetic guest(s)
                   and provide full smbios hardware fields, or
                3. Disable antiDetection on the affected guest(s).
            '';
          }
        ])
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
                  assertion = builtins.match "^[a-zA-Z0-9_-]{3,64}$" g.hwidSalt != null;
                  message = "Guest ${name}: hwidSalt is invalid. It must be 3-64 characters long and contain only alphanumeric characters, hyphens, and underscores. Generate one using `uuidgen` or `openssl rand -hex 16`.";
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
                # Anti-Detection — serial override is ALWAYS forbidden when antiDetection is on
                {
                  assertion = !(g.antiDetection.enable && g.smbios.serial != null);
                  message = ''
                    Guest ${name}: smbios.serial cannot be set manually when antiDetection is enabled.
                    The serial is always deterministically generated from your hwidSeed/hwidSalt to
                    ensure it is unique, plausible, and impossible to correlate with other identifiers.
                    Remove the smbios.serial override to proceed.
                  '';
                }
                # Anti-Detection — synthetic mode forbids ALL smbios overrides
                {
                  assertion =
                    !(
                      g.antiDetection.enable
                      && g.antiDetection.smbiosMode == "synthetic"
                      && (
                        g.smbios.manufacturer != null
                        || g.smbios.product != null
                        || g.smbios.version != null
                        || g.smbios.family != null
                        || g.smbios.biosVersion != null
                        || g.smbios.sku != null
                        || g.smbios.systemManufacturer != null
                        || g.smbios.systemProduct != null
                        || g.smbios.systemVersion != null
                        || g.smbios.systemFamily != null
                        || g.smbios.biosDate != null
                        || g.smbios.biosRelease != null
                        || g.smbios.boardAsset != null
                        || g.smbios.boardLocation != null
                        || g.smbios.chassisManufacturer != null
                        || g.smbios.chassisVersion != null
                        || g.smbios.chassisAsset != null
                        || g.smbios.chassisSku != null
                        || g.smbios.oemStrings != [ ]
                      )
                    );
                  message = ''
                    Guest ${name}: smbiosMode is "synthetic" but manual SMBIOS overrides are set.
                    In synthetic mode, the full Type 0/1/2/3/11 SMBIOS data is procedurally
                    selected from the curated profile database — no manual overrides are
                    permitted. Either:
                      1. Remove the smbios.* overrides, or
                      2. Set antiDetection.smbiosMode = "manual" and provide full smbios hardware fields.
                  '';
                }
                # Anti-Detection — manual mode: base smbios fields (Type 0/1/2) are required
                {
                  assertion =
                    !(
                      g.antiDetection.enable
                      && g.antiDetection.smbiosMode == "manual"
                      && (
                        g.smbios.manufacturer == null
                        || g.smbios.product == null
                        || g.smbios.version == null
                        || g.smbios.family == null
                        || g.smbios.biosVersion == null
                        || g.smbios.sku == null
                      )
                    );
                  message = ''
                    Guest ${name}: smbiosMode is "manual" but not all smbios hardware fields are provided.

                    Hint: Run `scripts/dump-host-smbios.sh` on your physical host to extract
                    your real values, or provide custom values of your choosing.

                    WARNING: Whatever values you provide must be internally consistent. The
                    manufacturer, product, version, family, BIOS version, and SKU must correspond
                    to a real, physically-possible motherboard. If you mix fields from
                    different boards (e.g., an ASUS product with a Gigabyte manufacturer),
                    or pair a board with a CPU that doesn't fit its socket, fingerprinting
                    tools will flag the impossible combination. The system cannot validate
                    these values for you — you are responsible for their accuracy.

                    Synthetic mode is strongly recommended unless you
                    have a specific reason to go manual (e.g., licensing tie-ins, custom
                    board profiles not in our database).
                  '';
                }
                # Anti-Detection — manual mode: Type 1 (system*) fields are all-or-nothing
                {
                  assertion =
                    !(
                      g.antiDetection.enable
                      && g.antiDetection.smbiosMode == "manual"
                      && (
                        g.smbios.systemManufacturer != null
                        || g.smbios.systemProduct != null
                        || g.smbios.systemVersion != null
                        || g.smbios.systemFamily != null
                      )
                      && !(
                        g.smbios.systemManufacturer != null
                        && g.smbios.systemProduct != null
                        && g.smbios.systemVersion != null
                        && g.smbios.systemFamily != null
                      )
                    );
                  message = ''
                    Guest ${name}: smbios Type 1 (system) fields are all-or-nothing in manual mode.
                    If you set any of systemManufacturer/systemProduct/systemVersion/systemFamily,
                    you must set all four. A partial override would mix a user-provided Type 1
                    field with a Type 2 (baseboard) fallback, producing an incoherent Type 1
                    that real hardware never emits. When none are set, all four fall back to
                    the flat baseboard values manufacturer/product/version (Type 2) plus
                    `family` (Type 1 — Type 2 has no Family field).
                  '';
                }
                # Anti-Detection — manual mode: Type 3 (chassis*) fields are all-or-nothing
                {
                  assertion =
                    !(
                      g.antiDetection.enable
                      && g.antiDetection.smbiosMode == "manual"
                      && (
                        g.smbios.chassisManufacturer != null
                        || g.smbios.chassisVersion != null
                        || g.smbios.chassisAsset != null
                        || g.smbios.chassisSku != null
                      )
                      && !(
                        g.smbios.chassisManufacturer != null
                        && g.smbios.chassisVersion != null
                        && g.smbios.chassisAsset != null
                        && g.smbios.chassisSku != null
                      )
                    );
                  message = ''
                    Guest ${name}: smbios Type 3 (chassis) fields are all-or-nothing in manual mode.
                    If you set any of chassisManufacturer/chassisVersion/chassisAsset/chassisSku,
                    you must set all four. Real hardware always populates Type 3 (even with
                    placeholders), so a partial chassis block is itself a fingerprint. When
                    none are set, no <chassis> block is emitted.
                  '';
                }
                # Anti-Detection — synthetic mode forbids manual MAC overrides
                {
                  assertion =
                    !(
                      g.antiDetection.enable
                      && g.antiDetection.smbiosMode == "synthetic"
                      && lib.any (net: net.mac != null) g.networks
                    );
                  message = ''
                    Guest ${name}: smbiosMode is "synthetic" but one or more network
                    interfaces have a manually set MAC address. In synthetic mode,
                    the MAC is procedurally derived from your hwidSeed/hwidSalt using
                    the NIC vendor's real OUI prefix (Intel, matching the
                    emulated e1000e NIC) — manual overrides
                    are not permitted. Either:
                      1. Remove the networks.*.mac overrides, or
                      2. Set antiDetection.smbiosMode = "manual".
                  '';
                }
                # HWID Seed — universally enforce presence and UUID format
                {
                  assertion =
                    cfg.host.hwidSeed != null
                    &&
                      builtins.match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" cfg.host.hwidSeed
                      != null;
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
