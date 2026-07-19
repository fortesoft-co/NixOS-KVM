# nixos-kvm

Declarative KVM guest management for NixOS.

> **Status:** alpha. This project is under active development and testing.
> The option surface and behavior may change before stabilizing. Expect rough
> edges, and avoid relying on it for production workloads yet.

`nixos-kvm` is a NixOS module, distributed as a flake, that lets you define
libvirt/KVM virtual machines inside your NixOS configuration and keeps
libvirt reconciled to that configuration. It extends the NixOS module system
into libvirt-based virtualization, filling a role similar to
`virtualisation.oci-containers`, applied to virtual machines.

```nix
cfg.kvm.guests.ubuntu = {
  memory = 8192;
  vcpus = 4;
  firmware = "uefi";
  disks = [{ path = "disk0"; size = "50G"; }];
  networks = [{ type = "user"; }];
  cloudInit.enable = true;
  cloudInit.sshAuthorizedKeys = [ "ssh-ed25519 AAAA..." ];
};
```

---

## Why

The conventional libvirt workflow is imperative. You create a guest with
`virsh` or `virt-manager`, tune its XML by hand, and the resulting definition
lives in `/var/lib/libvirt/qemu/<name>.xml`, outside your configuration tree
and outside version control. Over time the set of running guests and their
definitions becomes hidden state: unreviewed, untracked, and different on
every host.

NixOS users already treat the rest of the system this way. Services, users,
file systems, and network interfaces are declared in configuration that is
committed, reviewed, and reproduced on every rebuild. `nixos-kvm` brings
virtual machines into the same workflow.

The central design principle:

> **The Nix configuration is the single source of truth for VM definitions.**

Beyond generating XML, `nixos-kvm` continuously reconciles libvirt with the
declared configuration. If a managed guest is modified imperatively, through
`virsh edit`, `virt-manager`, or any direct write to the stored domain XML,
the module detects the drift and restores the canonical declarative
configuration.

---

## What is managed, and what is not

The distinction matters and is worth stating up front.

**Managed declaratively and continuously reconciled:**

- libvirt domain definitions (the QEMU domain XML)
- guest CPU, memory, and topology
- firmware and Secure Boot configuration
- virtual hardware: disks, NICs, graphics, input, video, audio, RNG, watchdog
- deterministic MAC addresses and domain UUIDs
- cloud-init seed generation
- guest lifecycle and systemd integration
- drift prevention (imperative edits are reverted)
- orphan cleanup (guests removed from config are undefined)
- libvirt access policy (manage and monitor tiers)
- desktop integration (virt-viewer launchers)

These are kept aligned to the Nix configuration on every rebuild and after any
external edit.

**Intentionally not managed:**

- guest operating system state
- files inside guest disks
- databases, user data, and application state

Virtual disks are persistent storage. `nixos-kvm` creates a disk image the
first time a guest is started, and leaves existing disks untouched from then
on. It never recreates, resets, or reverts an existing disk, and changing
`disks[].size` in your configuration does not resize an existing image. The
VM definition is declarative; guest storage is persistent user data.

---

## Quick start

Add the flake as an input and import the module:

```nix
# flake.nix
inputs.nixos-kvm.url = "github:OWNER/nixos-kvm";

# in your nixosSystem:
specialArgs = { inherit nixos-kvm; };
modules = [ inputs.nixos-kvm.nixosModules.kvm ];
```

Then define a guest and grant yourself libvirt access:

```nix
cfg.kvm.host.libvirtd.users.manage = [ "alice" ];

cfg.kvm.guests.ubuntu = {
  memory = 4096;
  vcpus = 4;
  firmware = "uefi";
  autoStart = true;

  disks = [
    {
      path = "disk0";
      size = "50G";
      sourceUrl = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img";
      bus = "virtio";
      cache = "none";
      aio = "io_uring";
      discard = "unmap";
    }
  ];

  networks = [{ type = "user"; }];

  cloudInit.enable = true;
  cloudInit.user = "alice";
  cloudInit.sshAuthorizedKeys = [ "ssh-ed25519 AAAA..." ];
};
```

