#!/bin/sh
# Guest-side probe script for guest-smbios-boot.nix (Option B).
#
# Runs INSIDE the booted AD-on guest. Captures every first-party fingerprint
# source a detection tool would read. Output is written to the raw results disk
# (/dev/sdb) by the guest's adon-probe systemd service; the host reads it back
# after the guest powers off. Markers delimit the payload so any pre-marker
# kernel-boot noise on the disk is ignored by the host-side diff harness.
#
# This file is pure shell — no Nix interpolation. It is read via
# pkgs.writeShellScript (readFile ./scripts/adon-guest-probe.sh) in
# guest-smbios-boot.nix.
set -e

echo "===PROBE-START==="

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

echo "===PROBE-END==="