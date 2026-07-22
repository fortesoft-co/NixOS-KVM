let
  # Pin to a recent stable nixpkgs branch to ensure QEMU 10.x builds consistently
  pkgs = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {};
  lib = pkgs.lib;

  # Simulate the KVM host configuration. cpuVendor/cpuSocket are set
  # explicitly so the socket-aware manufacturer selection is deterministic
  # (mirrors the real libvirtd.nix path, which uses hostLib.hostManufacturer).
  config = {
    cfg.kvm.host = {
      # Use the same seed from our previous tests
      hwidSeed = "a1b2c3d4-e5f6-4a7b-8c9d-0123456789ab";
      cpuVendor = "intel";
      cpuSocket = "LGA1700";
    };
  };

  # Import the hostLib to access the manufacturer registry
  hostLib = import ../modules/kvm/host/lib.nix { inherit config lib pkgs; };
  manufacturer = hostLib.hostManufacturer;

  # Replicate the exact dynamic patch derivation from libvirtd.nix
  dynamicPatch = pkgs.runCommand "qemu-anti-detection-dynamic.patch" {} ''
    sed \
      -e 's/ASUS Real Machine/${manufacturer.realMachine}/g' \
      -e 's/M4A88TD-M/${manufacturer.defaultProduct}/g' \
      -e 's/ASUS-PC/${manufacturer.patchToken}-PC/g' \
      -e 's/ASUS/${manufacturer.patchToken}/g' \
      ${../modules/kvm/patches/qemu-10.2.2-anti-detection.patch} > $out
  '';

  # Instantiate the customized QEMU package
  customQemu = pkgs.qemu.overrideAttrs (old: rec {
    version = "10.2.2";
    # We fetch the exact QEMU 10.2.2 source
    src = pkgs.fetchurl {
      url = "https://download.qemu.org/qemu-10.2.2.tar.xz";
      sha256 = "0xp1457v1hw5szf7gx942xvvk6pasarbqfijfam1f54wy9pjjjvq";
    };

    # Crucially, we OVERWRITE the upstream nixpkgs patches to avoid
    # conflicts (like the qemu-ga patch failure), and just use ours.
    patches = [ dynamicPatch ];

    # Optional: disable some heavy features just to speed up the test build
    # Also disable docs since sphinx might be acting up in this test environment
    configureFlags = (old.configureFlags or []) ++ [
      "--disable-docs"
      "--disable-gtk"
      "--target-list=x86_64-softmmu"
    ];

    # The doc output isn't built when --disable-docs is passed, so we
    # need to remove it from the outputs list to prevent the build from failing
    outputs = lib.remove "doc" old.outputs;
  });
in
customQemu
