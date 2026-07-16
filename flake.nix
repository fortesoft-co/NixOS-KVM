{
  description = "Declarative KVM guest management for NixOS (libvirt-backed)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    # The KVM module. Consume via:
    #   inputs.nixos-kvm.nixosModules.kvm   (or .default)
    # Import agenix as well if you use guest / cloud-init / graphics password
    # features (they are optional: the module only references age.secrets
    # when at least one guest has a passwordAgePath set).
    nixosModules.kvm = ./modules/kvm;
    nixosModules.default = self.nixosModules.kvm;
  };
}
