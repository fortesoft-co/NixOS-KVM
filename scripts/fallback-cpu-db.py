#!/usr/bin/env python3
"""
fallback-cpu-db.py — Curated fallback CPU package entries for the socket
detection database.

`sync-cpu-db.py` translates CPU-X's `databases.h` into `cpu-packages.nix`.
CPU-X is the CANONICAL reference for CPU → socket mapping. This module
provides curated fallback entries that are merged into the generated
`cpu-packages.nix` AFTER the CPU-X entries, so that:

  1. When CPU-X has a specific entry, it wins (findFirst returns it first).
  2. When CPU-X is missing, sparse, or drops an entry in a future commit,
     these fallbacks keep socket detection working for common modern
     desktop and workstation hardware.

Two kinds of entries live here, both emitted under the `# CUSTOM` marker:

  - **Gap-fillers** — CPUs CPU-X genuinely doesn't have (e.g. Xeon Scalable
    4th-6th gen, EPYC Siena). These are sourced from Intel/AMD's naming
    conventions and the regex heuristic in host/lib.nix.

  - **Backstops** — generation/family-level prefix entries for common
    desktop CPUs that CPU-X covers only sparsely (e.g. CPU-X has i5-12400
    but not i5-12600; the backstop `Intel(R) Core(TM) i5-12` catches the
    latter). Backstops use SHORT brand-string prefixes so a single entry
    covers every SKU in a (family, generation) pair. They cannot override
    a CPU-X entry that matches first — they only fill gaps.

DESIGN PRINCIPLES
────────────────

1. **CPU-X is canonical; we are resilience.** Never correct a CPU-X value
   here except via `SOCKET_OVERRIDES` (which fixes a known-wrong CPU-X
   socket by codename). The fallbacks exist so a future CPU-X commit that
   drops or changes a common entry doesn't silently break detection.

2. **Match the existing detection mechanism.** Intel entries use
   brand-string prefix match (`hasPrefix (stripSuffix e.model) stripped`
   in host/lib.nix), so Intel backstops are short brand-string prefixes.
   AMD entries use codename exact match, so AMD backstops are codenames.
   Don't mix the two styles within a vendor.

3. **Modern, broadly-used hardware only.** No ancient platforms (pre-Ryzen
   AMD, pre-Core-8th-gen Intel) and NO mobile. Mobile codenames (FP5/FP6/
   FP7/FT6/FL1/FP8/FP11 — Raven Ridge, Picasso, Renoir, Cezanne, Rembrandt,
   Dragon Range, Phoenix, Hawk Point, Mendocino, Strix*, Krackan) are
   intentionally excluded. The project doesn't support laptops (see
   Key Constraints). Including mobile sockets would be dead data at best
   and a misclassification risk at worst.

4. **One socket per (family, generation) for Intel desktop.** All i3/i5/
   i7/i9-NNxxx desktop SKUs in a generation share a socket (LGA1700 for
   12th-14th gen, LGA1200 for 10th-11th, LGA1151 for 8th-9th). A backstop
   like `Intel(R) Core(TM) i5-12` matches every 12th-gen i5 desktop SKU.
   Mobile SKUs of the same generation use different sockets, but mobile is
   out of scope — acceptable, and matches layer 3's existing behavior.

5. **Don't fabricate sockets.** If a vendor doesn't ship a retail board
   for a socket (e.g. nobody ships a consumer board for SP6 beyond Siena),
   that's a profile-library concern (see fallback-smbios.py), not a
   socket-detection concern. The socket is still real and detectable.

AMD DESKTOP-APU DISAMBIGUATION (handled in host/lib.nix, not here)
────────────────────────────────────────────────────────────────────────
AMD codename matching can't distinguish desktop from mobile when the same
codename covers both. The ambiguous codenames are Cezanne, Renoir, Picasso,
Raven Ridge (desktop G-suffix APU → AM4, mobile U/H-suffix → FP5/FP6) and
Phoenix (desktop 8600G/8700G → AM5, mobile → FP7/FP8). CPU-X maps all of
these to the MOBILE socket.

This is NOT fixed with fallback data here — it's fixed in detectSocketFromDatabase
(host/lib.nix): when a codename match returns a mobile socket (F[LPT][0-9].*)
AND the brand string shows a desktop-APU pattern (4-digit model + 'G', e.g.
5600G, 8600G), layer 2 returns null so the resolver falls through to layer 3
(detectAmdSocket), which has the Ryzen generation → AM4/AM5 logic. Mobile CPUs
(out of scope) keep CPU-X's mobile socket unchanged. Verified by the AMD
cases in test-cpu-socket.nix.

Because the fix defers to layer 3, the ambiguous APU codenames are
INTENTIONALLY NOT added to FALLBACK_AMD below — if CPU-X drops Cezanne, the
codename match returns null directly and the resolver still falls to layer 3.
No fallback entry is needed for the disambiguation to work.

COVERAGE
────────
Intel gap-fillers (moved from sync-cpu-db.py):
  Xeon Scalable 4th gen (Sapphire Rapids)  → LGA4677  (Platinum 84, Gold 64, Silver 44, Bronze 34)
  Xeon Scalable 5th gen (Emerald Rapids)  → LGA4677  (Platinum 85, Gold 65, Silver 45, Bronze 35)
  Xeon Scalable 6th gen (Granite Rapids)  → LGA4710  (Platinum 69, Gold 69/67, Silver 66, Bronze 65)
  Xeon W-2xxx/3xxx (Sapphire Rapids-WS)   → LGA4677  (lowercase 'w' brand prefix)
  Xeon W-2100..3175X (old)                → LGA2066  (uppercase 'W-' brand prefix)

Intel backstops (generation-level prefix):
  Core 8th-9th gen   (Coffee Lake)        → LGA1151  (i3/i5/i7-8xxx, i3/i5/i7/i9-9xxx)
  Core 10th-11th gen (Comet Lake/Rocket)  → LGA1200  (i3/i5/i7/i9-10xxx, i3/i5/i7/i9-11xxx)
  Core 12th-14th gen (Alder/Raptor)       → LGA1700  (i3/i5/i7/i9-12xxx/13xxx/14xxx)
  Core Ultra (Arrow Lake)                 → LGA1851  (brand prefix 'Intel(R) Core(TM) Ultra')

AMD gap-fillers:
  EPYC Siena (Zen 4c, 8004)               → SP6      (codename + brand prefix)

AMD backstops (codename exact match, copied from current cpu-packages.nix):
  AM4:   Summit Ridge (Zen 1), Pinnacle Ridge (Zen+), Matisse (Zen 2), Vermeer (Zen 3)
  AM5:   Raphael (Zen 4), Granite Ridge (Zen 5)
  sTR4:  Whitehaven (TR 1000), Colfax (TR 2000)
  sTRX4: Castle Peak (TR 3000)
  sWRX8: Chagall (TR PRO 3xxx/5xxx)
  sTR5:  Storm Peak, Shimada Peak (TR 7000+)
  SP3:   Naples, Rome, Milan (EPYC 7001-7003)
  SP5:   Genoa, Turin (EPYC 9004/9005)
  SP6:   Siena (EPYC 8004)

INTENTIONAL OMISSIONS
─────────────────────
  - Mobile AMD codenames (FP5/FP6/FP7/FT6/FL1/FP8/FP11) — out of scope.
  - Pre-Ryzen AMD (Deneb, Heka, Kabini, Turion, Athlon 64 FX, Phenom) — ancient.
  - Intel 6th-7th gen LGA1151 (Skylake/Kaby Lake) — older; layer 3 covers
    them (6th-9th gen → LGA1151) and CPU-X is stable for old hardware.
    Included 8th-9th gen only as the still-broadly-used LGA1151 cohort.
  - Intel mobile (BGA 1440, BGA 1744, rPGA 988B, etc.) — out of scope.
  - LGA775/LGA1155/LGA1150/LGA1366/LGA2011 — ancient/older; layer 3 or
    CPU-X covers them; not broadly in use for our target demographic.
  - Core Ultra mobile (Lunar Lake / Meteor Lake) — mobile, out of scope.

USAGE
─────
Imported by `sync-cpu-db.py` and merged after the CPU-X entries:

    from fallback_cpu_db import FALLBACK_INTEL, FALLBACK_AMD, SOCKET_OVERRIDES

The sync script emits CPU-X entries first, then the `# CUSTOM` block
containing these entries. `findFirst` in host/lib.nix returns the first
match, so specific CPU-X entries win and fallbacks only fill gaps.
"""

