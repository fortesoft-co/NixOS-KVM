{
  imports = [
    ./options.nix
    ./guests.nix
    ./host/kernel.nix
    ./host/libvirtd.nix
    ./host/storage.nix
    ./host/network.nix
    ./host/packages.nix
  ];
}
