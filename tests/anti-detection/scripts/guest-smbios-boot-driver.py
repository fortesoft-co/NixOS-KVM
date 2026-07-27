# Test driver script for guest-smbios-boot.nix (Option B).
#
# This is a Python file read by the Nix test via lib.readFile + replaceStrings.
# Nix store paths are injected via @PLACEHOLDER@ tokens (see guest-smbios-boot.nix).
# Keeping it as a real .py file avoids the '' escaping issues of embedding Python
# in a Nix multiline string, and gives us syntax highlighting + linting.
#
# What this script does (orchestrated by the Nix test):
#   1. Hard-fails if /dev/kvm is missing (nested KVM required).
#   2. Creates a qcow2 overlay (tiny) backed by the read-only guest image in the
#      nix store, plus a 1MB raw results disk.
#   3. Defines + starts the AD-on guest under libvirt — the real QEMU boot with
#      -smbios blocks from the module's XML.
#   4. Waits for the guest to run its probe + power off (up to 300s).
#   5. Runs the diff harness against the results disk, logging every OK/FAIL line.
import time

# Injected by guest-smbios-boot.nix via lib.replaceStrings:
GUEST_IMAGE = "@GUEST_IMAGE@"       # nix store path to the qcow2
XML_FILE = "@XML_FILE@"              # nix store path to the AD-on domain XML
DIFF_HARNESS = "@DIFF_HARNESS@"      # nix store path to the diff harness script
EXPECTED_VALUES = "@EXPECTED_VALUES@"  # nix store path to expected-values file


def run(machine, cmd):
    """machine.succeed wrapper that logs the command first."""
    machine.log(f"$ {cmd}")
    return machine.succeed(cmd)


machine.wait_for_unit("multi-user.target")

# HARD-FAIL if no nested KVM — the module emits <domain type='kvm'> which
# requires /dev/kvm. No silent skip (per the user's call: worry about CI later).
run(machine, "test -e /dev/kvm || { echo 'FAIL: /dev/kvm not present "
             "- Option B requires nested KVM'; exit 1; }")
machine.log("/dev/kvm present — proceeding with guest boot test")

# Start the libvirt default network (the guest NIC uses it).
run(machine, "virsh net-start default || true")
run(machine, "virsh net-autostart default || true")

# Place the guest disk: create a small qcow2 OVERLAY with the read-only
# nix-store guest image as a backing file (avoids copying the multi-GB base
# image into the test VM's small disk). The results disk is a tiny raw image
# the guest writes its probe output to.
run(machine, "mkdir -p /var/lib/libvirt/images")
run(machine, f"qemu-img create -f qcow2 -b {GUEST_IMAGE} -F qcow2 "
             f"/var/lib/libvirt/images/adon.qcow2")
run(machine, "chown qemu-libvirtd:libvirtd /var/lib/libvirt/images/adon.qcow2 "
             "2>/dev/null || true")
run(machine, "qemu-img create -f raw /var/lib/libvirt/images/adon-results.raw 1M")
run(machine, "chmod 666 /var/lib/libvirt/images/adon-results.raw")

# Define + start the AD-on guest. This is where QEMU actually boots with the
# -smbios blocks from the XML — the surface Option A couldn't check.
run(machine, f"virsh define {XML_FILE}")
machine.log("Starting AD-on guest under libvirt (KVM)...")
run(machine, "virsh start adon")

# Wait for the guest to finish probing + power off. The probe runs after
# multi-user.target inside the guest, so allow time for boot + probe.
# KVM boot of a minimal NixOS is typically 30-90s; give generous slack.
GUEST_TIMEOUT = 300
deadline = time.time() + GUEST_TIMEOUT
while time.time() < deadline:
    state = run(machine, "virsh domstate adon 2>/dev/null || true").strip()
    if state == "shut off":
        break
    time.sleep(5)
else:
    state = run(machine, "virsh domstate adon 2>/dev/null || true").strip()
    machine.log(f"FAIL: guest did not shut off within {GUEST_TIMEOUT}s "
                f"(state={state})")
    machine.log("=== guest serial console (last 50 lines) ===")
    run(machine, "virsh console adon 2>/dev/null | tail -50 || true")
    raise Exception(f"guest did not power off within {GUEST_TIMEOUT}s")

machine.log("Guest shut off — reading results from the raw results disk")

# Read the results disk + run the diff harness. Surface full output via
# machine.log so nix log shows every OK/FAIL line on a passing run too (same
# test-output-visibility fix as Option A).
out = run(machine, f"{DIFF_HARNESS} /var/lib/libvirt/images/adon-results.raw "
             f"{EXPECTED_VALUES}")
machine.log(out)