# ── Socket overrides for CPU-X entries (applied by codename) ──────────────
# CPU-X sometimes maps a codename to the wrong socket. These overrides
# replace the socket value for the matching CPU-X entry during emission.
# The entry stays in its original position but with the corrected socket.
# NOTE: the fallback AMD entries below already use the corrected socket,
# so if CPU-X drops the entry entirely, the fallback carries the fix.
SOCKET_OVERRIDES = {
    # CPU-X returns "SP3r2" for all three Threadripper 1000-3000 codenames,
    # but sTR4 (1000/2000) and sTRX4 (3000) are physically different, non-
    # compatible sockets. Correct the distinction:
    "Whitehaven":   "sTR4",    # Threadripper 1000 (X399 chipset)
    "Colfax":       "sTR4",    # Threadripper 2000 (X399 chipset)
    "Castle Peak":  "sTRX4",   # Threadripper 3000 (TRX40 chipset)
}


# ── Intel fallback entries ────────────────────────────────────────────────
# Intel uses brand-string prefix match: strip "Nth Gen " + suffix letters
# (K/KS/KF/F/T/H), then hasPrefix (stripSuffix db_model) stripped_brandstr.
# Backstops use short prefixes so one entry covers a whole (family, gen).

FALLBACK_INTEL = [
    # ── Gap-fillers: Xeon Scalable (not in CPU-X upstream) ──
    # 4th gen (Sapphire Rapids) → LGA4677. Brand: tier + 2nd digit = gen (4).
    { "codename": None, "model": "Intel(R) Xeon(R) Platinum 84", "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Gold 64",    "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Silver 44",  "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Bronze 34",  "socket": "LGA4677" },
    # 5th gen (Emerald Rapids) → LGA4677.
    { "codename": None, "model": "Intel(R) Xeon(R) Platinum 85", "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Gold 65",    "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Silver 45",  "socket": "LGA4677" },
    { "codename": None, "model": "Intel(R) Xeon(R) Bronze 35",  "socket": "LGA4677" },
    # 6th gen (Granite Rapids) → LGA4710 (new socket, NOT LGA4677).
    # New numbering: "6" prefix = generation 6, replacing the old convention
    # where the first digit was the tier. Tier name disambiguates from older gens.
    { "codename": None, "model": "Intel(R) Xeon(R) Platinum 69", "socket": "LGA4710" },
    { "codename": None, "model": "Intel(R) Xeon(R) Gold 69",     "socket": "LGA4710" },
    { "codename": None, "model": "Intel(R) Xeon(R) Gold 67",     "socket": "LGA4710" },
    { "codename": None, "model": "Intel(R) Xeon(R) Silver 66",  "socket": "LGA4710" },
    { "codename": None, "model": "Intel(R) Xeon(R) Bronze 65",  "socket": "LGA4710" },
    # Xeon W-2400/3400/2500/3500 (Sapphire Rapids-WS) → LGA4677.
    # New naming: lowercase 'w' + tier digit + hyphen (e.g. w3-2435, w7-3495X).
    { "codename": None, "model": "Intel(R) Xeon(R) w", "socket": "LGA4677" },
    # Old Xeon W (LGA2066): W-2100/2150/2170/2250/2270/3175X. Uppercase W- + 4-digit.
    { "codename": None, "model": "Intel(R) Xeon(R) W-", "socket": "LGA2066" },

    # ── Backstops: Core desktop (generation-level prefix) ──
    # CPU-X carries only a few SKUs per generation; these backstops catch the
    # rest. A backstop like i5-12 matches every 12th-gen i5 desktop SKU
    # (12400, 12400F, 12600K, 12600KF, 12500, ...). Specific CPU-X entries
    # win via findFirst; these only match when no specific entry does.
    # Mobile shares these model numbers but is out of scope — same as
    # layer 3's existing behavior (detectIntelSocket ignores mobile suffixes).

    # LGA1151 (8th-9th gen — Coffee Lake; 6th-7th gen skipped as older).
    { "codename": None, "model": "Intel(R) Core(TM) i3-8", "socket": "LGA1151" },
    { "codename": None, "model": "Intel(R) Core(TM) i5-8", "socket": "LGA1151" },
    { "codename": None, "model": "Intel(R) Core(TM) i7-8", "socket": "LGA1151" },
    { "codename": None, "model": "Intel(R) Core(TM) i3-9", "socket": "LGA1151" },
    { "codename": None, "model": "Intel(R) Core(TM) i5-9", "socket": "LGA1151" },
    { "codename": None, "model": "Intel(R) Core(TM) i7-9", "socket": "LGA1151" },
    { "codename": None, "model": "Intel(R) Core(TM) i9-9", "socket": "LGA1151" },

    # LGA1200 (10th-11th gen — Comet Lake / Rocket Lake).
    { "codename": None, "model": "Intel(R) Core(TM) i3-10", "socket": "LGA1200" },
    { "codename": None, "model": "Intel(R) Core(TM) i5-10", "socket": "LGA1200" },
    { "codename": None, "model": "Intel(R) Core(TM) i7-10", "socket": "LGA1200" },
    { "codename": None, "model": "Intel(R) Core(TM) i9-10", "socket": "LGA1200" },
    { "codename": None, "model": "Intel(R) Core(TM) i3-11", "socket": "LGA1200" },
    { "codename": None, "model": "Intel(R) Core(TM) i5-11", "socket": "LGA1200" },
    { "codename": None, "model": "Intel(R) Core(TM) i7-11", "socket": "LGA1200" },
    { "codename": None, "model": "Intel(R) Core(TM) i9-11", "socket": "LGA1200" },

    # LGA1700 (12th-14th gen — Alder Lake / Raptor Lake / Raptor Refresh).
    { "codename": None, "model": "Intel(R) Core(TM) i3-12", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i5-12", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i7-12", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i9-12", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i3-13", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i5-13", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i7-13", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i9-13", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i3-14", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i5-14", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i7-14", "socket": "LGA1700" },
    { "codename": None, "model": "Intel(R) Core(TM) i9-14", "socket": "LGA1700" },

    # LGA1851 (Core Ultra — Arrow Lake, Series 2). One broad prefix; all
    # desktop Core Ultra is LGA1851. Layer 3 also handles this via the
    # "Ultra" infix, so this is belt-and-suspenders.
    { "codename": None, "model": "Intel(R) Core(TM) Ultra", "socket": "LGA1851" },
]


