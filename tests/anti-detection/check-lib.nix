# Shared helper for Layer 1 eval-time checks (cpu-socket, guest-lib, host-lib,
# smbios-profiles). These tests all use the same pattern: a list of checks where
# each check returns null (pass) or a string (failure detail), aggregated into a
# final `true` or `throw` with a formatted report.
#
# Usage:
#   checkLib = import ./check-lib.nix { inherit lib; };
#   ...
#   in checkLib.mkChecks "my-test" allChecks
{ lib }:
with lib;
{
  mkChecks = name: checks:
    let failures = filter (c: c.detail != null) checks;
    in if failures == [] then true
    else throw (
      "${name}: ${toString (length failures)}/${toString (length checks)} checks FAILED:\n"
      + concatStringsSep "\n" (map (c: "  [${c.name}] ${c.detail}") failures)
    );
}