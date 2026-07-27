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
#   The Type 3 (Chassis) serial is likewise omitted — the module always emits
#   the "--" placeholder for it (matching real desktop boards).
#
# Field → SMBIOS type mapping (see modules/kvm/guests/lib.nix):
#   Type 0 (BIOS):       biosVersion / biosDate / biosRelease
#   Type 1 (System):      sku, systemManufacturer/Product/Version/Family,
#                        and `family` (the Type 1 family fallback — NOT Type 2,
#                        despite the option description; Type 2 has no Family)
#   Type 2 (Baseboard):   manufacturer / product / version / boardAsset /
#                        boardLocation
#   Type 3 (Chassis):     chassisManufacturer/Version/Asset/Sku
#   Type 11 (OEM Strings): oemStrings (list)
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

# ── Helpers ─────────────────────────────────────────────────────────────────

# dmidecode emits "Not Specified" / "Not Present" when a SMBIOS field is empty.
# Treat those (and a blank string) as absent so we can detect missing fields.
is_empty() {
  case "${1:-}" in
    "" | "Not Specified" | "Not Present") return 0 ;;
    *) return 1 ;;
  esac
}

# Extract the first matching field from a captured dmidecode blob.
# Strips the "  LABEL: " prefix and prints the rest, preserving any ": " inside
# the value (which `awk -F': '` would have truncated).
#   $1 = raw blob, $2 = field label (e.g. "Manufacturer", "Product Name")
extract() {
  printf '%s\n' "$1" | awk -v lbl="$2" '
    $0 ~ ("^[[:space:]]+" lbl ":") {
      sub(("^[[:space:]]+" lbl ":[[:space:]]*"), "")
      print
      exit
    }
  '
}

# Extract every "String N:" entry from an OEM Strings (Type 11) blob, in order.
extract_oem_strings() {
  printf '%s\n' "$1" | awk '/^[[:space:]]+String [0-9]+:[[:space:]]*/{
    sub(/^[[:space:]]+String [0-9]+:[[:space:]]*/, "")
    print
  }'
}

# Escape a value for embedding inside a Nix "..." string.
escape_nix() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Emit `  <opt> = "<val>";` for a real value; skip entirely if absent.
# Used for the OPTIONAL fields (Type 0/2 additions, Type 11).
emit_opt() {
  # $1 = option name (with leading indent), $2 = value
  is_empty "$2" || echo "$1 = \"$(escape_nix "$2")\";"
}

# Emit a REQUIRED base field. When the value is present, emit it normally;
# when absent, emit `= null;` with a FILL-ME-IN note so the manual-mode
# assertion (which checks `== null`) fails closed with its helpful message,
# rather than silently passing with an empty-string SMBIOS value.
emit_req() {
  # $1 = option name (with leading indent), $2 = value
  if is_empty "$2"; then
    echo "$1 = null;  # ← REQUIRED, not detected — FILL ME IN"
  else
    echo "$1 = \"$(escape_nix "$2")\";"
  fi
}

# ── Capture each SMBIOS type once (cheap to reuse) ───────────────────────────
bios_raw=$(dmidecode -t bios 2>/dev/null || true)
sys_raw=$(dmidecode -t system 2>/dev/null || true)
bb_raw=$(dmidecode -t baseboard 2>/dev/null || true)
chassis_raw=$(dmidecode -t chassis 2>/dev/null || true)
oem_raw=$(dmidecode -t 11 2>/dev/null || true)

# ── Type 0 (BIOS) ────────────────────────────────────────────────────────────
bios_version=$(extract "$bios_raw" "Version")
bios_date=$(extract "$bios_raw" "Release Date")
bios_release=$(extract "$bios_raw" "BIOS Revision")

