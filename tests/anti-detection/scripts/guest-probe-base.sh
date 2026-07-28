#!/bin/sh
# Shared base probe — runs INSIDE any booted AD-on guest (Option B + the
# patched-QEMU boot test + future RDTSC variant). Captures the first-party
# fingerprint sources every boot test diffs against:
#   - SMBIOS Types 0/1/2/3 via /sys/class/dmi/id (+ dmidecode for Type 0
#     release + Type 11 OEM strings, which sysfs omits)
#   - CPU hypervisor flag (/proc/cpuinfo) + model name (lscpu)
#   - NIC (ip link — the e1000e interface + MAC)
#   - PCI list (lspci — no VirtIO giveaway with e1000e)
#   - ACPI table list + block device models (Tier 2 patch targets)
#
# This script emits ONLY its `--- section ---` blocks. It does NOT emit the
# ===PROBE-START/END=== markers — mkGuestImage's adon-probe service wraps the
# concatenated output of ALL probe scripts (base + any extras) in a single
# marker pair, so each test composes its probe as a list of scripts.
#
# Pure shell — no Nix interpolation. Read via pkgs.writeShellScript (readFile)
# in the test's .nix file.
set -e

# /sys/class/dmi/id — the kernel's SMBIOS decode. Covers Types 0/1/2/3.
# Format: DMI:<filename>:<value> for unambiguous parsing on the host side.
echo "--- dmi-sysfs ---"
for f in /sys/class/dmi/id/*; do
  [ -r "$f" ] || continue
  printf 'DMI:%s:%s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null || echo "")"
done

# dmidecode — covers BIOS release (Type 0) + OEM strings (Type 11) which
# sysfs does NOT expose, plus is the tool real detectors use.
echo "--- dmidecode-t0 ---"
dmidecode -t 0
echo "--- dmidecode-t11 ---"
dmidecode -t 11

# CPU — the hypervisor flag in /proc/cpuinfo is the key AD signal (must be
# absent with hypervisor=off). lscpu for the model name (host-passthrough).
echo "--- cpuflags ---"
grep -o '\bhypervisor\b' /proc/cpuinfo | head -1 || true
echo "CPUFLAGS_HYPERVISOR_PRESENT=$(grep -c '\bhypervisor\b' /proc/cpuinfo || true)"
echo "--- lscpu ---"
lscpu

# NIC — ip link shows the e1000e interface + its MAC.
echo "--- ip-link ---"
ip -o link

# PCI — lspci shows the device list (no VirtIO giveaway with e1000e NIC).
echo "--- lspci ---"
lspci

# ACPI tables — OEM ID is a Tier 2 patch target; list what's present.
echo "--- acpi-tables ---"
ls -1 /sys/firmware/acpi/tables/ 2>/dev/null || echo '<none>'

# Block device models — disk model strings are a Tier 2 patch target.
echo "--- block-models ---"
for d in /sys/block/*/device/model; do
  [ -r "$d" ] && printf 'BLOCK:%s:%s\n' "$(echo "$d" | sed 's|/device/model||')" "$(cat "$d")"
done