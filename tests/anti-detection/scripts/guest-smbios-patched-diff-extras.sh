# Patched-QEMU extras fragment — the patched-string assertions, layered BETWEEN
# the shared 20-field regression checks (guest-smbios-diff-base.sh) and the
# summary (guest-smbios-diff-summary.sh) by mkDiffHarness. Uses check()/PROBE/
# PASS/FAIL from the base fragment (in scope via concatenation).
#
# Asserts three reliable x86 surfaces that the QEMU string replacements surface
# in the booted guest:
#   a. fw_cfg ACPI _HID: QEMU0002 -> <token>0002 (token-substituted half)
#   b. ACPI table OEM ID: "BOCHS " -> "INTEL " (CONSTANT — static-string half)
#   c. SATA disk model: "QEMU HARDDISK" -> "<token> HARDDISK" (assert-if-present)
# Together (a)+(b) cover both the sed-token-substituted and the static halves of
# the patch. See guest-smbios-patched.nix for the full surface categorization.
echo "=== PATCHED STRINGS — QEMU string replacements took effect ==="
# Extract the acpi-devices listing (between the --- acpi-devices --- header and
# the next --- header / end of payload). One device per line.
ACPI_DEVICES=$(printf '%s\n' "$PROBE" | awk '
  /^--- acpi-devices ---/{f=1;next}
  /^--- /{f=0}
  f
')

# Primary positive: the patched fw_cfg _HID (<token>0002) is present.
if printf '%s\n' "$ACPI_DEVICES" | grep -q "^${EXPECTED_acpi_fwcfg_hid}:"; then
  echo "OK   [acpi.fwcfg-hid-patched]: '${EXPECTED_acpi_fwcfg_hid}' present in /sys/bus/acpi/devices/"
  PASS=$((PASS + 1))
else
  echo "FAIL [acpi.fwcfg-hid-patched]"
  echo "  got : no '${EXPECTED_acpi_fwcfg_hid}:' in acpi device listing"
  echo "  want: '${EXPECTED_acpi_fwcfg_hid}:00' present"
  echo "  acpi-devices listing:"
  printf '%s\n' "$ACPI_DEVICES" | sed 's/^/    /'
  FAIL=$((FAIL + 1))
fi

# Negative: the unpatched fw_cfg _HID (QEMU0002) is GONE — the patch replaced,
# not added, the ID.
if printf '%s\n' "$ACPI_DEVICES" | grep -q '^QEMU0002:'; then
  echo "FAIL [acpi.fwcfg-hid-no-qemu]"
  echo "  got : 'QEMU0002:' still present (patch did not take effect)"
  echo "  want: 'QEMU0002:' absent"
  FAIL=$((FAIL + 1))
else
  echo "OK   [acpi.fwcfg-hid-no-qemu]: 'QEMU0002' absent from /sys/bus/acpi/devices/"
  PASS=$((PASS + 1))
fi

# ── ACPI OEM ID (constant string — proves the STATIC half of the patch) ─────
# ACPI_BUILD_APPNAME6 changed "BOCHS " -> "INTEL " in every ACPI table header.
# Independent of the fw_cfg _HID check (token-substituted half): the OEM ID is a
# constant in the patch, not sed-substituted. Extract the FACP OEM ID (always
# present on x86), strip trailing space padding.
FACP_OEM=$(printf '%s\n' "$PROBE" | awk -F':' '$1=="ACPI_OEM_ID" && $2=="FACP" {sub("^ACPI_OEM_ID:FACP:",""); print; exit}' | sed 's/[[:space:]]*$//')
check "acpi.oem-id-patched" "$FACP_OEM" "$EXPECTED_acpi_oem_id"

# Negative: no ACPI table should carry the unpatched "BOCHS" OEM ID.
if printf '%s\n' "$PROBE" | grep -q '^ACPI_OEM_ID:[^:]*:BOCHS'; then
  echo "FAIL [acpi.oem-id-no-bochs]"
  echo "  got : a table still has BOCHS OEM ID (patch did not take effect)"
  printf '%s\n' "$PROBE" | grep '^ACPI_OEM_ID:' | sed 's/^/    /'
  FAIL=$((FAIL + 1))
else
  echo "OK   [acpi.oem-id-no-bochs]: no ACPI table carries 'BOCHS' OEM ID"
  PASS=$((PASS + 1))
fi

# ── SATA disk model (token-substituted — hard assert) ─────────────────────
# AD forces SATA, so disks go through hw/ide/core.c whose default hard-disk
# model "QEMU HARDDISK" is patched to "<token> HARDDISK" and surfaces via
# /sys/block/sda/device/model (libata derives the SCSI model from ATA IDENTIFY).
# CONFIRMED to surface in a real boot (both SATA disks reported <token> HARDDISK),
# so this is a hard assert: if block models were captured, at least one must
# carry the token and none may still say "QEMU "; if none captured (surface
# absent — a regression), FAIL. The base probe captures block models (BLOCK:...).
BLOCK_MODELS=$(printf '%s\n' "$PROBE" | awk -F':' '$1=="BLOCK" {sub("^BLOCK:[^:]*:",""); print}')
if [ -z "$BLOCK_MODELS" ]; then
  echo "FAIL [block.model-patched]"
  echo "  got : no block-device models captured (surface absent — expected SATA disks to surface a model)"
  echo "  want: at least one model carrying '$EXPECTED_patch_token'"
  FAIL=$((FAIL + 1))
else
  if printf '%s\n' "$BLOCK_MODELS" | grep -q "QEMU "; then
    echo "FAIL [block.model-patched]"
    echo "  got : a block model still says 'QEMU ' (patch did not take effect)"
    printf '%s\n' "$BLOCK_MODELS" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  elif printf '%s\n' "$BLOCK_MODELS" | grep -q "$EXPECTED_patch_token"; then
    echo "OK   [block.model-patched]: block models carry '$EXPECTED_patch_token'"
    printf '%s\n' "$BLOCK_MODELS" | sed 's/^/    /'
    PASS=$((PASS + 1))
  else
    echo "FAIL [block.model-patched]"
    echo "  got : block models captured but none carry '$EXPECTED_patch_token' and none say 'QEMU '"
    printf '%s\n' "$BLOCK_MODELS" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
fi