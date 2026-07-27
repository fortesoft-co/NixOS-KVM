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
      # and (later) unpatched Layer 3 boot tests using nixpkgs' prebuilt QEMU.
      # Anything that builds QEMU or the kernel from source (patch-compile,
      # patched boot verification, detection realism) is opt-in via a separate
      # output, NOT in `checks`, so `nix flake check` stays fast by default.
      checks.x86_64-linux.anti-detection = {
        # Layer 1: pure-eval socket-detection assertions. Evaluates the test
        # at flake-eval time; throws on failure (failing the check), produces
        # a trivial derivation on success.
        cpu-socket =
          assert (import ./tests/anti-detection/cpu-socket.nix { inherit (pkgs) lib; }) == true;
          pkgs.runCommand "check-anti-detection-cpu-socket" { } "touch $out";

        # Layer 1: SMBIOS profile library + selection-logic assertions.
        # Imports the real host/lib.nix functions and smbios-profiles.nix,
        # asserts coverage / selection / fallback / determinism / profile
        # well-formedness. Eval-time throw on failure.
        smbios-profiles =
          assert (import ./tests/anti-detection/smbios-profiles.nix { inherit (pkgs) lib; inherit pkgs; }) == true;
          pkgs.runCommand "check-anti-detection-smbios-profiles" { } "touch $out";

        # Layer 1: host/lib.nix pure-logic functions (hexToInt, detectSocket
        # layer-3 regex, detectSocketFromDatabase incl. AMD APU defer, cpuVendor
        # explicit, hostManufacturer integration). Imports the real lib.nix.
        host-lib =
          assert (import ./tests/anti-detection/host-lib.nix { inherit (pkgs) lib; inherit pkgs; }) == true;
          pkgs.runCommand "check-anti-detection-host-lib" { } "touch $out";

        # Layer 1: guests/lib.nix — macFor (OUI on/off, determinism, override,
        # uniqueness) + computeEffectiveSmbios (manual/synthetic/off branching
        # + field mapping). computeEffectiveSmbios was extracted from generateXML
        # so it's directly callable with mock deps.
        guest-lib =
          assert (import ./tests/anti-detection/guest-lib.nix { inherit (pkgs) lib; inherit pkgs; }) == true;
          pkgs.runCommand "check-anti-detection-guest-lib" { } "touch $out";
      };
    };
}