# ── Type 1 (System) ─────────────────────────────────────────────────────────
# NOTE: `family` (the flat option) feeds Type 1's family as the fallback for
# `systemFamily` — it does NOT come from Type 2 (Baseboard), which has no
# Family field. The original version of this script extracted `family` from
# `dmidecode -t baseboard`, which was always empty. Fixed to pull from Type 1.
sys_manufacturer=$(extract "$sys_raw" "Manufacturer")
sys_product=$(extract "$sys_raw" "Product Name")
sys_version=$(extract "$sys_raw" "Version")
sys_family=$(extract "$sys_raw" "Family")
sku=$(extract "$sys_raw" "SKU Number")
family="$sys_family" # flat `family` is the Type 1 family fallback

# ── Type 2 (Baseboard) ──────────────────────────────────────────────────────
bb_manufacturer=$(extract "$bb_raw" "Manufacturer")
bb_product=$(extract "$bb_raw" "Product Name")
bb_version=$(extract "$bb_raw" "Version")
board_asset=$(extract "$bb_raw" "Asset Tag")
board_location=$(extract "$bb_raw" "Location In Chassis")

# ── Type 3 (Chassis) ────────────────────────────────────────────────────────
chassis_manufacturer=$(extract "$chassis_raw" "Manufacturer")
chassis_version=$(extract "$chassis_raw" "Version")
chassis_asset=$(extract "$chassis_raw" "Asset Tag")
chassis_sku=$(extract "$chassis_raw" "SKU Number")

# ── Type 11 (OEM Strings) ──────────────────────────────────────────────────
mapfile -t oem_strings < <(extract_oem_strings "$oem_raw")

# ── Validate the REQUIRED base fields (Type 0/1/2) ──────────────────────────
# These six are mandatory in manual mode (see modules/kvm/guests/assertions.nix).
missing=()
is_empty "$bb_manufacturer" && missing+=("manufacturer")
is_empty "$bb_product" && missing+=("product")
is_empty "$bb_version" && missing+=("version")
is_empty "$family" && missing+=("family")
is_empty "$bios_version" && missing+=("biosVersion")
is_empty "$sku" && missing+=("sku")