Apply with `nixos-rebuild switch`. The guest is defined, its disk image
created or downloaded, and (because `autoStart = true`) it is started. The
`kvm-guest-ubuntu-watch` path unit is now guarding its XML against imperative
edits.

> **Note:** no users are granted libvirt access by default. Both
> `users.manage` and `users.monitor` default to `[]`; list them explicitly or
> you will be unable to connect.

---

## Configuration reference

All options live under two subtrees: `cfg.kvm.guests.<name>` (per guest) and
`cfg.kvm.host` (host-wide).

### Guest options (`cfg.kvm.guests.<name>`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `enable` | bool | `true` | Disable a guest without removing its block. |
| `domainName` | str | *Required* | Permanent Libvirt domain name. Changing this creates a new VM and breaks HWID persistence. |
| `memory` | int | `2048` | MiB. |
| `vcpus` | int | `2` | Virtual CPU count. |
| `machineType` | str | `"q35"` | QEMU machine type. |
| `architecture` | str | `"x86_64"` | Guest CPU architecture. |
| `firmware` | `"bios"`/`"uefi"` | `"uefi"` | Firmware type. |
| `secureBoot` | bool | `false` | Requires `firmware = "uefi"` and `tpm.enable`. |
| `autoStart` | bool | `false` | Start the guest on host boot. |
| `dependsOn` | [str] | `[]` | Other guest names this one starts after. |
| `storagePath` | str | `null` | Override the per-guest storage subdirectory. |
| `extraXML` | str | `""` | Raw XML appended to the domain. |
| `extraQemuArgs` | [str] | `[]` | Extra QEMU command-line args. |

#### CPU Options (`cfg.kvm.guests.<name>.cpu`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `cpu.mode` | `"host-passthrough"` / `"host-model"` / `"custom"` | `"host-passthrough"` | CPU model exposed to the guest. |
| `cpu.reportedModel` | str? | `null` | Model to report; only for `mode = "custom"` (e.g. `"Haswell-noTSX-IBRS"`). |
| `cpu.sockets` | int? | `null` | Topology sockets. Set with `cores` and `threads`; product must equal `vcpus`. |
| `cpu.cores` | int? | `null` | Cores per socket. |
| `cpu.threads` | int? | `null` | Threads per core. |
| `cpu.hidden` | bool | `false` | Hide hypervisor status (gaming/anti-cheat). |
| `cpu.flags` | list of `{ name, policy }` | `[]` | CPU feature flags. `policy` is `require`/`force`/`disable`/`forbid`/`optional`. |

#### Clock Options (`cfg.kvm.guests.<name>.clock`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `clock.offset` | `"utc"` / `"localtime"` / `"timezone"` / `"variable"` | `"utc"` | `"localtime"` for Windows; pair `"timezone"` with `timezone`, `"variable"` with `adjustment`. |
| `clock.timezone` | str? | `null` | Timezone for `offset = "timezone"` (e.g. `"America/New_York"`). |
| `clock.adjustment` | int? | `null` | Seconds offset from UTC for `offset = "variable"`. |

#### SMBIOS Options (`cfg.kvm.guests.<name>.smbios`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `smbios.manufacturer` | str? | `null` | SMBIOS manufacturer string. |
| `smbios.product` | str? | `null` | SMBIOS product name. |
| `smbios.version` | str? | `null` | SMBIOS product version. |
| `smbios.serial` | str? | `null` | SMBIOS system serial number. |
| `smbios.uuid` | str? | `null` | System UUID. When null, derived from the domain name. |
| `smbios.family` | str? | `null` | SMBIOS family string. |
| `smbios.sku` | str? | `null` | SMBIOS SKU number. |

