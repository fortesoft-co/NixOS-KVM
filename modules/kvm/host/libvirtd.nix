{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.cfg.kvm;

  anyGuestParavirtGraphics = lib.any (g: g.paravirtGraphics.enable) (
    builtins.attrValues cfg.guests
  );

  # ───────── Bundled hook scripts ─────────
  gpuPassthroughHook = pkgs.writeShellScript "gpu-passthrough" (
    builtins.readFile ../libvirt_hooks/gpu-passthrough.sh
  );

  libvirtNosleepHook = pkgs.writeShellScript "libvirt-nosleep" (
    builtins.readFile ../libvirt_hooks/libvirt-nosleep.sh
  );

  bundledHookMap = {
    "gpu-passthrough" = gpuPassthroughHook;
    "libvirt-nosleep" = libvirtNosleepHook;
  };

  bundledHooks = lib.genAttrs cfg.host.libvirtd.hooks.bundled (name: bundledHookMap.${name});
in
{
  config = mkMerge [
    {
      virtualisation.libvirtd = {
        enable = true;
        onBoot = cfg.host.libvirtd.onBoot;
        onShutdown = cfg.host.libvirtd.onShutdown;
        parallelShutdown = cfg.host.libvirtd.parallelShutdown;
        shutdownTimeout = cfg.host.libvirtd.shutdownTimeout;
        startDelay = cfg.host.libvirtd.startDelay;
        allowedBridges = cfg.host.libvirtd.allowedBridges;
        extraConfig = cfg.host.libvirtd.extraConfig;
        extraOptions = cfg.host.libvirtd.extraOptions;
        firewallBackend = cfg.host.libvirtd.firewallBackend;
        qemu = {
          runAsRoot = cfg.host.libvirtd.runAsRoot;
          swtpm.enable = cfg.host.libvirtd.swtpm;
        };
        hooks.qemu = bundledHooks // cfg.host.libvirtd.hooks.qemu;
      };

      environment.variables.LIBVIRT_DEFAULT_URI = "qemu:///system";
      environment.etc."libvirt/hooks".source = "/var/lib/libvirt/hooks";

      # ───────── User / permissions ─────────
      users.groups.kvm-monitors = { };
      users.users = mkMerge [
        (genAttrs cfg.host.libvirtd.users.manage (u: {
          extraGroups = [ "libvirtd" ];
        }))
        (genAttrs cfg.host.libvirtd.users.monitor (u: {
          extraGroups = [ "kvm-monitors" ];
        }))
      ];

      environment.etc."polkit-1/rules.d/11-kvm-monitors.rules".text = ''
        polkit.addRule(function(action, subject) {
            if (subject.isInGroup("kvm-monitors")) {
                if (action.id == "org.libvirt.unix.monitor") {
                    return polkit.Result.YES;
                }
                if (action.id == "org.libvirt.unix.manage") {
                    return polkit.Result.NO;
                }
            }
        });
      '';

      security.pam.loginLimits = [
        { domain = "libvirtd"; type = "soft"; item = "memlock"; value = "unlimited"; }
        { domain = "libvirtd"; type = "hard"; item = "memlock"; value = "unlimited"; }
      ];

      systemd.services.libvirtd.path =
        let
          env = pkgs.buildEnv {
            name = "qemu-hook-env";
            paths = with pkgs; [ bash libvirt kmod systemd ripgrep sd ];
          };
        in
        [ env ];
    }

    (mkIf anyGuestParavirtGraphics {
      users.users.qemu-libvirtd = mkIf (!cfg.host.libvirtd.runAsRoot) {
        extraGroups = [ "render" "video" ];
      };
    })

    # ───────── QEMU Anti-Detection Patching ─────────
    (mkIf cfg.host.antiDetection.patchQemu {
      virtualisation.libvirtd.qemu.package = pkgs.qemu.overrideAttrs (old: rec {
        version = if cfg.host.antiDetection.customQemuVersion != null then cfg.host.antiDetection.customQemuVersion else "10.2.2";
        src = if cfg.host.antiDetection.customQemuSrcUrl != null then
          pkgs.fetchurl {
            url = cfg.host.antiDetection.customQemuSrcUrl;
            sha256 = cfg.host.antiDetection.customQemuSrcSha256;
          }
        else
          pkgs.fetchurl {
            url = "https://download.qemu.org/qemu-${version}.tar.xz";
            sha256 = "0xp1457v1hw5szf7gx942xvvk6pasarbqfijfam1f54wy9pjjjvq";
          };
        patches = (old.patches or []) ++ [
          (if cfg.host.antiDetection.customQemuPatch != null then
            cfg.host.antiDetection.customQemuPatch
          else
            ../patches/qemu-10.2.2-anti-detection.patch
          )
        ];
      });
    })

    # ───────── libvirt-nosleep template service ─────────
    (mkIf (elem "libvirt-nosleep" cfg.host.libvirtd.hooks.bundled) {
      systemd.services."libvirt-nosleep@" = {
        unitConfig.Description = ''Preventing sleep while libvirt domain "%i" is running'';
        serviceConfig = {
          Type = "simple";
          ExecStart = ''/run/current-system/sw/bin/systemd-inhibit --what=sleep --why="Libvirt domain \"%i\" is running" --who=%U --mode=block sleep infinity'';
        };
      };
    })
  ];
}
