#!/usr/bin/env python3
"""
sync-cpu-db.py — Translate CPU-X's databases.h to a Nix attribute set.

Downloads `src/core/databases.h` from the CPU-X GitHub repository, parses the
`package_intel[]` and `package_amd[]` C struct arrays, normalizes socket names,
and emits a Nix file (`cpu-packages.nix`) that can be imported directly by the
KVM module's socket detection pipeline.

Usage:
    python3 scripts/sync-cpu-db.py > modules/kvm/host/cpu-packages.nix

The generated file is pure data — no IFD, no parsing at eval time.  To update
when CPU-X adds new CPUs, re-run this script and commit the diff.

The CPU-X commit hash and date are embedded in the generated file's header
for traceability.
"""

import re
import sys
import os
import urllib.request
import datetime

# ── Configuration ──────────────────────────────────────────────────────────

CPU_X_REPO = "TheTumultuousUnicornOfDarkness/CPU-X"
DATABASES_H_PATH = "src/core/databases.h"

# Raw GitHub URL for the file.
RAW_URL = f"https://raw.githubusercontent.com/{CPU_X_REPO}/master/{DATABASES_H_PATH}"

# API URL to get the latest commit hash (for the header).
COMMIT_API_URL = f"https://api.github.com/repos/{CPU_X_REPO}/commits/master"

# ── Custom gap-filler entries ─────────────────────────────────────────────
# These entries are NOT in CPU-X's databases.h upstream.  They cover CPUs that
# CPU-X missed (mostly Intel server/workstation).  They are sourced from the
# regex heuristic in host/lib.nix and are emitted after the CPU-X entries with
# a '# CUSTOM' comment so they are visually distinct in the generated file.
# To add more gap-fillers, append to these lists.

# ── Socket overrides ──────────────────────────────────────────────────────
# CPU-X sometimes maps a codename to the wrong socket.  These overrides
# replace the socket value for specific CPU-X entries (matched by codename).
# The override is applied during emission — the entry stays in its original
# position in the list but with the corrected socket.
SOCKET_OVERRIDES = {
    # CPU-X returns "SP3r2" for all three Threadripper 1000-3000 codenames,
    # but sTR4 (1000/2000) and sTRX4 (3000) are physically different, non-
    # compatible sockets.  Correct the distinction:
    "Whitehaven":   "sTR4",    # Threadripper 1000 (X399 chipset)
    "Colfax":       "sTR4",    # Threadripper 2000 (X399 chipset)
    "Castle Peak":  "sTRX4",   # Threadripper 3000 (TRX40 chipset)
}

CUSTOM_INTEL = [
    # Xeon Scalable 4th gen (Sapphire Rapids) → LGA4677
    # Brand strings: tier (8=Platinum, 6=Gold, 5/4=Silver/Bronze) + 2nd digit = gen (4).
    { "codename": None, "model": "Intel(R) Xeon(R) Platinum 84", "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Gold 64",    "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Silver 44",  "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Bronze 34",  "socket": "LGA4677" },
    # Xeon Scalable 5th gen (Emerald Rapids)
    { "codename": None, "model": "Intel(R) Xeon(R) Platinum 85", "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Gold 65",    "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Silver 45",  "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Bronze 35",  "socket": "LGA4677" },
    # Xeon Scalable 6th gen (Granite Rapids) → LGA4710 (new socket, not LGA4677)
    # Granite Rapids uses a NEW model numbering: "6" prefix = generation 6, replacing
    # the old convention where the first digit was the tier (8=Platinum, 6=Gold, etc.).
    # SKUs: Platinum 69xx, Gold 69xx/67xx, Silver 66xx, Bronze 65xx.
    # The tier name in the brand string disambiguates from older generations
    # (e.g. old Gold 61xx-65xx used LGA3647/LGA4677, but new Gold 69xx/67xx uses LGA4710).
    { "codename": None, "model": "Intel(R) Xeon(R) Platinum 69", "socket": "LGA4710" },
    { "codename": None, "model": "Intel(R) Xeon(R) Gold 69",     "socket": "LGA4710" },
    { "codename": None, "model": "Intel(R) Xeon(R) Gold 67",     "socket": "LGA4710" },
    { "codename": None, "model": "Intel(R) Xeon(R) Silver 66",  "socket": "LGA4710" },
    { "codename": None, "model": "Intel(R) Xeon(R) Bronze 65",  "socket": "LGA4710" },
    # Xeon W-2400/3400/2500/3500 (Sapphire Rapids-WS) → LGA4677
    # New naming: lowercase 'w' + tier digit + hyphen (e.g. w3-2435, w7-3495X).
    { "codename": None, "model": "Intel(R) Xeon(R) w", "socket": "LGA4677" },
    # Old Xeon W (LGA2066): W-2100/2150/2170/2250/2270/3175X
    # Brand format: uppercase W- + 4-digit model.
    { "codename": None, "model": "Intel(R) Xeon(R) W-", "socket": "LGA2066" },
]