#### Disks Options (`cfg.kvm.guests.<name>.disks`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `disks[].path` | str | (required) | Relative name (joined with storage dir + format ext) or absolute path. |
| `disks[].format` | `"qcow2"` / `"raw"` | `"qcow2"` | Disk image format. |
| `disks[].bus` | `"virtio"` / `"sata"` / `"ide"` / `"scsi"` | `"virtio"` | Disk bus. |
| `disks[].size` | str? | `null` | Size (e.g. `"50G"`). Required for new empty images; resizes downloaded images. |
| `disks[].sourceUrl` | str? | `null` | Download a pre-built image instead of creating empty. |
| `disks[].readOnly` | bool | `false` | Auto-set true for `device = "cdrom"`. |
| `disks[].device` | `"disk"` / `"cdrom"` | `"disk"` | CD-ROMs are auto read-only. |
| `disks[].boot` | int? | `null` | Boot order (1 = first). Auto-assigned when null. |
| `disks[].cache` | `"none"`/`"writeback"`/`"writethrough"`/`"unsafe"`/`"directsync"`? | `null` | Cache mode. `none` recommended for qcow2 + virtio. |
| `disks[].aio` | `"native"` / `"threads"` / `"io_uring"`? | `null` | Async I/O backend. `io_uring` fastest on modern kernels. |
| `disks[].discard` | `"ignore"` / `"unmap"`? | `null` | `unmap` enables guest TRIM. |
| `disks[].iothread` | int? | `null` | Assign to an IOThread by number; auto-creates the `<iothreads>` element. |
| `disks[].ssd` | bool | `false` | Expose as SSD to the guest. |
| `disks[].serial` | str? | `null` | Serial number for guest udev rules. |

#### Networks Options (`cfg.kvm.guests.<name>.networks`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `networks[].type` | `"bridge"` / `"network"` / `"direct"` / `"user"` | `"network"` | Interface type. |
| `networks[].source` | str? | `null` | Bridge/network/physical interface name. Ignored for `user`. |
| `networks[].model` | `"virtio"` / `"e1000"` / `"rtl8139"` / `"vmxnet3"` | `"virtio"` | NIC model. |
| `networks[].mac` | str? | `null` | MAC; when null, deterministic from name + index (`52:54:00:` prefix). |

#### TPM Options (`cfg.kvm.guests.<name>.tpm`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `tpm.enable` | bool | `false` | Enable emulated TPM via swtpm. |
| `tpm.version` | `"1.2"` / `"2.0"` | `"2.0"` | TPM spec version. |
| `tpm.model` | `"tpm-crb"` / `"tpm-tis"` | `"tpm-crb"` | TPM device model. |

#### PCI Passthrough Options (`cfg.kvm.guests.<name>.passthrough.pci`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `passthrough.pci[].id` | str | (required) | PCI BDF (e.g. `"0000:01:00.0"`). |
| `passthrough.pci[].pcie` | bool | `false` | Use PCIe bus. |
| `passthrough.pci[].romBar` | bool | `true` | Expose device option ROM. |
| `passthrough.pci[].xVga` | bool | `false` | Mark as primary guest VGA. |

#### USB Passthrough Options (`cfg.kvm.guests.<name>.passthrough.usb`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `passthrough.usb[].vendor` | str | (required) | USB vendor ID (hex, e.g. `"0bda"`). |
| `passthrough.usb[].product` | str | (required) | USB product ID (hex, e.g. `"5411"`). |
| `passthrough.usb[].usb3` | bool | `false` | Use USB 3.0 (qemu-xhci). |

#### Graphics Options (`cfg.kvm.guests.<name>.graphics`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `graphics.type` | `"spice"` / `"vnc"` / `"none"` | `"spice"` | Graphics protocol. |
| `graphics.listen` | str? | `null` | Listen address; null means local-only (`127.0.0.1`). |
| `graphics.port` | int? | `null` | Fixed port; auto-allocated when null. |
| `graphics.passwordAgePath` | path? | `null` | age-encrypted graphics password; applied after VM start. |
| `graphics.clipboard` | bool | `false` | Clipboard sharing (SPICE only). |
| `graphics.fileTransfer` | bool | `false` | File transfer (SPICE only). |

#### Paravirtualized Graphics Options (`cfg.kvm.guests.<name>.paravirtGraphics`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `paravirtGraphics.enable` | bool | `false` | Enable 3D proxying via VirtIO-GPU. Mutes standard XML graphics. |
| `paravirtGraphics.backend` | `"venus"` / `"virgl"` | `"venus"` | Proxy Vulkan (`venus`) or OpenGL (`virgl`) directly to the host OS. |

