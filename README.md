# nixos-virtman

Declarative QEMU/KVM guest management for NixOS, backed by libvirt.

Define virtual machines in your NixOS configuration (following the
`virtualisation.oci-containers` pattern) instead of creating them
imperatively with `virsh` / `virt-manager`. The module generates the libvirt
domain XML, per-guest systemd services, and keeps the stored XML aligned to
your Nix config.

> Workspace name — to be renamed.

## Usage

Add this flake as an input and import the module:

```nix
# flake.nix
inputs.nixos-virtman.url = "github:OWNER/nixos-virtman";

# in your nixosSystem:
modules = [ inputs.nixos-virtman.nixosModules.kvm ];
```

```nix
# config
cfg.kvm.guests.ubuntu = {
  memory = 2048;
  vcpus = 2;
  disks = [ { ... } ];
  networks = [ { type = "user"; } ];
};
```

## Optional peer dependency: agenix

Guest graphics passwords and cloud-init passwords are injected via agenix
(`age.secrets`). The module only references `age.secrets` when at least one
guest sets a `passwordAgePath`, so agenix is **optional** — import
`agenix.nixosModules.default` too only if you use those password features.

## Access tiers

- `cfg.kvm.host.libvirtd.users.manage` — users added to the `libvirtd` group
  (full read-write access; virt-manager works; edits are auto-reverted to the
  Nix config by the per-guest watch service).
- `cfg.kvm.host.libvirtd.users.monitor` — users added to a `kvm-monitors`
  group with **read-only** access enforced via polkit (`unix.manage` denied,
  `unix.monitor` allowed). Monitor users can use `virsh -r` and `virt-viewer`
  but not `virt-manager` (which opens read-write connections).

Neither list has any users by default — list them explicitly.

## virt-viewer shortcuts

When `cfg.kvm.host.tools.gui` is true, a `.desktop` entry is generated per
guest (`virt-viewer --connect qemu:///system <name>`), usable by both manage-
and monitor-scope users (virt-viewer opens a read-only connection).