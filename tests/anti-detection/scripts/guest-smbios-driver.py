# Test driver script for guest-smbios.nix (Option A — libvirt argv surfacing).
#
# This is a Python file read by the Nix test via lib.readFile + replaceStrings.
# Nix store paths are injected via @PLACEHOLDER@ tokens (see guest-smbios.nix).
#
# What this script does (orchestrated by the Nix test):
#   1. Waits for the test VM to reach multi-user.target.
#   2. Runs the probe script (virsh define + dumpxml + domxml-to-native checks)
#      with the XML file + expected-values file as arguments.
#   3. Logs the full probe output so nix log shows every OK/FAIL line on a
#      passing run too (the machine.succeed test-output-visibility fix).

# Injected by guest-smbios.nix via lib.replaceStrings:
PROBE_SCRIPT = "@PROBE_SCRIPT@"        # nix store path to the probe script
XML_FILE = "@XML_FILE@"                # nix store path to the AD-on domain XML
EXPECTED_VALUES = "@EXPECTED_VALUES@"  # nix store path to expected-values file


machine.wait_for_unit("multi-user.target")

# Capture the probe's stdout into the test log on SUCCESS too. By default
# `machine.succeed` only dumps its captured stdout on FAILURE (via the
# exception), so a passing run's `===`/`OK:` lines would be lost and `nix log`
# would show nothing of what the probe did. `machine.log` writes them to the
# build log (retrievable via `nix log` or `-L`); the default `nix build` /
# `nix flake check` (no `-L`) stay quiet on success, since they don't stream
# logs — so default CI behavior is unchanged.
out = machine.succeed(f"{PROBE_SCRIPT} {XML_FILE} {EXPECTED_VALUES}")
machine.log(out)