CUSTOM_AMD = [
    # EPYC Siena (Zen 4c, 8004 series) → SP6
    # libcpuid may return codename 'Genoa' for these (same CPUID family/model),
    # but the brand string starts with 'AMD EPYC 8' (vs 'AMD EPYC 9' for Genoa/Turin).
    { "codename": "Siena", "model": None,        "socket": "SP6" },
    { "codename": None,    "model": "AMD EPYC 8", "socket": "SP6" },
]


# ── Socket name normalization ──────────────────────────────────────────────

def normalize_socket(raw: str) -> str:
    """
    Normalize a CPU-X socket string to the canonical form used by the KVM
    module's profile library.

    CPU-X uses forms like:
      "AM4 (PGA-1331)"          → "AM4"
      "SP3 (LGA-4094)"          → "SP3"
      "LGA 1700"                → "LGA1700"
      "sWRX8 (LGA-4094)"        → "sWRX8"
      "sTR5 (LGA-4844)"         → "sTR5"
      "SP3r2 (LGA-4094)"        → "SP3r2"

    Rules:
      1. Strip anything in parentheses (pin-count suffixes).
      2. Strip leading/trailing whitespace.
      3. Collapse "LGA NNNN" → "LGANNNN" (no space).
      4. Leave everything else as-is (AM4, AM5, SP3, SP5, sTR5, sWRX8, etc.).
    """
    s = raw.strip()
    # Strip parenthetical suffix: "AM4 (PGA-1331)" → "AM4"
    s = re.sub(r"\s*\([^)]*\)", "", s).strip()
    # Normalize "LGA NNNN" → "LGANNNN"
    s = re.sub(r"\bLGA\s+(\d+)\b", r"LGA\1", s)
    return s


# ── C struct parsing ───────────────────────────────────────────────────────

# Matches lines like:
#   { "Raphael",        NULL,  "AM5 (LGA-1718)" },
#   { NULL,             "Intel(R) Core(TM) i9-13900K",  "LGA 1700" },
#   { "Athlon 64 FX X2 (Toledo)", NULL, "939 (PGA-939)" },
ENTRY_RE = re.compile(
    r'^\s*\{\s*'
    r'(?P<codename>"[^"]*"|NULL)\s*,\s*'
    r'(?P<model>"[^"]*"|NULL)\s*,\s*'
    r'(?P<socket>"[^"]*"|NULL)'
    r'(?:\s*,\s*)?'   # optional trailing fields (comments, etc.)
    r'\s*\}',
    re.MULTILINE,
)


def parse_value(v: str) -> str | None:
    """Convert a C string literal or NULL to a Python string or None."""
    v = v.strip()
    if v == "NULL":
        return None
    # Strip surrounding quotes, unescape
    return v[1:-1].replace('\\"', '"').replace('\\n', '\n')


def parse_array(text: str, array_name: str) -> list[dict]:
    """
    Extract all entries from a `const Package_DB array_name[] = { ... };` block.
    Returns a list of {codename, model, socket} dicts (with None for missing fields).
    """
    # Find the array block (use string concat to avoid f-string brace issues)
    pattern = (r"const\s+Package_DB\s+"
               + re.escape(array_name)
               + r"\s*\[\s*\]\s*=\s*\{(.*?)\n\};")
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        raise ValueError(f"Could not find array '{array_name}' in databases.h")
    body = m.group(1)

    entries = []
    for em in ENTRY_RE.finditer(body):
        codename = parse_value(em.group("codename"))
        model = parse_value(em.group("model"))
        socket = parse_value(em.group("socket"))
        if socket is None:
            continue  # Skip the sentinel { NULL, NULL, NULL } terminator
        entries.append({
            "codename": codename,
            "model": model,
            "socket": normalize_socket(socket),
        })
    return entries


# ── Nix emission ───────────────────────────────────────────────────────────

