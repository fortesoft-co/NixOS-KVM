#!/bin/sh
# Patched-QEMU extras probe — layered ON TOP of guest-probe-base.sh by the
# patched-QEMU boot test (guest-smbios-patched.nix). Captures the surfaces
# where the QEMU string replacements surface that the base probe doesn't:
#   - /sys/bus/acpi/devices/  — the fw_cfg device _HID changes from QEMU0002
#     to <patchToken>0002 (hw/i386/fw_cfg.c). Primary patched-string surface;
#     reliable on q35, always present. Hard-asserted by the patched diff harness.
#   - /proc/bus/input/devices — input handler names (QEMU PS/2 * -> <token> PS/2 *).
#     With AD on the module uses PS/2 input; the ps2 handlers ARE patched, so
#     these may surface if libvirt adds default PS/2 devices. Captured for
#     diagnostics (promoted to an assertion once confirmed to surface).
#
# This script emits ONLY its `--- section ---` blocks — NO ===PROBE-START/END===
# markers (mkGuestImage's service wraps the concatenated probe output). It is
# run AFTER guest-probe-base.sh, so the combined payload is base sections then
# these extras, all between one marker pair.
#
# Pure shell — no Nix interpolation. Read via pkgs.writeShellScript (readFile)
# in guest-smbios-patched.nix.
set -e

# ACPI devices — the fw_cfg device _HID is patched from QEMU0002 to <token>0002.
# This is the PRIMARY patched-string surface: the listing should contain
# <token>0002:00 and NOT QEMU0002:00. Parsed by the host-side diff harness.
echo "--- acpi-devices ---"
ls -1 /sys/bus/acpi/devices/ 2>/dev/null || echo '<none>'

# ACPI table OEM ID — patched from "BOCHS " to "INTEL " (ACPI_BUILD_APPNAME6
# in hw/i386/acpi-build.c). Unlike the fw_cfg _HID, this is a CONSTANT in the
# patch (not sed-token-substituted), so it proves the static-string half of the
# patch took effect. The OEM ID is bytes 10-15 of every ACPI table header;
# /sys/firmware/acpi/tables/<SIG> exposes the raw table (header included), so
# we read it with dd — no acpica-tools needed. FACP is always present. Format:
# ACPI_OEM_ID:<table-basename>:<oem-id> for the host-side diff to parse.
echo "--- acpi-oem ---"
for t in /sys/firmware/acpi/tables/*; do
  [ -r "$t" ] || continue
  oem=$(dd if="$t" bs=1 skip=10 count=6 2>/dev/null | tr -d '\0')
  printf 'ACPI_OEM_ID:%s:%s\n' "$(basename "$t")" "$oem"
done

# Input devices — captured for diagnostics only, NOT asserted. The QEMU input
# handler names (QEMU PS/2 * -> <token> PS/2 *) are QEMU-internal and do NOT
# surface in the guest for PS/2 devices: /proc/bus/input/devices Name= shows the
# KERNEL's generic name ("AT Translated Set 2 keyboard"), since PS/2 has no
# device descriptors. Only USB HID names surface (via USB product strings), and
# AD uses PS/2 (no USB tablet). Kept so a future USB-input fixture variant can
# inspect it.
echo "--- input-devices ---"
cat /proc/bus/input/devices 2>/dev/null || echo '<none>'