# ── AMD fallback entries ──────────────────────────────────────────────────
# AMD uses codename EXACT match: extractCodename(cpuid_tool --codename)
# then findFirst (e: e.codename == cn). Since a codename covers every SKU
# of an architecture, there's no sibling-SKU gap — either the codename is
# in the DB (all SKUs match) or it isn't. These entries are pure
# resilience: if CPU-X drops a modern codename in a future commit, the
# fallback keeps detection working. Sockets below are the CORRECTED
# values (post-SOCKET_OVERRIDES) so they're right even if CPU-X is dropped.

FALLBACK_AMD = [
    # ── Gap-filler: EPYC Siena (not in CPU-X upstream) ──
    # libcpuid may return codename 'Genoa' for these (same CPUID family/model),
    # but the brand string starts with 'AMD EPYC 8' (vs 'AMD EPYC 9' for Genoa).
    { "codename": "Siena", "model": None,        "socket": "SP6" },
    { "codename": None,    "model": "AMD EPYC 8", "socket": "SP6" },

    # ── Backstops: modern desktop / workstation / server codenames ──
    # Copied from the current cpu-packages.nix (synced 2026-07-20) with
    # SOCKET_OVERRIDES already applied. Mobile codenames (FP5/FP6/FP7/FT6/
    # FL1/FP8/FP11 — Raven Ridge, Picasso, Renoir, Lucienne, Cezanne,
    # Mendocino, Rembrandt, Dragon Range, Phoenix, Hawk Point, Strix*,
    # Krackan) are intentionally excluded (out of scope).

    # AM4 — Ryzen desktop (Zen 1 / Zen+ / Zen 2 / Zen 3).
    { "codename": "Summit Ridge",   "model": None, "socket": "AM4" },
    { "codename": "Pinnacle Ridge",  "model": None, "socket": "AM4" },
    { "codename": "Matisse",         "model": None, "socket": "AM4" },
    { "codename": "Vermeer",         "model": None, "socket": "AM4" },

    # AM5 — Ryzen desktop (Zen 4 / Zen 5).
    { "codename": "Raphael",         "model": None, "socket": "AM5" },
    { "codename": "Granite Ridge",    "model": None, "socket": "AM5" },

    # sTR4 — Threadripper 1000/2000 (socket overridden from CPU-X's SP3r2).
    { "codename": "Whitehaven",      "model": None, "socket": "sTR4" },
    { "codename": "Colfax",          "model": None, "socket": "sTR4" },

    # sTRX4 — Threadripper 3000 (socket overridden from CPU-X's SP3r2).
    { "codename": "Castle Peak",     "model": None, "socket": "sTRX4" },

    # sWRX8 — Threadripper PRO 3xxx/5xxx (HEDT workstation).
    { "codename": "Chagall",         "model": None, "socket": "sWRX8" },

    # sTR5 — Threadripper 7000/9000 (modern HEDT workstation).
    { "codename": "Storm Peak",      "model": None, "socket": "sTR5" },
    { "codename": "Shimada Peak",    "model": None, "socket": "sTR5" },

    # SP3 — EPYC Naples/Rome/Milan (7001-7003, server).
    { "codename": "Naples",          "model": None, "socket": "SP3" },
    { "codename": "Rome",            "model": None, "socket": "SP3" },
    { "codename": "Milan",           "model": None, "socket": "SP3" },

    # SP5 — EPYC Genoa/Turin (9004/9005, server).
    { "codename": "Genoa",           "model": None, "socket": "SP5" },
    { "codename": "Turin",           "model": None, "socket": "SP5" },
]