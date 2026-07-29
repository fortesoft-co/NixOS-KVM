{
  description = "Declarative KVM guest management for NixOS (libvirt-backed)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # x86_64-linux is the only platform where KVM/libvirt guests are
      # supported; tests and checks are exposed for that system only.
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      # The KVM module. Consume via:
      #   inputs.nixos-kvm.nixosModules.kvm   (or .default)
      # Import agenix as well if you use guest / cloud-init / graphics password
      # features (they are optional: the module only references age.secrets
      # when at least one guest has a passwordAgePath set).
      nixosModules.kvm = ./modules/kvm;
      nixosModules.default = self.nixosModules.kvm;

      # ── Tests ─────────────────────────────────────────────────────────────
      # Test code lives under tests/ (isolated from modules/, one-way import:
      # tests import the module; the module never imports tests).
      #
      # `checks` runs on `nix flake check` and `nix build .#checks.<name>`.
      # Only fast, no-from-source-build tests belong here — pure-eval Layer 1
      # and the unpatched Layer 3 boot test using nixpkgs' prebuilt QEMU.
      # Anything that builds QEMU or the kernel from source (patch-compile,
      # patched boot verification, detection realism) is opt-in via a separate
      # output, NOT in `checks`, so `nix flake check` stays fast by default.
      #
      # NOTE: `nix flake check` does NOT recurse into nested attrsets under
      # `checks` — every `checks.x86_64-linux.<name>` must be a derivation. So
      # the checks are FLAT, with `anti-detection-` (and `guest-`) prefixes
      # preserving the old grouping visually instead of nested attrsets.
      checks.x86_64-linux = {
        # Layer 1: pure-eval socket-detection assertions. Evaluates the test
        # at flake-eval time; throws on failure (failing the check), produces
        # a trivial derivation on success.
        anti-detection-cpu-socket =
          assert (import ./tests/anti-detection/cpu-socket.nix { inherit (pkgs) lib; inherit pkgs; }) == true;
          pkgs.runCommand "check-anti-detection-cpu-socket" { } "touch $out";

        # Layer 1: SMBIOS profile library + selection-logic assertions.
        # Imports the real host/lib.nix functions and smbios-profiles.nix,
        # asserts coverage / selection / fallback / determinism / profile
        # well-formedness. Eval-time throw on failure.
        anti-detection-smbios-profiles =
          assert (import ./tests/anti-detection/smbios-profiles.nix { inherit (pkgs) lib; inherit pkgs; }) == true;
          pkgs.runCommand "check-anti-detection-smbios-profiles" { } "touch $out";

        # Layer 1: host/lib.nix pure-logic functions (hexToInt, detectSocket
        # layer-3 regex, detectSocketFromDatabase incl. AMD APU defer, cpuVendor
        # explicit, hostManufacturer integration). Imports the real lib.nix.
        anti-detection-host-lib =
          assert (import ./tests/anti-detection/host-lib.nix { inherit (pkgs) lib; inherit pkgs; }) == true;
          pkgs.runCommand "check-anti-detection-host-lib" { } "touch $out";

        # Layer 1: guests/lib.nix — macFor (OUI on/off, determinism, override,
        # uniqueness) + computeEffectiveSmbios (manual/synthetic/off branching
        # + field mapping). computeEffectiveSmbios was extracted from generateXML
        # so it's directly callable with mock deps.
        anti-detection-guest-lib =
          assert (import ./tests/anti-detection/guest-lib.nix { inherit (pkgs) lib; inherit pkgs; }) == true;
          pkgs.runCommand "check-anti-detection-guest-lib" { } "touch $out";

        # Layer 3 (unpatched): boots a NixOS VM with the real kvm module's
        # libvirtd wiring, generates the AD-on synthetic guest XML, and verifies
        # via `virsh define` + `virsh dumpxml` + `virsh domxml-to-native
        # qemu-argv` that libvirt ACCEPTS, STORES, and would PASS every SMBIOS
        # / NIC / CPU value to QEMU — the real libvirt schema/parser + argv
        # generator, not just xmllint. Uses nixpkgs' prebuilt QEMU (no
        # from-source build) and needs no KVM, so it stays in the default checks.
        anti-detection-guest-smbios = import ./tests/anti-detection/guest-smbios.nix { inherit (pkgs) lib; inherit pkgs; };

        # Layer 3 Option B (unpatched, guest-OS boot): boots a minimal NixOS
        # guest UNDER libvirt with the AD-on XML, runs the first-party probe
        # sweep (dmidecode / /sys/class/dmi/id / lscpu / ip link / lspci / acpi
        # tables / block models) from INSIDE the guest, and diffs the firmware
        # tables the guest OS actually saw against the module's computed values.
        # This is the only test that catches the rare class where QEMU/SeaBIOS
        # silently ignores a passed -smbios block. Requires nested KVM (hard-
        # fails if /dev/kvm is missing). Uses nixpkgs' prebuilt QEMU (no
        # from-source build), so it stays in the default checks.
        anti-detection-guest-smbios-boot = import ./tests/anti-detection/guest-smbios-boot.nix { inherit (pkgs) lib; inherit pkgs; };

        # General (non-anti-detection) build-time check: generateXML produces
        # well-formed libvirt XML (xmllint --noout) with correct structure
        # (xpath) + the cheap high-value AD on/off value checks. Composed
        # fixtures: one baseGuest + small deltas (AD on/off, with-disks,
        # with-passthrough). Returns a runCommand derivation — the build IS
        # the check.
        guest-xml = import ./tests/guest/xml.nix { inherit (pkgs) lib; inherit pkgs; };
      };

      # ── Opt-in patch-build tests (Layer 2) ───────────────────────────────
      # NOT in `checks` — these build QEMU / kernel from source, so they're
      # slow and would make `nix flake check` impractical. Exposed under a
      # separate top-level output so they're explicitly opt-in:
      #
      #   nix build .#patchBuilds.x86_64-linux.<name> --no-link -L
      #
      # Tier 2 (QEMU): verifies the dynamic manufacturer-token rewrite in
      # host/libvirtd.nix produces a valid patch for ALL FOUR manufacturer
      # tokens (apply-check, cheap, parallel) + a full QEMU 10.2.2 compile
      # for the seed-selected default token (heavy). See
      # tests/anti-detection/qemu-patch-build.nix for the two-level rationale.
      patchBuilds.x86_64-linux = let
        qemuPatch = import ./tests/anti-detection/qemu-patch-build.nix { inherit (pkgs) lib; inherit pkgs; };
        kernelPatch = import ./tests/anti-detection/kernel-patch-build.nix { inherit (pkgs) lib; inherit pkgs; };
      in {
        # Cheap half only — all four token patches apply cleanly to QEMU 10.2.2
        # source (no from-source compile). Fast enough to run interactively.
        anti-detection-qemu-applies = qemuPatch.applies;
        # Heavy half — full QEMU 10.2.2 build with the default token's patch.
        anti-detection-qemu-compile = qemuPatch.compile;
        # Static binary string check on the compiled patched QEMU (needs the
        # compile, but the check itself is just `strings | grep`). Verifies the
        # dynamic sed produced the right token strings + the QEMU defaults / ASUS
        # template are gone — proves the sed ran (uses a non-template token).
        anti-detection-qemu-strings = qemuPatch.patchedStringCheck;
        # Convenience: build everything (applies + compile + static string check).
        anti-detection-qemu = qemuPatch.all;

        # Layer 2 Tier 3 (Kernel anti-detection) — verifies the five vendored
        # per-vector patches (modules/kvm/patches/linux-6.18-ad-*.patch) each
        # apply cleanly to the pinned Linux 6.18.38 source AND all five apply
        # + compile together. Cheap apply matrix + ONE heavy full-kernel build.
        # See tests/anti-detection/kernel-patch-build.nix.
        # Maximize parallelism on the compile (no hard-coded -j) with:
        #   nix build .#patchBuilds.x86_64-linux.anti-detection-kernel --cores 0 -L
        anti-detection-kernel-applies = kernelPatch.applies;
        anti-detection-kernel-compile = kernelPatch.compile;
        anti-detection-kernel = kernelPatch.all;

        # Layer 3 PATCHED-KERNEL boot test (heavy — boots a nested test VM
        # running the pinned + patched kernel, then boots the AD-on guest
        # inside it; needs nested KVM to RUN). Reuses the Layer 2 combined
        # kernel build (same derivation — not rebuilt). Verifies the patch
        # set's runtime surfaces from inside the guest: CPUID 0x40000000
        # signature + user-mode TSC divisor ratio, plus the shared 20-field
        # SMBIOS/NIC/CPU regression. See tests/anti-detection/kernel-boot.nix.
        anti-detection-kernel-boot =
          import ./tests/anti-detection/kernel-boot.nix { inherit (pkgs) lib; inherit pkgs; };

        # Layer 3 PATCHED-QEMU boot test (VERY heavy — builds patched QEMU from
        # source on the test VM, then boots a guest under it; needs nested KVM
        # to RUN). Verifies the QEMU string replacements surface in a booted
        # guest (fw_cfg ACPI _HID: QEMU0002 -> <token>0002) and that the patched
        # QEMU does not break AD SMBIOS/NIC/CPU surfacing (reuses Option B's
        # 20-field regression). See tests/anti-detection/guest-smbios-patched.nix.
        anti-detection-guest-smbios-patched =
          import ./tests/anti-detection/guest-smbios-patched.nix { inherit (pkgs) lib; inherit pkgs; };
      }
      # Per-file kernel compiles — bisect targets for a failing combined
      # build. Opt-in outputs only; never referenced by `all`, so they're
      # built solely on demand (BESPOKE-PATCH-DESIGN.md §8 stage 3).
      // pkgs.lib.mapAttrs' (n: v: pkgs.lib.nameValuePair "anti-detection-kernel-compile-${n}" v)
        kernelPatch.perFileCompiles;
    };
}
