#!/usr/bin/env bash
#
# dump-host-smbios.sh — Extract SMBIOS fields from your physical host and
# emit a copy-paste Nix snippet for use with antiDetection.smbiosMode = "manual".
#
# Usage:
#   sudo bash scripts/dump-host-smbios.sh
#
# Requires: dmidecode (usually pre-installed, or: nix-shell -p dmidecode)
#
# Security note:
#   Your real serial number and UUID are NOT included in the output. Those are
#   always deterministically generated from your hwidSeed/hwidSalt to prevent
#   correlation attacks and accidental collisions with real hardware owners.
#

set -euo pipefail

# Ensure we're root (dmidecode requires it)
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (dmidecode requires it)." >&2
  echo "Try: sudo bash $0" >&2
  exit 1
fi

# Check for dmidecode
if ! command -v dmidecode &>/dev/null; then
  echo "dmidecode not found. Install it with: nix-shell -p dmidecode" >&2
  exit 1
fi

# ── Extract SMBIOS Type 2 (Baseboard) fields ──
# These are the motherboard identifiers that anti-cheats cross-reference.
bb_manufacturer=$(dmidecode -t baseboard 2>/dev/null | awk -F': ' '/^[[:space:]]+Manufacturer:/{print $2; exit}')
bb_product=$(dmidecode -t baseboard 2>/dev/null | awk -F': ' '/^[[:space:]]+Product Name:/{print $2; exit}')
bb_version=$(dmidecode -t baseboard 2>/dev/null | awk -F': ' '/^[[:space:]]+Version:/{print $2; exit}')
bb_family=$(dmidecode -t baseboard 2>/dev/null | awk -F': ' '/^[[:space:]]+Family:/{print $2; exit}')

# ── Extract SMBIOS Type 0 (BIOS) version ──
bios_version=$(dmidecode -t bios 2>/dev/null | awk -F': ' '/^[[:space:]]+Version:/{print $2; exit}')

# ── Validate we got something ──
missing=()
[ -z "$bb_manufacturer" ] && missing+=("manufacturer")
[ -z "$bb_product" ]      && missing+=("product")
[ -z "$bb_version" ]      && missing+=("version")
[ -z "$bb_family" ]       && missing+=("family")
[ -z "$bios_version" ]    && missing+=("biosVersion")

if [ ${#missing[@]} -gt 0 ]; then
  echo "WARNING: The following fields could not be extracted: ${missing[*]}" >&2
  echo "Some motherboards leave these blank in SMBIOS. You may need to fill" >&2
  echo "them in manually from your motherboard manual or BIOS setup screen." >&2
  echo "" >&2
fi

# ── Emit the Nix snippet ──
# Escape double quotes in values for Nix string safety
escape_nix() {
  echo "$1" | sed 's/"/\\"/g'
}

echo ""
echo "# ─────────────────────────────────────────────────────────────"
echo "# Copy-paste this into your guest config:"
echo "#"
echo "#   antiDetection = {"
echo "#     enable = true;"
echo "#   smbiosMode = \"manual\";"
echo "#   };"
echo "#   smbios = {"
echo "      manufacturer = \"$(escape_nix "$bb_manufacturer")\";"
echo "      product      = \"$(escape_nix "$bb_product")\";"
echo "      version      = \"$(escape_nix "$bb_version")\";"
echo "      family       = \"$(escape_nix "$bb_family")\";"
echo "      biosVersion  = \"$(escape_nix "$bios_version")\";"
echo "#   };"
echo "# ─────────────────────────────────────────────────────────────"
echo ""
