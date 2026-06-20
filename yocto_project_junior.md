# Yocto RPi5 Project — Explained for a Junior Developer

## Overview

This project uses the **Yocto Project** to build a custom embedded Linux image for a Raspberry Pi 5, targeting NVMe boot via an Argon ONE V3 PCIe case. The build runs on a Fedora 44 x86_64 laptop and cross-compiles for the Pi's ARM64 architecture.

## What is Yocto?

Yocto is a build framework — not a Linux distribution, but a system for *producing* Linux distributions. It cross-compiles everything from source: kernel, bootloader, libraries, userspace packages, and generates a flashable image.

The core tooling is:

- **BitBake** — the task scheduler and build engine (like `make`, but far more sophisticated)
- **OpenEmbedded** — the metadata layer system that BitBake operates on
- **poky** — the reference distribution and the starting layer stack

## The Layer Model

Yocto is organized into **layers** — directories of metadata (recipes, configuration, patches) stacked on top of each other. Each layer adds or modifies what gets built.

This project uses four layers:

```
poky/                    # Base layer: core recipes, BitBake, build infrastructure
meta-openembedded/       # Extended package collection (meta-oe, meta-python, meta-networking)
meta-raspberrypi/        # BSP layer: RPi kernel config, firmware, device tree overlays
meta-john/               # Custom layer: our image, network config, tweaks
```

Layers are declared in `build-rpi5/conf/bblayers.conf`. Order matters — later layers can override earlier ones using `.bbappend` files.

## Recipes

A **recipe** (`.bb` file) describes how to fetch, configure, compile, and install a single package. It defines things like:

- `SRC_URI` — where to get the source
- `do_compile` — how to build it
- `do_install` — where to put the result
- `RDEPENDS` — runtime dependencies

A `.bbappend` file extends an existing recipe without modifying it — useful for adding a config file to someone else's package or tweaking `RDEPENDS`.

## What's in `meta-john`

This is the custom layer. It contains:

