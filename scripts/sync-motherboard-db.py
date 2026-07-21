#!/usr/bin/env python3
"""
sync-motherboard-db.py — Compile a motherboard hardware profile library.

Sparsely checks out target desktop/server folders from the linuxhw/DMI
repository, parses raw dmidecode dumps, extracts SMBIOS motherboard metadata,
maps CPU brand strings to sockets using `cpu-packages.nix` (for Intel) and
`detectAmdSocket` (for AMD), and generates a structured Nix profile library
('profiles.nix') for anti-detection guests.

Usage:
    python3 scripts/sync-motherboard-db.py > modules/kvm/guests/profiles.nix
"""

import re
import os
import sys
import subprocess
import tempfile
import shutil
import importlib.util

# ── Configuration ──────────────────────────────────────────────────────────

DMI_REPO_URL = "https://github.com/linuxhw/DMI.git"

# Target manufacturer folders under Desktop/ and Server/ to parse
TARGET_PATHS = [
    # ASUS
    "Desktop/ASUSTek Computer",
    "Server/ASUSTek Computer",
    # ASRock
    "Desktop/ASRock",
    "Server/ASRockRack",
    # Gigabyte
    "Desktop/Gigabyte Technology",
    "Desktop/Giga-Byte Technology",
    "Server/Giga Computing",
    "Server/Gigabyte Technology",
    # MSI
    "Desktop/MSI",
    "Server/MSI",
]

# Motherboard manufacturer ID mapping (for step 5 matching)
MANUFACTURER_MAP = {
    "asustek computer inc.": "asus",
    "asrock": "asrock",
    "asrockrack": "asrock",
    "gigabyte technology co., ltd.": "gigabyte",
    "giga-byte technology co., ltd.": "gigabyte",
    "micro-star international co., ltd.": "msi",
    "micro-star international co. ltd.": "msi",
}

# Standard SMBIOS strings for normalizations
SMBIOS_MANUFACTURERS = {
    "asus": "ASUSTeK COMPUTER INC.",
    "asrock": "ASRock",
    "gigabyte": "Gigabyte Technology Co., Ltd.",
    "msi": "Micro-Star International Co., Ltd.",
}

# Sockets supported by NixOS-KVM (per cpu-packages.nix primary targets)
SUPPORTED_SOCKETS = {
    # AMD
    "AM4", "AM5", "sTR4", "sTRX4", "sWRX8", "sTR5", "SP3", "SP5", "SP6",
    # Intel
    "LGA1151", "LGA1200", "LGA1700", "LGA1851", "LGA2011", "LGA2011-3", "LGA2066", "LGA3647", "LGA4677", "LGA4710"
}

# ── Fallback profiles loader ───────────────────────────────────────────────
# The sibling `fallback-smbios.py` carries curated profiles for (vendor, socket)
# cells that are empty after the Step 2a quality filter. The hyphenated filename
# isn't a valid Python identifier, so we load it via importlib.

