# Layer 1 smoke test for socket-detection backstops + AMD APU fix.
# Imports the REAL detectSocketFromDatabase from host/lib.nix (no replicated
# logic) and asserts results for representative brand strings / codenames.
#
# Returns `true` on success, throws with a failure report on failure, so it
# can be wired as an eval-time flake check (see flake.nix checks output).
#
# Standalone run (for dev iteration):
#   nix-instantiate --eval --strict --arg lib '(import <nixpkgs> {}).lib' \
#     --arg pkgs '(import <nixpkgs> {}).legacyPackages.x86_64-linux' \
#     tests/anti-detection/cpu-socket.nix
#
# This is the first module of the Layer 1 testing strategy in CONTEXT.md.
# It covers:
#   - Intel generation-level backstops (fallback-cpu-db.py) catching SKUs
#     that CPU-X doesn't carry (e.g. i5-12600KF matched by i5-12).
#   - AMD desktop-APU disambiguation: Cezanne/Renoir/Picasso/Raven Ridge/
#     Phoenix codenames map to MOBILE sockets in CPU-X; a desktop G-suffix
#     APU (5600G, 8600G) must defer to layer 3 (return null), not return FP6.
#   - AMD mobile (out of scope) keeping CPU-X's mobile socket unchanged.
#   - AMD non-APU codenames (Vermeer, Raphael, Genoa, Storm Peak) returning
#     their socket directly.
{ lib, pkgs }:
with lib;
let
  # Mock config with explicit cpuVendor/cpuSocket (no IFD). The functions
  # under test don't read these, but host/lib.nix's `let` bindings reference
  # them lazily — explicit non-"auto" values guarantee the IFD bindings
  # (cpuid_tool / proc/cpuinfo) never fire.
  config = {
    cfg.kvm.host = {
      hwidSeed = "test-seed-1234";
      cpuVendor = "intel";
      cpuSocket = "LGA1700";
      antiDetection = { patchQemu = false; patchKernel = false; };
    };
  };
  hostLib = import ../../modules/kvm/host/lib.nix { inherit config lib pkgs; };
  inherit (hostLib) detectSocketFromDatabase;

  # Intel cases: (brandstr, expected). "Backstop" cases are NOT in CPU-X.
  intelCases = [
    # CPU-X specific entries (should still win):
    { brandstr = "13th Gen Intel(R) Core(TM) i9-13900K";     expected = "LGA1700"; }
    { brandstr = "Intel(R) Core(TM) i5-2500K CPU";          expected = "LGA1155"; }
    { brandstr = "12th Gen Intel(R) Core(TM) i5-12400F";    expected = "LGA1700"; }
    # Backstop cases (NOT in CPU-X — covered only by fallback-cpu-db.py):
    { brandstr = "12th Gen Intel(R) Core(TM) i5-12600KF";   expected = "LGA1700"; }
    { brandstr = "13th Gen Intel(R) Core(TM) i5-13400F";    expected = "LGA1700"; }
    { brandstr = "14th Gen Intel(R) Core(TM) i7-14700K";    expected = "LGA1700"; }
    { brandstr = "10th Gen Intel(R) Core(TM) i3-10100";     expected = "LGA1200"; }
    { brandstr = "11th Gen Intel(R) Core(TM) i9-11900KF";   expected = "LGA1200"; }
    { brandstr = "Intel(R) Core(TM) i7-8700K CPU";          expected = "LGA1151"; }
    { brandstr = "Intel(R) Core(TM) i3-9100 CPU";           expected = "LGA1151"; }
    { brandstr = "Intel(R) Core(TM) Ultra 7 265K";          expected = "LGA1851"; }
    # Xeon backstops (gap-fillers):
    { brandstr = "Intel(R) Xeon(R) Platinum 8480+";         expected = "LGA4677"; }
    { brandstr = "Intel(R) Xeon(R) Gold 6430";             expected = "LGA4677"; }
    { brandstr = "Intel(R) Xeon(R) w7-2495X";              expected = "LGA4677"; }
    { brandstr = "Intel(R) Xeon(R) W-3175X";               expected = "LGA2066"; }
  ];

  # AMD cases: (codename from cpuid_tool, brandstr, expected). The desktop-APU
  # cases assert the defer-to-layer-3 fix (expected = null). Mobile (out of
  # scope) keeps CPU-X's mobile socket. Non-APU codenames return directly.
  amdCases = [
    # Desktop APUs — codename maps to mobile socket, G-suffix → defer (null):
    { codename = "Ryzen 5 (Cezanne)";   brandstr = "AMD Ryzen 5 5600G 6-Core Processor";        expected = null;    }
    { codename = "Ryzen 7 (Cezanne)";   brandstr = "AMD Ryzen 7 5700G 8-Core Processor";        expected = null;    }
    { codename = "Ryzen 5 (Renoir)";    brandstr = "AMD Ryzen 5 4600G 6-Core Processor";        expected = null;    }
    { codename = "Ryzen 5 (Picasso)";   brandstr = "AMD Ryzen 5 3400G 8-Core Processor";        expected = null;    }
    { codename = "Ryzen 5 (Phoenix)";   brandstr = "AMD Ryzen 5 8600G 6-Core Processor";        expected = null;    }  # AM5 APU
    # Mobile APUs (out of scope) — no G suffix, keep CPU-X's mobile socket:
    { codename = "Ryzen 5 (Cezanne)";   brandstr = "AMD Ryzen 5 5600U 6-Core Processor";        expected = "FP6";  }
    { codename = "Ryzen 5 (Renoir)";    brandstr = "AMD Ryzen 5 4600U 6-Core Processor";        expected = "FP6";  }
    # Desktop non-APU codenames — return socket directly (not mobile):
    { codename = "Ryzen 9 (Vermeer)";   brandstr = "AMD Ryzen 9 5950X 16-Core Processor";      expected = "AM4";  }
    { codename = "Ryzen 9 (Raphael)";   brandstr = "AMD Ryzen 9 7950X 16-Core Processor";      expected = "AM5";  }
    { codename = "Ryzen 9 (Granite Ridge)"; brandstr = "AMD Ryzen 9 9950X 16-Core Processor";   expected = "AM5";  }
    # Server / workstation codenames — return socket directly:
    { codename = "AMD EPYC (Genoa)";     brandstr = "AMD EPYC 9654 96-Core Processor";          expected = "SP5";  }
    { codename = "AMD EPYC (Turin)";     brandstr = "AMD EPYC 9755 128-Core Processor";         expected = "SP5";  }
    { codename = "Ryzen Threadripper (Storm Peak)"; brandstr = "AMD Ryzen Threadripper 7980X 64-Core"; expected = "sTR5"; }
    # Threadripper socket-override (CPU-X says SP3r2, we correct):
    { codename = "Ryzen Threadripper (Castle Peak)"; brandstr = "AMD Ryzen Threadripper 3990X 64-Core"; expected = "sTRX4"; }
  ];

  intelResults = map (c: {
    label = c.brandstr;
    inherit (c) expected;
    # Intel branch ignores codename — pass null.
    got = detectSocketFromDatabase "intel" null c.brandstr;
  }) intelCases;

  amdResults = map (c: {
    label = "${c.codename} | ${c.brandstr}";
    inherit (c) expected;
    got = detectSocketFromDatabase "amd" c.codename c.brandstr;
  }) amdCases;

  results = intelResults ++ amdResults;
  failures = filter (r: r.got != r.expected) results;
in
  if failures == [] then true
  else throw (
    "cpu-socket test: ${toString (length failures)}/${toString (length results)} cases FAILED:\n"
    + concatStringsSep "\n" (map (r:
      "  ${r.label}: expected ${if r.expected == null then "null" else r.expected}, got ${if r.got == null then "null" else r.got}"
    ) failures)
  )