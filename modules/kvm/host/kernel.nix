{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.cfg.kvm;
  hostLib = import ./lib.nix { inherit config lib pkgs; };
  cpuVendor = hostLib.cpuVendor;

  anyGuestPciPassthrough = lib.any (g: (g.passthrough.pci or [ ]) != [ ]) (
    builtins.attrValues cfg.guests
  );

  iommuActive = cfg.host.kernel.iommu.enable || anyGuestPciPassthrough;

  anyGuestParavirtGraphics = lib.any (g: g.paravirtGraphics.enable) (
    builtins.attrValues cfg.guests
  );
in
{
  config = mkMerge [
    {
      # ───────── Kernel / KVM modules ─────────
      boot.kernelModules = cfg.host.kernel.extraModules ++ optional iommuActive "vfio-pci";
      boot.kernelParams =
        cfg.host.kernel.extraParams
        ++ optionals iommuActive [
          "iommu=${cfg.host.kernel.iommu.mode}"
          "${cpuVendor}_iommu=on"
        ];
      boot.extraModprobeConfig = ''
        options kvm_${cpuVendor} nested=${if cfg.host.kernel.nested then "1" else "0"}
        options kvm ignore_msrs=${if cfg.host.kernel.ignoreMsrs then "1" else "0"}
      '';
    }

    # ───────── VFIO PCI device binding ─────────
    (mkIf iommuActive {
      boot.extraModprobeConfig = mkAfter ''
        ${optionalString anyGuestPciPassthrough ''
          options vfio-pci ids=${
            concatStringsSep "," (
              unique (concatLists (mapAttrsToList (_: g: map (d: d.id) g.passthrough.pci) cfg.guests))
            )
          }
        ''}
      '';
    })

    # ───────── Paravirtualized Graphics Host Setup ─────────
    (mkIf anyGuestParavirtGraphics {
      hardware.graphics = {
        enable = true;
        enable32Bit = true;
      };
    })

    # ───────── Kernel Anti-Detection Patching (RDTSC) ─────────
    (mkIf cfg.host.antiDetection.patchKernel {
      boot.kernelPackages = if cfg.host.antiDetection.customKernelSrcUrl != null then
        pkgs.linuxPackagesFor (pkgs.linux.override {
          argsOverride = {
            src = pkgs.fetchurl {
              url = cfg.host.antiDetection.customKernelSrcUrl;
              sha256 = cfg.host.antiDetection.customKernelSrcSha256;
            };
            version = cfg.host.antiDetection.customKernelVersion;
            modDirVersion = cfg.host.antiDetection.customKernelVersion;
          };
        })
      else
        pkgs.linuxPackages_6_1;

      boot.kernelPatches = [
        {
          name = "kvm-rdtsc-spoof";
          patch = if cfg.host.antiDetection.customKernelPatch != null then
            cfg.host.antiDetection.customKernelPatch
          else
            ../patches/linux-6.1-rdtsc.patch;
        }
      ];
    })
  ];
}
