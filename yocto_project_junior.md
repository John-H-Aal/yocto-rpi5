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
| `nm-eth0-config/` | Installs a NetworkManager keyfile for static IP on eth0 |
| `init-ifupdown/` bbappend | Configures static IP for `core-image-minimal` (no NetworkManager) |
| `packagegroup-base.bbappend` | Removes `ofono` and `neard` (unwanted modem/NFC daemons) |
| `resize-rootfs/` | First-boot script that expands the root partition to fill the drive |

## Two Images

The project builds two images, used in sequence:

### 1. `core-image-minimal`
A minimal image flashed to the SD card. Its only job is to boot the Pi, give SSH access, and flash the real image to the NVMe drive using `bmaptool`. Includes `ssh-server-dropbear` via `EXTRA_IMAGE_FEATURES`.

### 2. `rpi5-base-image`
The permanent image, built by `meta-john`. Runs from NVMe. Includes:
- `networkmanager` with a static IP keyfile
- `openssh-server`
- `e2fsprogs-resize2fs` for filesystem resize
- `bmaptool` for flashing
- The auto-resize-rootfs init script

## Key `local.conf` Settings

```bitbake
MACHINE = "raspberrypi5"
DISTRO = "poky"
IMAGE_FSTYPES = "wic.bz2 wic.bmap"
EXTRA_IMAGE_FEATURES = "debug-tweaks ssh-server-dropbear"
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch"   # required for RPi WiFi firmware
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

The Pi has a static IP `169.254.100.1/16` on `eth0` — link-local range, direct cable to laptop (no router). The laptop's Ethernet interface (`enp195s0f0`) uses `169.254.163.154/16`.

For `rpi5-base-image`, the static IP is configured via a NetworkManager keyfile at `/etc/NetworkManager/system-connections/eth0.nmconnection` (permissions must be `0600` — NM refuses to load it otherwise).

For `core-image-minimal`, it's configured via `/etc/network/interfaces` using `init-ifupdown`.

## NVMe Boot

The Pi's EEPROM boot order is set to `0xf16`:
- `1` = SD card
- `6` = NVMe
- `f` = restart loop

`0xf16` means: try NVMe first, fall back to SD, loop. This is set using `rpi-eeprom-config` tools from the `rpi-eeprom` repository.

## Flash Procedure (Summary)

```bash
# On laptop: flash SD
bmaptool copy core-image-minimal-raspberrypi5.wic.bz2 /dev/sdX

# On Pi (over SSH): flash NVMe
bmaptool copy rpi5-base-image-raspberrypi5.wic.bz2 /dev/nvme0n1

# Remove SD, reboot — Pi comes up from NVMe
```

## Gotchas Worth Knowing

- Always `umask 022` before sourcing the build env or builds will fail
- `bmaptool` in poky is the package name — not `bmap-tools`
- `resize2fs` lives in `e2fsprogs-resize2fs`, not `e2fsprogs`
- `ofono` and `neard` must be removed via a `packagegroup-base.bbappend` — they're hard `RDEPENDS`, not recommendations, so `BAD_RECOMMENDATIONS` won't remove them
- The Fedora 44 "not a validated distro" warning is harmless
