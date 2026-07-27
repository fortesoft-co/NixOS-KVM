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

# ── Custom gap-filler + fallback entries ────────────────────────────────
# The curated fallback data (gap-fillers CPU-X missed + generation-level
# backstops for common modern desktop/workstation CPUs) lives in a separate
# module so this script stays focused on parse/emit logic. The fallback
# entries are emitted AFTER the CPU-X entries, so specific CPU-X matches
# win via findFirst and the fallbacks only fill gaps.
# Edit fallback data in scripts/fallback-cpu-db.py.
import importlib.util
import pathlib

_FB_PATH = pathlib.Path(__file__).resolve().parent / "fallback-cpu-db.py"
_spec = importlib.util.spec_from_file_location("fallback_cpu_db", _FB_PATH)
_fb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fb)
CUSTOM_INTEL = _fb.FALLBACK_INTEL
CUSTOM_AMD = _fb.FALLBACK_AMD
SOCKET_OVERRIDES = _fb.SOCKET_OVERRIDES


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
    lines.append("# (Gap-filler + fallback entries are emitted from scripts/fallback-cpu-db.py.)")
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
    lines.append("# Gap-filler + fallback entries are appended after the CPU-X")
    lines.append("# entries with '# CUSTOM' markers. Edit them in scripts/fallback-cpu-db.py.")
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
        lines.append("    # CUSTOM — gap-filler + fallback entries (see scripts/fallback-cpu-db.py)")
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
        lines.append("    # CUSTOM — gap-filler + fallback entries (see scripts/fallback-cpu-db.py)")
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