if [ ${#missing[@]} -gt 0 ]; then
  echo "WARNING: The following REQUIRED fields could not be extracted: ${missing[*]}" >&2
  echo "Manual mode requires all six base fields. Your motherboard leaves them" >&2
  echo "blank in SMBIOS — fill them in from your motherboard manual or BIOS setup" >&2
  echo "screen. The snippet below will still print (with '= null;' placeholders)," >&2
  echo "but you MUST edit those values before the build will pass." >&2
  echo "" >&2
fi

# ── Validate the all-or-nothing groups ──────────────────────────────────────
# Type 1 (system*) and Type 3 (chassis*) are all-or-nothing: if any member is
# set, all must be set (enforced by assertions). We only emit the group
# uncommented when ALL members are present; otherwise we emit it commented out
# with a note, so the user can choose to fill it in or leave it disabled.
type1_complete=no
if
  ! is_empty "$sys_manufacturer" && ! is_empty "$sys_product" \
    && ! is_empty "$sys_version" && ! is_empty "$sys_family"
then
  type1_complete=yes
fi

type3_complete=no
if
  ! is_empty "$chassis_manufacturer" && ! is_empty "$chassis_version" \
    && ! is_empty "$chassis_asset" && ! is_empty "$chassis_sku"
then
  type3_complete=yes
fi

if [ "$type1_complete" = no ]; then
  echo "NOTE: Type 1 (System) group is incomplete on your host — it will be" >&2
  echo "      emitted commented out. Manual mode treats system* as" >&2
  echo "      all-or-nothing: if you set any, you must set all four. When all" >&2
  echo "      four are unset, they fall back to the Type 2 (baseboard) values" >&2
  echo "      (and `family` for the family), so leaving them commented is safe." >&2
  echo "" >&2
fi

if [ "$type3_complete" = no ]; then
  echo "NOTE: Type 3 (Chassis) group is incomplete on your host — it will be" >&2
  echo "      emitted commented out. Manual mode treats chassis* as" >&2
  echo "      all-or-nothing. When none are set, no <chassis> block is emitted," >&2
  echo "      which is acceptable." >&2
  echo "" >&2
fi

# ── Emit the Nix snippet ─────────────────────────────────────────────────────
echo ""
echo "# ─────────────────────────────────────────────────────────────"
echo "# Copy-paste this into your guest config:"
echo "#"
echo ""
echo "antiDetection = {"
echo "  enable = true;"
echo "  smbiosMode = \"manual\";"
echo "};"
echo "smbios = {"

# ── Required base (Type 0/1/2) ──
emit_req "  manufacturer" "$bb_manufacturer"
emit_req "  product" "$bb_product"
emit_req "  version" "$bb_version"
emit_req "  family" "$family"
emit_req "  sku" "$sku"
emit_req "  biosVersion" "$bios_version"

# ── Optional Type 0 additions ──
emit_opt "  biosDate" "$bios_date"
emit_opt "  biosRelease" "$bios_release"

# ── Optional Type 2 additions ──
emit_opt "  boardAsset" "$board_asset"
emit_opt "  boardLocation" "$board_location"

# ── Optional Type 1 (System) group — all-or-nothing ──
if [ "$type1_complete" = yes ]; then
  echo "  # ── Type 1 (System) — distinct from Type 2 (Baseboard) ──"
  echo "  systemManufacturer = \"$(escape_nix "$sys_manufacturer")\";"
  echo "  systemProduct = \"$(escape_nix "$sys_product")\";"
  echo "  systemVersion = \"$(escape_nix "$sys_version")\";"
  echo "  systemFamily = \"$(escape_nix "$sys_family")\";"
else
  echo "  # ── Type 1 (System) — incomplete on your host (all-or-nothing) ──"
  echo "  # If you fill any in, you must set ALL four. When all four are"
  echo "  # unset, they fall back to the Type 2 values (and `family`) above."
  echo "  #   systemManufacturer = \"$(escape_nix "${sys_manufacturer:-}")\";"
  echo "  #   systemProduct = \"$(escape_nix "${sys_product:-}")\";"
  echo "  #   systemVersion = \"$(escape_nix "${sys_version:-}")\";"
  echo "  #   systemFamily = \"$(escape_nix "${sys_family:-}")\";"
fi

# ── Optional Type 3 (Chassis) group — all-or-nothing ──
if [ "$type3_complete" = yes ]; then
  echo "  # ── Type 3 (Chassis) — serial is always the \"--\" placeholder ──"
  echo "  chassisManufacturer = \"$(escape_nix "$chassis_manufacturer")\";"
  echo "  chassisVersion = \"$(escape_nix "$chassis_version")\";"
  echo "  chassisAsset = \"$(escape_nix "$chassis_asset")\";"
  echo "  chassisSku = \"$(escape_nix "$chassis_sku")\";"
else
  echo "  # ── Type 3 (Chassis) — incomplete on your host (all-or-nothing) ──"
  echo "  # If you fill any in, you must set ALL four. When none are set,"
  echo "  # no <chassis> block is emitted."
  echo "  #   chassisManufacturer = \"$(escape_nix "${chassis_manufacturer:-}")\";"
  echo "  #   chassisVersion = \"$(escape_nix "${chassis_version:-}")\";"
  echo "  #   chassisAsset = \"$(escape_nix "${chassis_asset:-}")\";"
  echo "  #   chassisSku = \"$(escape_nix "${chassis_sku:-}")\";"
fi

# ── Optional Type 11 (OEM Strings) ──
if [ ${#oem_strings[@]} -gt 0 ]; then
  echo "  # ── Type 11 (OEM Strings) ──"
  echo "  oemStrings = ["
  for s in "${oem_strings[@]}"; do
    echo "    \"$(escape_nix "$s")\""
  done
  echo "  ];"
else
  echo "  # ── Type 11 (OEM Strings) — none detected ──"
  echo "  #   oemStrings = [];"
fi

echo "};"
echo ""
echo "# ─────────────────────────────────────────────────────────────"
echo ""
