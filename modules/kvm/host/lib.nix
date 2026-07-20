{ config, lib, pkgs }:
with lib;
let
  cfg = config.cfg.kvm;

  # ───────── CPU vendor detection ─────────
  # Resolves "auto" to "intel" or "amd" from boot.kernelModules,
  # falling back to /proc/cpuinfo probing.
  cpuVendor =
    let
      v = cfg.host.cpuVendor;
    in
    if v != "auto" then
      v
    else if builtins.elem "kvm-intel" config.boot.kernelModules then
      "intel"
    else if builtins.elem "kvm-amd" config.boot.kernelModules then
      "amd"
    else
      builtins.readFile (
        pkgs.runCommand "cpu-vendor.txt" { } ''
          ((cat /proc/cpuinfo | grep vendor | head -n 1 | grep -i intel > /dev/null 2>&1) \
            && echo -n 'intel' || echo -n 'amd') > $out
        ''
      );
in
{
  inherit cpuVendor;
}