#### Input Options (`cfg.kvm.guests.<name>.input`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `input.tablet` | bool | `true` | USB tablet (pointer alignment for SPICE/VNC). |
| `input.keyboard` | bool | `true` | Keyboard input device. |
| `input.mouse` | bool | `true` | Mouse input device. |

#### Video Options (`cfg.kvm.guests.<name>.video`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `video.model` | `"qxl"` / `"virtio"` / `"vga"` / `"cirrus"` / `"none"` | `"qxl"` | Video card model. |
| `video.heads` | int | `1` | Number of display heads. |

#### Serial Options (`cfg.kvm.guests.<name>.serial`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `serial.enable` | bool | `false` | Enable a serial console. |
| `serial.port` | port? | `null` | TCP port (bound on 127.0.0.1); null uses a PTY (`virsh console`). |

#### Audio Options (`cfg.kvm.guests.<name>.audio`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `audio.enable` | bool | `false` | Enable an audio device. |
| `audio.model` | `"ich9"` / `"ac97"` / `"es1370"` / `"usb"` / `"none"` | `"ich9"` | Audio hardware model. |

#### RNG Options (`cfg.kvm.guests.<name>.rng`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `rng.enable` | bool | `false` | VirtIO RNG feeding host entropy. |
| `rng.rateBytes` | int? | `null` | Max bytes per period. |
| `rng.ratePeriod` | int? | `null` | Rate period in ms. Set together with `rateBytes`. |

#### Watchdog Options (`cfg.kvm.guests.<name>.watchdog`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `watchdog.enable` | bool | `false` | Enable a hardware watchdog. |
| `watchdog.model` | `"i6300esb"` / `"ib700"` / `"diag288"` / `"itco"` | `"itco"` | Watchdog model. |
| `watchdog.action` | `"reset"` / `"shutdown"` / `"poweroff"` / `"pause"` / `"dump"` / `"none"` | `"reset"` | Action when the watchdog fires. |

#### Agent Options (`cfg.kvm.guests.<name>.agent`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `agent.enable` | bool | `false` | QEMU guest agent virtio-serial channel; needs `qemu-guest-agent` in the guest. |

#### Cloud-init Options (`cfg.kvm.guests.<name>.cloudInit`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `cloudInit.enable` | bool | `false` | Generate a NoCloud seed ISO as a CD-ROM. |
| `cloudInit.hostname` | str | `<name>` | Guest hostname. |
| `cloudInit.user` | str | `"user"` | Primary user to create. |
| `cloudInit.passwordAgePath` | path? | `null` | age-encrypted user password; injected at runtime. |
| `cloudInit.sshAuthorizedKeys` | [str] | `[]` | SSH public keys for the user. |
| `cloudInit.packages` | [str] | `[]` | Packages to install on first boot. |
| `cloudInit.runcmd` | [str] | `[]` | Commands to run on first boot. |

#### Anti-Detection Options (`cfg.kvm.guests.<name>.antiDetection`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `antiDetection.enable` | bool | `false` | Enable Tier 1 & 1.5 XML scrubbing. Mutes paravirt devices, spoofs HyperV vendor, standardizes storage buses. |
| `antiDetection.patchQemu` | bool | `false` | *DO NOT USE HERE*. Fails the build and directs to `cfg.kvm.host.antiDetection.patchQemu`. |