def nix_string(s: str) -> str:
    """Escape a Python string as a Nix double-quoted string."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def emit_nix(intel: list[dict], amd: list[dict], commit: str, date: str) -> str:
    """Emit the full Nix file content."""
    lines = []
    lines.append("# ──────────────────────────────────────────────────────────────────────────")
    lines.append("# cpu-packages.nix — CPU codename/brand → socket mapping database.")
    lines.append("#")
    lines.append("# AUTO-GENERATED by scripts/sync-cpu-db.py — DO NOT EDIT BY HAND.")
    lines.append("# (Custom gap-filler entries are emitted by the script from CUSTOM_INTEL/CUSTOM_AMD.)")
    lines.append("#")
    lines.append(f"# Source:  https://github.com/{CPU_X_REPO}/blob/master/{DATABASES_H_PATH}")
    lines.append(f"# Commit:  {commit[:12]}")
    lines.append(f"# Synced:  {date}")
    lines.append("#")
    lines.append("# This file is a Nix translation of CPU-X's `databases.h` Package_DB tables.")
    lines.append("# Each entry maps a CPU codename OR brand-string prefix to its socket family,")
    lines.append("# used by the KVM module's socket detection pipeline (layer 2):")
    lines.append("#")
    lines.append("#   cpuid_tool --codename → codename → lookup here → socket")
    lines.append("#   cpuid_tool --brandstr → brandstr → prefix-match here → socket")
    lines.append("#")
    lines.append("# Socket names are normalized: pin-count suffixes stripped,")
    lines.append("# 'LGA NNNN' collapsed to 'LGANNNN'. See normalize_socket() in the sync script.")
    lines.append("#")
    lines.append("# Gap-filler entries (not in CPU-X upstream) are appended after the CPU-X")
    lines.append("# entries with '# CUSTOM' markers. Edit them in scripts/sync-cpu-db.py.")
    lines.append("# ──────────────────────────────────────────────────────────────────────────")
    lines.append("")
    lines.append("{ lib }:")
    lines.append("with lib;")
    lines.append("{")
    lines.append("  # ─── Intel: keyed by brand-string prefix match ───")
    lines.append("  # libcpuid returns codenames like 'Core i9 (Raptor Lake-S)' for Intel, but")
    lines.append("  # CPU-X's database uses brand strings (e.g. 'Intel(R) Core(TM) i9-13900K').")
    lines.append("  # Matching: strip the '13th Gen ' prefix and any K/KS/KF/F/T/H suffixes,")
    lines.append("  # then prefix-match the base model number against entries below.")
    lines.append("  packageIntel = [")
    for e in intel:
        cn = nix_string(e["codename"]) if e["codename"] else "null"
        md = nix_string(e["model"]) if e["model"] else "null"
        sk = nix_string(e["socket"])
        lines.append(f"    {{ codename = {cn}; model = {md}; socket = {sk}; }}")
    if CUSTOM_INTEL:
        lines.append("    # CUSTOM — gap-filler entries (not in CPU-X upstream)")
        for e in CUSTOM_INTEL:
            cn = nix_string(e["codename"]) if e["codename"] else "null"
            md = nix_string(e["model"]) if e["model"] else "null"
            sk = nix_string(e["socket"])
            lines.append(f"    {{ codename = {cn}; model = {md}; socket = {sk}; }}")
    lines.append("  ];")
    lines.append("")
    lines.append("  # ─── AMD: keyed by codename exact match ───")
    lines.append("  # libcpuid returns codenames like 'Ryzen 9 (Raphael)' for AMD.")
    lines.append("  # Extract the parenthesized codename and exact-match against entries below.")
    lines.append("  packageAmd = [")
    for e in amd:
        cn = nix_string(e["codename"]) if e["codename"] else "null"
        md = nix_string(e["model"]) if e["model"] else "null"
        # Apply socket override if this codename is in SOCKET_OVERRIDES
        sk_val = e["socket"]
        if e["codename"] and e["codename"] in SOCKET_OVERRIDES:
            sk_val = SOCKET_OVERRIDES[e["codename"]]
        sk = nix_string(sk_val)
        lines.append(f"    {{ codename = {cn}; model = {md}; socket = {sk}; }}")
    if CUSTOM_AMD:
        lines.append("    # CUSTOM — gap-filler entries (not in CPU-X upstream)")
        for e in CUSTOM_AMD:
            cn = nix_string(e["codename"]) if e["codename"] else "null"
            md = nix_string(e["model"]) if e["model"] else "null"
            sk = nix_string(e["socket"])
            lines.append(f"    {{ codename = {cn}; model = {md}; socket = {sk}; }}")
    lines.append("  ];")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


# ── Main ───────────────────────────────────────────────────────────────────

def fetch_commit_hash() -> str:
    """Fetch the latest commit hash from the GitHub API."""
    try:
        req = urllib.request.Request(COMMIT_API_URL, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            import json
            data = json.loads(resp.read().decode())
            return data.get("sha", "unknown")
    except Exception as e:
        print(f"# Warning: could not fetch commit hash ({e}), using 'unknown'", file=sys.stderr)
        return "unknown"


def main() -> int:
    commit = fetch_commit_hash()
    date = datetime.date.today().isoformat()

    print(f"# Fetching {RAW_URL}", file=sys.stderr)
    req = urllib.request.Request(RAW_URL, headers={"Accept": "text/plain"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode("utf-8")

    print("# Parsing package_intel[] and package_amd[]", file=sys.stderr)
    intel = parse_array(text, "package_intel")
    amd = parse_array(text, "package_amd")

    print(f"# Intel entries: {len(intel)}", file=sys.stderr)
    print(f"# AMD entries:   {len(amd)}", file=sys.stderr)

    nix = emit_nix(intel, amd, commit, date)
    
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_path = os.path.normpath(os.path.join(script_dir, "../modules/kvm/host/cpu-packages.nix"))
    
    print(f"# Writing output to {out_path}", file=sys.stderr)
    with open(out_path, "w") as f:
        f.write(nix)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())