def load_fallbacks() -> dict:
    """Return FALLBACK_PROFILES from sibling fallback-smbios.py, or {} if absent."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    fb_path = os.path.join(script_dir, "fallback-smbios.py")
    if not os.path.exists(fb_path):
        print("# Warning: fallback-smbios.py not found; skipping fallback merge.",
              file=sys.stderr)
        return {}
    spec = importlib.util.spec_from_file_location("fallback_smbios", fb_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.FALLBACK_PROFILES

# ── Nix cpu-packages.nix Parser ──────────────────────────────────────────

def parse_cpu_packages(nix_filepath: str) -> tuple[list[dict], list[dict]]:
    """Parse cpu-packages.nix to extract raw Intel and AMD lists."""
    try:
        with open(nix_filepath, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception as e:
        print(f"# Error reading {nix_filepath}: {e}", file=sys.stderr)
        return [], []

    # Extract packageIntel list block
    intel_match = re.search(r'packageIntel\s*=\s*\[(.*?)\];', content, re.DOTALL)
    amd_match = re.search(r'packageAmd\s*=\s*\[(.*?)\];', content, re.DOTALL)

    intel_entries = []
    if intel_match:
        # Match `{ codename = ...; model = ...; socket = "..."; }`
        for m in re.finditer(r'\{\s*codename\s*=\s*(null|"[^"]*")\s*;\s*model\s*=\s*(null|"[^"]*")\s*;\s*socket\s*=\s*"([^"]*)"\s*;\s*\}', intel_match.group(1)):
            codename = m.group(1)
            model = m.group(2)
            socket = m.group(3)
            intel_entries.append({
                "codename": None if codename == "null" else codename.strip('"'),
                "model": None if model == "null" else model.strip('"'),
                "socket": socket
            })

    amd_entries = []
    if amd_match:
        for m in re.finditer(r'\{\s*codename\s*=\s*(null|"[^"]*")\s*;\s*model\s*=\s*(null|"[^"]*")\s*;\s*socket\s*=\s*"([^"]*)"\s*;\s*\}', amd_match.group(1)):
            codename = m.group(1)
            model = m.group(2)
            socket = m.group(3)
            amd_entries.append({
                "codename": None if codename == "null" else codename.strip('"'),
                "model": None if model == "null" else model.strip('"'),
                "socket": socket
            })

    return intel_entries, amd_entries

# ── Parsing & Normalization ────────────────────────────────────────────────

def clean_string(val: str) -> str:
    """Strip quotes and sanitize string. Used for Type 2 baseboard fields
    where placeholders should be replaced with synthesized fallbacks."""
    if not val:
        return ""
    val = val.strip().strip('"').strip("'").strip()
    if val.lower() in {"not specified", "to be filled by o.e.m.", "not applicable", "unknown", "none"}:
        return ""
    return val

def raw_string(val: str) -> str:
    """Strip whitespace only — preserve placeholder values like 'Default string',
    '--', 'To be filled by O.E.M.', 'System Product Name'.

    Used for Type 1 (System), Type 3 (Chassis), Type 11 (OEM Strings), and the
    new Type 0/2 fields where the *placeholder* is the realistic value: real
    hardware emits 'Default string' and '--' verbatim, and a detection engine
    comparing against real dmidecode output expects to see those placeholders,
    not empty or synthesized values."""
    if not val:
        return ""
    return val.strip().strip('"').strip("'").strip()

def nix_escape(val: str) -> str:
    """Escape a string for safe embedding inside a Nix double-quoted string."""
    return val.replace("\\", "\\\\").replace('"', '\\"')

def extract_chipset(product_name: str) -> str:
    """Extract standard desktop/workstation chipsets from product name."""
    m = re.search(r'\b(A\d{3}|B\d{3}|H\d{3}|Q\d{3}|Z\d{3}|X\d{3}[E]?|TRX\d{2}|WRX\d{2})\b', product_name, re.IGNORECASE)
    if m:
        return m.group(1).upper()
    return ""

def extract_model_num(model_name: str) -> str:
    """Mirror host/lib.nix:extractModelNum."""
    m = re.match(r'.*[^0-9]([0-9]{4,5})[^0-9].*', model_name)
    if m:
        return m.group(1)
    return ""

def detect_amd_socket(cpu_brand: str) -> str | None:
    """Replicates host/lib.nix:detectAmdSocket."""
    model_num = extract_model_num(cpu_brand)
    first_digit = model_num[0] if model_num else ""
    is_pro = "PRO" in cpu_brand.upper()

    if "EPYC" in cpu_brand.upper():
        if first_digit == "9":
            return "SP5"          # Genoa/Bergamo/Turin (9004/9005)
        elif first_digit == "8":
            return "SP6"          # Siena (8004)
        elif first_digit == "7":
            return "SP3"          # Naples/Rome/Milan (7001-7003)
        else:
            return None
    elif "THREADRIPPER" in cpu_brand.upper():
        if first_digit in {"7", "8", "9"}:
            return "sTR5"         # TR 7000+
        elif is_pro:
            return "WRX80"        # PRO 3xxx/5xxx
        else:
            return "sTRX4"        # non-PRO 3xxx/5xxx
    elif "RYZEN" in cpu_brand.upper():
        if first_digit in {"7", "8", "9"}:
            return "AM5"          # Zen 4+
        else:
            return "AM4"          # Zen 1/+/2/3
    return None

def detect_intel_socket(cpu_brand: str, package_intel: list[dict]) -> str | None:
    """Replicates host/lib.nix:detectSocketFromDatabase (Intel branch)."""
    # 1. Strip the "Nth Gen " prefix from Intel brand strings
    stripped = re.sub(r'^[0-9]+th Gen\s+', '', cpu_brand)

    # 2. Strip trailing uppercase letters after the last digit (suffixes like K, KS, KF, F, T, H)
    m_suffix = re.match(r'^(.*[0-9])[A-Z]*$', stripped)
    stripped_clean = m_suffix.group(1) if m_suffix else stripped

    # 3. Find prefix-match against packageIntel models
    for entry in package_intel:
        if entry["model"]:
            db_model = entry["model"]
            m_db = re.match(r'^(.*[0-9])[A-Z]*$', db_model)
            db_clean = m_db.group(1) if m_db else db_model

            if stripped_clean.startswith(db_clean):
                return entry["socket"]

    return None

def map_cpu_to_socket(cpu_brand: str, package_intel: list[dict]) -> tuple[str, str] | None:
    """Maps CPU brand string to its socket and vendor using the Nix database algorithms."""
    cpu = cpu_brand.upper()

    if "INTEL" in cpu:
        socket = detect_intel_socket(cpu_brand, package_intel)
        if socket:
            return socket, "intel"

    elif "AMD" in cpu or "RYZEN" in cpu or "EPYC" in cpu:
        socket = detect_amd_socket(cpu_brand)
        if socket:
            return socket, "amd"

    return None

# ── Parser Engine ──────────────────────────────────────────────────────────

def parse_dmidecode_file(filepath: str, package_intel: list[dict]) -> dict | None:
    """Parse raw DMI dump and extract motherboard profile data."""
    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception as e:
        print(f"# Error reading {filepath}: {e}", file=sys.stderr)
        return None

    # Regex matches for each SMBIOS type block. The trailing comma in
    # 'DMI type N,' anchors the match so type 1 doesn't match type 11, etc.
    type0_match  = re.search(r"Handle 0x[0-9A-Fa-f]+, DMI type 0,.*?\n\n", content, re.DOTALL)
    type1_match  = re.search(r"Handle 0x[0-9A-Fa-f]+, DMI type 1,.*?\n\n", content, re.DOTALL)
    type2_match  = re.search(r"Handle 0x[0-9A-Fa-f]+, DMI type 2,.*?\n\n", content, re.DOTALL)
    type3_match  = re.search(r"Handle 0x[0-9A-Fa-f]+, DMI type 3,.*?\n\n", content, re.DOTALL)
    type4_match  = re.search(r"Handle 0x[0-9A-Fa-f]+, DMI type 4,.*?\n\n", content, re.DOTALL)
    type11_match = re.search(r"Handle 0x[0-9A-Fa-f]+, DMI type 11,.*?\n\n", content, re.DOTALL)

    if not (type2_match and type4_match):
        return None

    type0_text  = type0_match.group(0)  if type0_match  else ""
    type1_text  = type1_match.group(0)  if type1_match  else ""
    type2_text  = type2_match.group(0)
    type3_text  = type3_match.group(0)  if type3_match  else ""
    type4_text  = type4_match.group(0)
    type11_text = type11_match.group(0) if type11_match else ""

    # Baseboard fields
    m_manufacturer = re.search(r"Manufacturer:\s*(.*)", type2_text)
    m_product = re.search(r"Product Name:\s*(.*)", type2_text)
    m_version = re.search(r"Version:\s*(.*)", type2_text)
    m_family = re.search(r"Family:\s*(.*)", type2_text)

    raw_manufacturer = clean_string(m_manufacturer.group(1)) if m_manufacturer else ""
    product = clean_string(m_product.group(1)) if m_product else ""
    version = clean_string(m_version.group(1)) if m_version else ""
    family = clean_string(m_family.group(1)) if m_family else ""

    # Sanitize motherboard product names to exclude generic placeholders
    if not product or product.lower() in {"base board product name", "motherboard", "default string"}:
        return None

    # Match manufacturer to standard Nix ID
    m_id = MANUFACTURER_MAP.get(raw_manufacturer.lower())
    if not m_id:
        return None
    manufacturer = SMBIOS_MANUFACTURERS[m_id]

    # CPU field → Socket matching via Nix db
    m_cpu = re.search(r"Version:\s*(.*)", type4_text)
    if not m_cpu:
        return None
    cpu_string = clean_string(m_cpu.group(1))

    socket_info = map_cpu_to_socket(cpu_string, package_intel)
    if not socket_info:
        return None
    socket, cpu_vendor = socket_info

    # Enforce supported-sockets boundary
    if socket not in SUPPORTED_SOCKETS:
        return None

    # ── Type 0 (BIOS) ──────────────────────────────────────────────────────
    # biosVersion: existing field (BIOS Version string, e.g. "1604")
    # biosDate:    NEW — BIOS Release Date (mm/dd/yyyy). libvirt's `<bios date=...>`.
    # biosRelease: NEW — BIOS Revision (major.minor, e.g. "16.4"). libvirt's `<bios release=...>`.
    bios_version = ""
    bios_date = ""
    bios_release = ""
    if type0_text:
        m_bios = re.search(r"Version:\s*(.*)", type0_text)
        if m_bios:
            bios_version = clean_string(m_bios.group(1))
        m_date = re.search(r"Release Date:\s*(.*)", type0_text)
        if m_date:
            bios_date = raw_string(m_date.group(1))
        m_rel = re.search(r"BIOS Revision:\s*(.*)", type0_text)
        if m_rel:
            bios_release = raw_string(m_rel.group(1))

    # ── Type 1 (System) ───────────────────────────────────────────────────
    # Extracted SEPARATELY from Type 2. Real hardware typically has placeholders
    # here ("System Product Name", "To be filled by O.E.M.") while Type 2 has the
    # real board model. We preserve placeholders verbatim via raw_string() —
    # synthesizing Type 1 values from Type 2 would create a fingerprint that real
    # hardware never produces. Serial and UUID are NOT extracted here: they stay
    # synthetic (derived from hwidSeed at guest-XML-generation time).
    system_manufacturer = ""
    system_product      = ""
    system_version      = ""
    system_family       = ""
    system_sku          = ""
    if type1_text:
        m = re.search(r"Manufacturer:\s*(.*)", type1_text)
        if m: system_manufacturer = raw_string(m.group(1))
        m = re.search(r"Product Name:\s*(.*)", type1_text)
        if m: system_product = raw_string(m.group(1))
        m = re.search(r"Version:\s*(.*)", type1_text)
        if m: system_version = raw_string(m.group(1))
        m = re.search(r"Family:\s*(.*)", type1_text)
        if m: system_family = raw_string(m.group(1))
        m = re.search(r"SKU Number:\s*(.*)", type1_text)
        if m: system_sku = raw_string(m.group(1))

    # ── Type 2 (Baseboard) additions ──────────────────────────────────────
    # Asset Tag and Location In Chassis are new. Like other Type 2 fields, they
    # are typically placeholders on retail boards ("--", "Default string").
    board_asset    = ""
    board_location = ""
    m = re.search(r"Asset Tag:\s*(.*)", type2_text)
    if m: board_asset = raw_string(m.group(1))
    m = re.search(r"Location In Chassis:\s*(.*)", type2_text)
    if m: board_location = raw_string(m.group(1))

    # ── Type 3 (Chassis) ──────────────────────────────────────────────────
    # On retail desktop boards, ALL Type 3 fields are typically placeholders.
    # We preserve them verbatim. libvirt exposes: manufacturer, version, serial,
    # asset, sku.
    chassis_manufacturer = ""
    chassis_version      = ""
    chassis_serial       = ""
    chassis_asset        = ""
    chassis_sku          = ""
    if type3_text:
        m = re.search(r"Manufacturer:\s*(.*)", type3_text)
        if m: chassis_manufacturer = raw_string(m.group(1))
        m = re.search(r"Version:\s*(.*)", type3_text)
        if m: chassis_version = raw_string(m.group(1))
        m = re.search(r"Serial Number:\s*(.*)", type3_text)
        if m: chassis_serial = raw_string(m.group(1))
        m = re.search(r"Asset Tag:\s*(.*)", type3_text)
        if m: chassis_asset = raw_string(m.group(1))
        m = re.search(r"SKU Number:\s*(.*)", type3_text)
        if m: chassis_sku = raw_string(m.group(1))

    # ── Type 11 (OEM Strings) ─────────────────────────────────────────────
    # Highly vendor-specific strings (ASUS often carries internal codenames like
    # "TIKTOK" as String 3). High-signal fingerprint — must be kept atomic with
    # the rest of the probe (never mix strings from different probes).
    oem_strings: list[str] = []
    if type11_text:
        for m in re.finditer(r"String \d+:\s*(.*)", type11_text):
            oem_strings.append(raw_string(m.group(1)))

    # ── Content Quality Filter ────────────────────────────────────────────
    # Real retail boards often use placeholders ("System Product Name", "Default string").
    # We MUST preserve them for plausible deniability (e.g. 68% of real ASUS
    # boards use "System Product Name" for Type 1 Product).
    # But some probes have literally NOTHING beyond the Baseboard info. We drop
    # profiles that have NO real Type 1 product, NO real Type 3 manufacturer,
    # AND NO real OEM strings.
    def is_real(val: str) -> bool:
        if not val: return False
        v = val.lower().strip()
        return v not in {"default string", "to be filled by o.e.m.", "system product name", "system version", "--", "sku", "none", "unknown"}

    real_t1  = is_real(system_product) or is_real(system_manufacturer)
    real_t3  = is_real(chassis_manufacturer) or is_real(chassis_version)
    real_t11 = any(is_real(s) for s in oem_strings)

    if not (real_t1 or real_t3 or real_t11):
        return None  # Drop "Zero" quality profiles

    chipset = extract_chipset(product)

    return {
        # ── Existing fields (unchanged) ───────────────────────────────────
        "manufacturerId": m_id,
        "manufacturer": manufacturer,
        "product": product,
        "version": version if version else "Rev 1.xx",
        "family": family if family else (manufacturer.split()[0] + " System"),
        "socket": socket,
        "chipset": chipset,
        "cpuVendor": cpu_vendor,
        "biosVersion": bios_version if bios_version else "1001",
        # ── Type 0 additions ───────────────────────────────────────────────
        "biosDate": bios_date,        # mm/dd/yyyy — libvirt `<bios date=...>`
        "biosRelease": bios_release,  # major.minor  — libvirt `<bios release=...>`
        # ── Type 1 (System) — separate from Type 2, placeholders preserved ─
        "systemManufacturer": system_manufacturer,
        "systemProduct":      system_product,
        "systemVersion":      system_version,
        "systemFamily":       system_family,
        "systemSku":           system_sku,
        # ── Type 2 (Baseboard) additions ──────────────────────────────────
        "boardAsset":    board_asset,
        "boardLocation": board_location,
        # ── Type 3 (Chassis) ─────────────────────────────────────────────
        "chassisManufacturer": chassis_manufacturer,
        "chassisVersion":      chassis_version,
        "chassisSerial":       chassis_serial,
        "chassisAsset":        chassis_asset,
        "chassisSku":          chassis_sku,
        # ── Type 11 (OEM Strings) — atomic per probe ──────────────────────
        "oemStrings": oem_strings,
    }

# ──────────────────────────────────────────────────────────────────────────

def perform_sparse_checkout(tmpdir: str) -> str:
    """Clones DMI sparsely to extract ONLY target manufacturer dirs."""
    print(f"# Initializing sparse clone of linuxhw/DMI to {tmpdir}", file=sys.stderr)
    subprocess.run(["git", "clone", "--depth=1", "--no-checkout", "--filter=blob:none", DMI_REPO_URL, "DMI"], cwd=tmpdir, check=True)
    repo_path = os.path.join(tmpdir, "DMI")

    subprocess.run(["git", "sparse-checkout", "init", "--cone"], cwd=repo_path, check=True)
    subprocess.run(["git", "sparse-checkout", "set"] + TARGET_PATHS, cwd=repo_path, check=True)
    subprocess.run(["git", "checkout"], cwd=repo_path, check=True)
    return repo_path

def scan_and_compile(repo_path: str, package_intel: list[dict]) -> list[dict]:
    """Walk directories, extract profiles, and resolve deduplications."""
    profiles = {}
    print("# Scanning and compiling profiles...", file=sys.stderr)

    for target in TARGET_PATHS:
        target_dir = os.path.join(repo_path, target)
        if not os.path.exists(target_dir):
            continue

        for root, _, files in os.walk(target_dir):
            for file in files:
                # Leaf files in this repo contain raw dmidecode hex files named by HWID
                if len(file) == 12 and all(c in "0123456789ABCDEFabcdef" for c in file):
                    filepath = os.path.join(root, file)
                    prof = parse_dmidecode_file(filepath, package_intel)
                    if prof:
                        # Deduplicate by (manufacturerId, product, socket).
                        #
                        # ATOMICITY: when two probes share the same key, we replace the
                        # WHOLE record — never individual fields. This preserves
                        # whole-probe coherence: the Type 11 OEM strings, Type 2 board
                        # model, and Type 0 BIOS version from the *same* probe stay
                        # together. Mixing fields across probes would produce a
                        # Frankenstein fingerprint (e.g. an ASUS board with Gigabyte OEM
                        # strings) that's worse than missing the fields entirely.
                        key = (prof["manufacturerId"], prof["product"].lower(), prof["socket"])
                        if key not in profiles:
                            profiles[key] = prof
                        else:
                            # Prefer profiles with more OEM strings (Type 11 is high-signal
                            # and vendor-specific), then fuller BIOS versions, then any
                            # board version when the existing one is empty.
                            existing = profiles[key]
                            prof_oem      = len(prof.get("oemStrings", []))
                            existing_oem  = len(existing.get("oemStrings", []))
                            prof_bv_len  = len(prof["biosVersion"])
                            existing_bv_len = len(existing["biosVersion"])
                            if (prof_oem > existing_oem
                                or (prof_oem == existing_oem and prof_bv_len > existing_bv_len)
                                or (prof_oem == existing_oem and prof_bv_len == existing_bv_len
                                    and not existing["version"] and prof["version"])):
                                profiles[key] = prof

    return sorted(profiles.values(), key=lambda x: (x["manufacturerId"], x["socket"], x["product"]))

# ── Nix Emission ───────────────────────────────────────────────────────────

def emit_nix(profiles: list[dict], date: str) -> str:
    """Formats Python profile dicts as beautiful Nix code."""

    # Group profiles for efficient Nix evaluation O(1) lookups
    # Structure: { manufacturerId = { cpuVendor = { socket = [ { ... }, ... ] } } }
    grouped = {}
    for p in profiles:
        m_id = p["manufacturerId"]
        vendor = p["cpuVendor"]
        sock = p["socket"]

        if m_id not in grouped:
            grouped[m_id] = {}
        if vendor not in grouped[m_id]:
            grouped[m_id][vendor] = {}
        if sock not in grouped[m_id][vendor]:
            grouped[m_id][vendor][sock] = []

        grouped[m_id][vendor][sock].append(p)

    lines = []
    lines.append("# ──────────────────────────────────────────────────────────────────────────")
    lines.append("# smbios-profiles.nix — Curated motherboard hardware profile library.")
    lines.append("#")
    lines.append("# AUTO-GENERATED by scripts/sync-motherboard-db.py — DO NOT EDIT BY HAND.")
    lines.append(f"# Synced:  {date}")
    lines.append("# Source:  https://github.com/linuxhw/DMI")
    lines.append("# ──────────────────────────────────────────────────────────────────────────")
    lines.append("")
    lines.append("{")

    for m_id, vendors in grouped.items():
        lines.append(f'  "{m_id}" = {{')
        for vendor, sockets in vendors.items():
            lines.append(f'    "{vendor}" = {{')
            for sock, profs in sockets.items():
                lines.append(f'      "{sock}" = [')
                for p in profs:
                    lines.append("        {")
                    lines.append(f'          manufacturerId = "{nix_escape(p["manufacturerId"])}";')
                    lines.append(f'          manufacturer = "{nix_escape(p["manufacturer"])}";')
                    lines.append(f'          product = "{nix_escape(p["product"])}";')
                    lines.append(f'          version = "{nix_escape(p["version"])}";')
                    lines.append(f'          family = "{nix_escape(p["family"])}";')
                    lines.append(f'          socket = "{nix_escape(p["socket"])}";')
                    if p["chipset"]:
                        lines.append(f'          chipset = "{nix_escape(p["chipset"])}";')
                    else:
                        lines.append('          chipset = "";')
                    lines.append(f'          cpuVendor = "{nix_escape(p["cpuVendor"])}";')
                    lines.append(f'          biosVersion = "{nix_escape(p["biosVersion"])}";')
                    # Type 0 additions
                    lines.append(f'          biosDate = "{nix_escape(p["biosDate"])}";')
                    lines.append(f'          biosRelease = "{nix_escape(p["biosRelease"])}";')
                    # Type 1 (System) — placeholders preserved verbatim
                    lines.append(f'          systemManufacturer = "{nix_escape(p["systemManufacturer"])}";')
                    lines.append(f'          systemProduct = "{nix_escape(p["systemProduct"])}";')
                    lines.append(f'          systemVersion = "{nix_escape(p["systemVersion"])}";')
                    lines.append(f'          systemFamily = "{nix_escape(p["systemFamily"])}";')
                    lines.append(f'          systemSku = "{nix_escape(p["systemSku"])}";')
                    # Type 2 (Baseboard) additions
                    lines.append(f'          boardAsset = "{nix_escape(p["boardAsset"])}";')
                    lines.append(f'          boardLocation = "{nix_escape(p["boardLocation"])}";')
                    # Type 3 (Chassis)
                    lines.append(f'          chassisManufacturer = "{nix_escape(p["chassisManufacturer"])}";')
                    lines.append(f'          chassisVersion = "{nix_escape(p["chassisVersion"])}";')
                    lines.append(f'          chassisSerial = "{nix_escape(p["chassisSerial"])}";')
                    lines.append(f'          chassisAsset = "{nix_escape(p["chassisAsset"])}";')
                    lines.append(f'          chassisSku = "{nix_escape(p["chassisSku"])}";')
                    # Type 11 (OEM Strings) — Nix list of strings
                    if p["oemStrings"]:
                        strs = " ".join(f'"{nix_escape(s)}"' for s in p["oemStrings"])
                        lines.append(f'          oemStrings = [ {strs} ];')
                    else:
                        lines.append('          oemStrings = [ ];')
                    lines.append("        }")
                lines.append("      ];")
            lines.append("    };")
        lines.append("  };")

    lines.append("}")
    lines.append("")
    return "\n".join(lines)

# ── Main ───────────────────────────────────────────────────────────────────

def main() -> int:
    import datetime
    date = datetime.date.today().isoformat()

    # Load cpu-packages.nix relative to script directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    nix_filepath = os.path.normpath(os.path.join(script_dir, "../modules/kvm/host/cpu-packages.nix"))

    print(f"# Loading CPU database from {nix_filepath}", file=sys.stderr)
    package_intel, _ = parse_cpu_packages(nix_filepath)
    if not package_intel:
        print("# Error: Could not parse cpu-packages.nix.", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            repo_path = perform_sparse_checkout(tmpdir)
            profiles = scan_and_compile(repo_path, package_intel)
            print(f"# Compiled {len(profiles)} unique profiles.", file=sys.stderr)

            # ── Step 2b: merge curated fallbacks for empty cells ───────────────
            # Only add a fallback for a (manufacturerId, socket) cell that is
            # empty after the Step 2a quality filter — never overwrite a real
            # mined profile. See scripts/fallback-smbios.py for the rationale
            # behind which cells are filled vs. intentionally left empty.
            fallbacks = load_fallbacks()
            if fallbacks:
                present = {(p["manufacturerId"], p["socket"]) for p in profiles}
                added = 0
                for (m_id, socket), fb_list in fallbacks.items():
                    if (m_id, socket) not in present:
                        profiles.extend(fb_list)
                        added += len(fb_list)
                if added:
                    # Re-sort to keep deterministic output (scan_and_compile
                    # returned a sorted list; the extend above broke that).
                    profiles.sort(key=lambda x: (x["manufacturerId"], x["socket"], x["product"]))
                print(f"# Merged {added} curated fallback profiles for empty cells.",
                      file=sys.stderr)
                print(f"# Total profiles after fallback merge: {len(profiles)}.",
                      file=sys.stderr)

            nix_output = emit_nix(profiles, date)

            out_path = os.path.normpath(os.path.join(script_dir, "../modules/kvm/host/smbios-profiles.nix"))
            print(f"# Writing output to {out_path}", file=sys.stderr)
            with open(out_path, "w") as f:
                f.write(nix_output)
        except subprocess.CalledProcessError as e:
            print(f"# Git command failed: {e}", file=sys.stderr)
            return 1
        except Exception as e:
            print(f"# Sync failed with error: {e}", file=sys.stderr)
            return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