| Recipe | Purpose |
|---|---|
| `rpi5-base-image.bb` | Defines the final NVMe image: which packages are included |
| `eth0-networkd-config/` | Installs a systemd-networkd `.network` file for static IP on eth0 |
| `wlan0-config/` | Installs a systemd-networkd DHCP profile for wlan0 + pulls in wpa-supplicant |
| `ssh-keys/` | Bakes the authorized SSH public key into `/home/root/.ssh/authorized_keys` (root's home in Yocto is `/home/root`) |
| `pi-ble-status/` | BLE GATT server: reads IP/temp/uptime/hostname; writable char 1006 provisions WiFi |
| `init-ifupdown/` bbappend | Configures static IP for `core-image-minimal` (no NetworkManager) |
| `packagegroup-base.bbappend` | Removes `ofono` and `neard` (unwanted modem/NFC daemons) |
| `resize-rootfs/` | First-boot script that expands the root partition to fill the drive |

## Two Images

The project builds two images, used in sequence:

### 1. `core-image-minimal`
A minimal image flashed to the SD card. Its only job is to boot the Pi, give SSH access, and flash the real image to the NVMe drive. Includes `ssh-server-dropbear` via `EXTRA_IMAGE_FEATURES`.

### 2. `rpi5-base-image`
The permanent image, built by `meta-john`. Runs from NVMe. Includes:
- `openssh-server` (via `IMAGE_FEATURES`)
- `systemd-networkd` with a static IP config file
- Your SSH public key pre-installed
- `e2fsprogs` for filesystem tools
- `bmaptool` for flashing
- `pi-ble-status` — BLE diagnostic server
- The auto-resize-rootfs service

## Key `local.conf` Settings

```bitbake
MACHINE = "raspberrypi5"
DISTRO = "poky"
IMAGE_FSTYPES = "wic.bz2 wic.bmap"
EXTRA_IMAGE_FEATURES = "ssh-server-dropbear"
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch"   # required for RPi WiFi firmware

# Use systemd as init manager (required for pi-ble-status and service management)
DISTRO_FEATURES:append = " systemd usrmerge"
VIRTUAL-RUNTIME_init_manager = "systemd"

BB_NUMBER_THREADS = "24"
PARALLEL_MAKE = "-j24"
```

`wic` is Yocto's image format tool. It produces a full disk image (partition table + boot + root) based on a `.wks` kickstart file. `.bmap` is a block map used by `bmaptool` to skip empty blocks when flashing — much faster than `dd`.

## The Build Flow

```bash
cd ~/repos/yocto-rpi5
umask 022                                        # required — Yocto enforces this
source poky/oe-init-build-env build-rpi5         # sets up environment, cds into build dir

bitbake core-image-minimal                       # ~1–4 hours first time (downloads + compiles)
bitbake rpi5-base-image
```

Output lands in `build-rpi5/tmp/deploy/images/raspberrypi5/`.

Subsequent builds are fast because Yocto has two caches:
- **sstate-cache** — cached task outputs (survive across builds)
- **downloads/** — fetched source archives

## Networking

The Pi has a static IP `169.254.100.1/16` on `eth0` — link-local range, direct cable to laptop (no router). The laptop's Ethernet interface uses `169.254.x.x/16`.

For `rpi5-base-image`, the static IP is configured via a systemd-networkd `.network` file installed by the `eth0-networkd-config` recipe:

```ini
[Match]
Name=eth0

[Network]
Address=169.254.100.1/16
```

For `core-image-minimal`, it's configured via `/etc/network/interfaces` using `init-ifupdown`.

**Important:** Do not use NetworkManager with a systemd init manager built from sstate cache — NM may be cached without systemd integration and silently fail to configure interfaces. systemd-networkd is simpler and more reliable here.

WiFi (`wlan0`) uses DHCP via systemd-networkd. Credentials are provisioned at runtime over BLE — write `SSID/password` to characteristic `1006`, read the resulting DHCP IP from characteristic `1001`. No credentials are stored in the image or the repo. After provisioning, `wpa_supplicant@wlan0` is enabled and WiFi reconnects automatically on every reboot. A reflash wipes the credentials — re-provision via BLE after each reflash.

## NVMe Boot

The Pi's EEPROM boot order is set to `0xf16`:
- `6` (rightmost) = NVMe — tried first
- `1` = SD card — fallback if NVMe fails
- `f` = restart loop

This is set using pre-built EEPROM binaries in the `rpi-eeprom/` directory. The SD card stays inserted as a silent fallback — it does not interfere with normal NVMe boots.

## Flash Procedure (Summary)

```bash
# Laptop → SD card
bzcat core-image-minimal-raspberrypi5.rootfs.wic.bz2 | sudo dd of=/dev/sdX bs=4M

# Insert SD, boot Pi, SSH in
until ssh -o StrictHostKeyChecking=no root@169.254.100.1 'echo up'; do sleep 5; done

# Pipe NVMe image directly from laptop to Pi
bzcat rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | ssh -o StrictHostKeyChecking=no root@169.254.100.1 'dd of=/dev/nvme0n1 bs=4M && sync && reboot'

# Pi reboots — comes up from NVMe automatically (SD stays in as fallback)
ssh-keygen -R 169.254.100.1 && ssh root@169.254.100.1
```

## Gotchas Worth Knowing

- Always `umask 022` before sourcing the build env or builds will fail
- `bmaptool` in poky is the package name — not `bmap-tools`
- `resize2fs` lives in `e2fsprogs-resize2fs`, not `e2fsprogs`
- `ofono` and `neard` must be removed via a `packagegroup-base.bbappend` — they're hard `RDEPENDS`, not recommendations, so `BAD_RECOMMENDATIONS` won't remove them
- The Fedora 44 "not a validated distro" warning is harmless
- When changing `DISTRO_FEATURES` (e.g. adding `systemd`), run `bitbake -c cleansstate <image>` before rebuilding — sstate can serve stale packages built without systemd support
- SD image (core-image-minimal) uses Dropbear and presents an RSA host key; NVMe image uses OpenSSH with your ED25519 key baked in — always use `StrictHostKeyChecking=no` when SSHing into the SD image
- **Root's home directory is `/home/root`**, not `/root` — install `authorized_keys` to `/home/root/.ssh/`, not `/root/.ssh/`
- **`PermitRootLogin` must be set explicitly** — without `debug-tweaks`, root SSH is blocked by default; the image recipe sets it to `prohibit-password` via `ROOTFS_POSTPROCESS_COMMAND`
- **WiFi needs `country=DK`** in the wpa_supplicant config or the AP rejects association