*Note: You must provide a `cfg.kvm.host.hwidSeed` so the module can synthesize a cryptographically permanent UUID, Serial, and MAC Address.*
| `cloudInit.extraConfig` | lines | `""` | Extra cloud-config YAML appended to user-data. |
| `cloudInit.networkConfig` | lines? | `null` | Override netplan v2 network-config. See [Cloud-init](#cloud-init). |

### Host options (`cfg.kvm.host`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `cpuVendor` | `"intel"` / `"amd"` / `"auto"` | `"auto"` | `"auto"` derives from `boot.kernelModules`. |
| `kernel.extraModules` | [str] | `[]` | Extra `boot.kernelModules`. |
| `kernel.extraParams` | [str] | `[]` | Extra kernel command-line params. |
| `kernel.nested` | bool | `true` | Nested virtualization (KVM in KVM). |
| `kernel.ignoreMsrs` | bool | `true` | KVM ignores unrecognized MSR accesses. |
| `libvirtd.onBoot` | `"start"` / `"ignore"` | `"ignore"` | Action on formerly running guests when the host boots. |
| `libvirtd.onShutdown` | `"shutdown"` / `"suspend"` | `"shutdown"` | Method used to halt guests on host shutdown. |
| `libvirtd.parallelShutdown` | int | `0` | Guests shut down concurrently (0 = sequential). |
| `libvirtd.shutdownTimeout` | int | `300` | Seconds to wait for guests to shut down. |
| `libvirtd.startDelay` | int | `0` | Seconds between guest starts (0 = parallel). |
| `libvirtd.runAsRoot` | bool | `true` | Run QEMU as root. |
| `libvirtd.swtpm` | bool | `true` | Enable swtpm for emulated TPM. |
| `libvirtd.allowedBridges` | [str] | `["virbr0"]` | Bridges allowed for `qemu:///session`. |
| `libvirtd.firewallBackend` | `"iptables"` / `"nftables"` | `"iptables"` | Firewall backend for libvirt network rules. |
| `libvirtd.extraConfig` | lines | `""` | Appended to `libvirtd.conf`. |
| `libvirtd.extraOptions` | [str] | `[]` | libvirtd CLI args. |
| `libvirtd.users.manage` | [str] | `[]` | Usernames added to `libvirtd`. |
| `libvirtd.users.monitor` | [str] | `[]` | Usernames added to `kvm-monitors`. |
| `libvirtd.hooks.bundled` | list of `"gpu-passthrough"` / `"libvirt-nosleep"` | `[]` | Bundled hook scripts to install. |
| `libvirtd.hooks.qemu` | attrs of path | `{}` | Custom QEMU hook scripts. |
| `storage.persistentPath` | path? | `null` | Relocate all KVM state; bind-mounts onto `/var/lib/libvirt`. |
| `tools.enable` | bool | `true` | Install core management tools. |
| `tools.gui` | bool | `false` | Install `virt-manager`, `virt-viewer`. |
| `tools.extraPackages` | [package] | `[]` | Additional packages. |
| `xrdp.enable` | bool | `true` | RDP for remote VM control. |
| `hwidSeed` | str? | `null` | **Mandatory if any guest is enabled.** 36-char UUID seed for generating deterministic SMBIOS/MACs. |
| `antiDetection.patchQemu` | bool | `false` | Recompiles a pinned QEMU binary to remove "QEMU Keyboard", "BOCHS", etc. |
| `antiDetection.patchKernel` | bool | `false` | Compiles a pinned Linux Kernel with KVM RDTSC timing patches applied. |
| `antiDetection.custom...` | - | `null` | Extensive escape hatches to provide custom QEMU/Kernel source URLs and patches. |

#### IOMMU Options (`cfg.kvm.host.kernel.iommu`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `kernel.iommu.enable` | bool | `false` | Force-enable IOMMU. Auto-enabled when any guest uses `passthrough.pci`. |
| `kernel.iommu.mode` | `"pt"` / `"off"` | `"pt"` | IOMMU mode: `pt` (passthrough) or `off`. Maps to the `iommu=` kernel param. |

#### Host Bridges Options (`cfg.kvm.host.networking.bridges`)

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `networking.bridges[].name` | str | (required) | Bridge interface name (e.g. `"br0"`). |
| `networking.bridges[].interface` | str? | `null` | Physical NIC to enslave. |
| `networking.bridges[].address` | str? | `null` | IPv4 address for the bridge. |
| `networking.bridges[].prefixLength` | int | `24` | Subnet prefix length. |

---

## Cloud-init

When `cloudInit.enable` is set, the module generates a NoCloud seed ISO at
runtime (`cloud-init-seed.iso`) and attaches it as a CD-ROM. The guest's
cloud image reads it on first boot to configure the user, SSH keys, hostname,
and packages without manual installer interaction.

The seed includes a `network-config` (netplan v2). By default the module
generates a config that enables DHCP on each declared interface, matched by
its **deterministic MAC**:

```yaml
version: 2
ethernets:
  n0:
    match:
      macaddress: 52:54:00:76:6a:14
    dhcp4: true
```

cloud-init matches interfaces by MAC, so pinning the MAC both in the domain
XML and in the seed ensures cloud-init always configures the NIC the VM
actually receives, even if the guest name (and therefore the MAC) changes
between rebuilds. Set `cloudInit.networkConfig` to provide static IP
configuration or to override the generated config entirely; in that case you
are responsible for matching the interface (e.g. by MAC or name) yourself.

`cloudInit.passwordAgePath` and `graphics.passwordAgePath` take paths to
age-encrypted files; the module decrypts them via agenix at runtime and
injects the password into the seed or applies it to the SPICE/VNC server
after VM start.

---

## Optional peer dependency: agenix

The password features above rely on agenix (`age.secrets`). The module only
references `age.secrets` when at least one guest sets a `passwordAgePath` (for
`graphics` or `cloudInit`). If you use those features, import
`agenix.nixosModules.default` on the host as well. With no `passwordAgePath`
set, agenix is not required.

---

## Storage and persistence

By default guest disk images live under `/var/lib/libvirt/qemu/<name>/` (or
`/var/lib/libvirt/qemu/` for the domain XML). Set
`cfg.kvm.host.storage.persistentPath` to relocate all KVM state to a
separate disk or dataset:

- `${persistentPath}/host/` is bind-mounted onto `/var/lib/libvirt`, so
  NVRAM, TPM state, and domain definitions survive a host reinstall.
- Guest disk images are stored under `${persistentPath}/guests/<name>/`.
- `${persistentPath}/guests/` is registered as the `kvm-guests` libvirt
  storage pool.

Disk images are created only when they do not already exist; the persistence
model is covered in [What is managed, and what is not](#what-is-managed-and-what-is-not).

---

## Networking

Guest interfaces are declared under `networks`:

- `type = "user"`: QEMU SLIRP NAT. No host configuration required; suitable
  for quick setups.
- `type = "network"`: attach to a libvirt-managed network (e.g. the default
  `virbr0` NAT bridge).
- `type = "bridge"`: attach to a host bridge. Declare host bridges under
  `cfg.kvm.host.networking.bridges`.
- `type = "direct"`: macvtap direct attachment to a physical NIC.

Host bridges (`cfg.kvm.host.networking.bridges`) can enslave a physical NIC
and take a static IPv4 address. The default libvirt NAT bridge (`virbr0`) is
always available.

---

## Device passthrough

PCI and USB passthrough are declared per guest. When any guest requests PCI
passthrough, the module enables IOMMU (`intel_iommu`/`amd_iommu`) and binds
the listed PCI IDs to `vfio-pci` at boot. PCI BDFs use the standard Linux
form (`0000:01:00.0`) and are translated to libvirt address XML for you.

```nix
cfg.kvm.guests.windows = {
  vcpus = 8;
  memory = 32768;
  cpu.hidden = true; # anti-cheat / hypervisor hiding

  passthrough.pci = [
    { id = "0000:01:00.0"; romBar = false; }
  ];
  passthrough.usb = [
    { vendor = "0x1234"; product = "0x5678"; usb3 = true; }
  ];
};
```

The module raises an assertion if a PCI device is assigned to more than one
guest.

For GPU passthrough workflows, enable the bundled `gpu-passthrough` hook
(`host.libvirtd.hooks.bundled`), which unbinds PCI hostdevs from the host
driver before VM start and rebinds them on stop. The bundled
`libvirt-nosleep` hook inhibits host sleep while any VM is running.

---

## Paravirtualized Graphics (Venus & Virgl)

Virtual machines traditionally struggle with 3D hardware acceleration unless you dedicate an entire physical GPU to them via PCIe Passthrough (VFIO).

This module natively integrates **VirtIO-GPU API Proxying**, allowing your VMs to leverage the host's physical GPU without exposing its exact PCI identifiers to the guest. 

By setting `paravirtGraphics.enable = true` and selecting a backend (like `venus` for Vulkan or `virgl` for OpenGL), the guest translates 3D API calls and sends them across the VM boundary using direct shared memory buffers (`blob=on`). The host's native graphics drivers (Mesa) execute the commands and display them seamlessly.

*Note: The module handles host-side privilege elevation automatically. If QEMU runs as the unprivileged `qemu-libvirtd` user, the module automatically maps that user to the `render` group to guarantee direct rendering node access (`/dev/dri/renderD128`).*

---

## Anti-VM Detection (Stealth & Cloaking)

For use cases requiring robust malware sandbox evasion or anti-cheat compliance, this module integrates a mathematical, heavily opinionated cloaking engine.

### Tier 1 & 1.5: XML Scrubbing and PCI Cloaking
Setting `guests.<name>.antiDetection.enable = true` instantly scrubs the generated libvirt XML of standard paravirtualized identifiers:
* **Processor Masquerading:** Forces `host-passthrough`, strips the `hypervisor` CPU flag, and spoofs the Hyper-V vendor ID to `GenuineIntel`.
* **Topology Cloaking:** Forces block storage devices to standard `sata` buses and network interfaces to Intel `e1000e` NICs. Removes memory ballooning devices, VirtIO RNG, and the QEMU Guest Agent entirely.
* **Procedural Hardware IDs:** Using the host's global `hwidSeed` and the guest's `domainName`, the module mathematically guarantees a globally unique, RFC-4122 compliant UUID v4, a 14-character uppercase Serial Number, and a pseudorandomly assigned consumer Motherboard Profile (e.g., ASUS, MSI, Gigabyte).

### Tier 2: QEMU Binary Patching
Setting `cfg.kvm.host.antiDetection.patchQemu = true` elevates stealth to the QEMU binary itself.
NixOS will natively pull the QEMU source code, pin the version, and apply extensive source-level patches to purge over 75 hardcoded strings from the ACPI tables and USB device descriptors (e.g. changing "QEMU Keyboard" to "ASUS Keyboard" and "BOCHS" to "INTEL"). 

### Tier 3: Kernel RDTSC Patching
Setting `cfg.kvm.host.antiDetection.patchKernel = true` applies a KVM RDTSC timing patch to the Linux Kernel to defeat hyper-aggressive anti-cheats (like Vanguard) that use timing attacks to detect VM-Exits.
* **Batteries-Included:** By default, this forces your host to compile and use the pinned `Linux 6.1 LTS` kernel and applies our vendored KVM patch.
* **Escape Hatch:** You can override this entirely for newer kernels by providing your own `.patch` file via `customKernelPatch` and custom source URLs.
*(Note: Compiling the Linux kernel from source can take 30-90+ minutes depending on your CPU).*

---

## Access tiers

libvirt on NixOS enforces access at the *connection* level via polkit:
`org.libvirt.unix.manage` (read-write) and `org.libvirt.unix.monitor`
(read-only). Per-operation `api.*` actions are not checked, so the connection
level is the only tier that is reliably enforced. The module exposes both:

- **`cfg.kvm.host.libvirtd.users.manage`**: usernames added to the `libvirtd`
  group. Full read-write access to `qemu:///system`: `virt-manager`, `virsh`,
  and lifecycle control all work. Edits by these users are still reverted to
  the Nix-defined XML by the per-guest watch service.
- **`cfg.kvm.host.libvirtd.users.monitor`**: usernames added to a
  `kvm-monitors` group. Read-only access, enforced by a polkit rule
  (`11-kvm-monitors.rules`, ordered after NixOS's `10-nixos.rules`) that
  denies `unix.manage` and allows `unix.monitor`. The rule is first-match,
  so a user in both groups keeps manage access. Monitor users can use
  `virsh -r` and `virt-viewer`. `virt-manager` opens read-write connections,
  so it will not work for monitor users.

Neither list has any users by default.

---

## Escape hatches

The module favors declarative configuration and still lets you reach below
the option surface when needed:

- **`extraXML`**: raw XML appended to the generated domain definition for
  elements the module does not expose as options.
- **`extraQemuArgs`**: additional QEMU command-line arguments.
- **`networks[].mac`** and **`smbios.uuid`**: override the deterministic
  identities when you need specific values.
- **`cloudInit.networkConfig`** and **`cloudInit.extraConfig`**: full
  control over cloud-init networking and user-data.
- **`host.libvirtd.hooks.qemu`**: custom QEMU hook scripts.

These exist for cases the option surface does not cover. When you use them,
the rest of the reconciliation machinery still applies to whatever the module
generates.

---

## Desktop integration

When `cfg.kvm.host.tools.gui` is true, a `.desktop` entry is generated per
enabled guest (`VM: <name>` → `virt-viewer --connect qemu:///system <name>`).
`virt-viewer` opens a read-only connection, so these launchers work for both
manage- and monitor-scope users. `LIBVIRT_DEFAULT_URI=qemu:///system` is set
so command-line tools target the system instance where guests are defined.

---

## How it works

Each enabled guest is backed by a oneshot systemd service,
`kvm-guest-<name>.service`, that runs on boot when `autoStart` is set and on
`nixos-rebuild switch`. Its `preStart` prepares the storage directory,
creates any missing disk images (or downloads them via `sourceUrl`), builds
the cloud-init seed ISO when enabled, and runs `virsh define` from XML
generated in the Nix store. Existing disks are never touched. Because the
XML is generated deterministically, `virsh define` produces byte-identical
stored XML on every rebuild, so re-defining an unchanged guest is a no-op and
reconciliation is idempotent.

A second layer keeps the stored XML aligned to that configuration after the
fact. A `systemd.path` unit watches `/var/lib/libvirt/qemu/<name>.xml`; when
the file changes, a paired service compares its sha256 against a hash saved
after the module's own `virsh define`. Matching hashes mean the write was the
module's own, which breaks the feedback loop, since libvirt rewrites the file
on every define even when the content is unchanged. A mismatch means the file
was edited imperatively, and the service re-defines the domain from the Nix
store XML and records the new hash. `virsh edit` and `virt-manager` remain
usable for inspection, but only the Nix configuration can durably change a
managed guest's definition.

Reproducibility across rebuilds depends on stable identities. `nixos-kvm`
derives each interface's MAC from `52:54:00:` plus bytes of
`sha256("<name>-<interface-index>")`, and the domain UUID from
`sha256("<name>")`, overridable via `smbios.uuid`. The pinned MAC keeps DHCP
leases, firewall rules, and the stored domain XML stable; the stable UUID
means `virsh define` updates the existing domain instead of creating a new
one. Supply an explicit `networks[].mac` or `smbios.uuid` to take direct
control.

Guests removed from `cfg.kvm.guests` are undefined by `kvm-cleanup.service`,
which runs after `libvirtd` on every boot and rebuild. It preserves NVRAM and
emulated TPM state with `--keep-nvram --keep-tpm`, so re-adding a guest later
recovers its UEFI variables. On the host side, the module enables
`virtualisation.libvirtd`, wires KVM and IOMMU/VFIO kernel parameters when
needed, sets `LIBVIRT_DEFAULT_URI=qemu:///system`, and registers a
`kvm-guests` storage pool when `host.storage.persistentPath` is set.

---

## Design goals

- Infrastructure belongs in Git.
- VM definitions should be reproducible across rebuilds and portable between
  hosts.
- Hidden imperative state should not accumulate.
- Declarative configuration should be authoritative; manual drift should be
  corrected automatically.
- Users should have escape hatches when the option surface is insufficient.

`nixos-kvm` does one job: declaratively manage libvirt/KVM virtual machines on
NixOS, as an extension of the NixOS module system. Proxmox is a useful point
of comparison when translating VM configurations; this module does not aim
for feature parity with it.

---

## License

`nixos-kvm` is free software released under the terms of the GNU General
Public License v3.0 or (at your option) any later version. See
[LICENSE](LICENSE) for the full text.