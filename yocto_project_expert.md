# Yocto RPi5 Project — Technical Reference

## Platform Summary

| | |
|---|---|
| **Yocto release** | Scarthgap 5.0 LTS |
| **Host** | Fedora 44, x86_64, AMD Ryzen AI 9 HX PRO 370, 62 GB RAM |
| **Target** | Raspberry Pi 5, 8 GB RAM, Cortex-A76 (aarch64) |
| **MACHINE** | `raspberrypi5` |
| **DISTRO** | `poky` |
| **Kernel** | Linux 6.6.63 (from meta-raspberrypi, Scarthgap branch) |
| **Boot device** | NVMe via Argon ONE V3 PCIe adapter (M.2 NVMe) |
| **Fallback** | microSD (EEPROM silent fallback only) |
| **Network** | Static link-local, eth0, `169.254.100.1/16` |
| **SSH** | `root@169.254.100.1`, ED25519 key, no password (`debug-tweaks`) |

## Layer Stack

```
poky/                          # Scarthgap branch — core OE, BitBake, poky DISTRO
meta-openembedded/meta-oe      # Scarthgap branch
meta-openembedded/meta-python  # Scarthgap branch
meta-openembedded/meta-networking  # Scarthgap branch
meta-raspberrypi/              # Scarthgap branch — RPi BSP, kernel, firmware
meta-john/                     # Custom layer (git submodule → github.com/John-H-Aal/meta-john)
```

Declared in `build-rpi5/conf/bblayers.conf`. `meta-john` is last and takes priority in override resolution.

## `local.conf` Key Settings

```bitbake
MACHINE = "raspberrypi5"
DISTRO = "poky"
IMAGE_FSTYPES = "wic.bz2 wic.bmap"

EXTRA_IMAGE_FEATURES = "debug-tweaks ssh-server-dropbear"

# RPi closed-source WiFi firmware — without this, bitbake errors on license check
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch"

BB_NUMBER_THREADS = "24"
PARALLEL_MAKE = "-j24"

# Shared caches outside build directory — survive `bitbake cleansstate`
DL_DIR = "${TOPDIR}/../downloads"
SSTATE_DIR = "${TOPDIR}/../sstate-cache"
```

`wic.bmap` enables sparse flashing via `bmaptool`. The `.wks` file used is the default for `raspberrypi5` from meta-raspberrypi (`sdimage-raspberrypi.wks`), which lays out a FAT32 boot partition and ext4 root.

## Images

### `core-image-minimal` (staging / SD card)
Standard OE image. SSH added via `EXTRA_IMAGE_FEATURES += "ssh-server-dropbear"` in `local.conf` — it is not present by default. Used solely to flash `rpi5-base-image` onto the NVMe from a running Pi, then discarded.

### `rpi5-base-image` (target / NVMe)
Defined in `meta-john/recipes-core/images/rpi5-base-image.bb`. Inherits `core-image`. Key additions over the base:

```bitbake
IMAGE_INSTALL:append = " \
    networkmanager \
    openssh-server \
    e2fsprogs e2fsprogs-resize2fs \
    bmaptool \
    resize-rootfs \
"
```

`debug-tweaks` and `ssh-server-openssh` are set via `EXTRA_IMAGE_FEATURES` in `local.conf` (not in the recipe itself, to keep `local.conf` as the single override point for security posture).

## `meta-john` Recipe Details

### `nm-eth0-config` (for `rpi5-base-image`)
Installs a NetworkManager system connection keyfile to `/etc/NetworkManager/system-connections/eth0.nmconnection`. File permissions set to `0600` in `do_install` — NM refuses to load connections with looser permissions. Keyfile specifies:

```ini
[ipv4]
method=manual
address1=169.254.100.1/16
```

No gateway, no DNS — intentional for a direct-cable link-local setup.

### `init-ifupdown` bbappend (for `core-image-minimal`)
Appends a static IP stanza to `/etc/network/interfaces`. Works because `core-image-minimal` does not include NetworkManager — `init-ifupdown` owns `eth0` without conflict. Would break silently on `rpi5-base-image` because NM ignores `interfaces` by default.

### `packagegroup-base.bbappend`
Removes `ofono` and `neard` from the image. These are pulled in as hard `RDEPENDS` via `packagegroup-base-3g` and `packagegroup-base-nfc` respectively — `BAD_RECOMMENDATIONS` has no effect. The bbappend removes them from the packagegroup's `RDEPENDS` directly.

### `resize-rootfs`
SysVinit/systemd service that runs `resize2fs /dev/nvme0n1p2` on first boot after `parted` expands the partition to fill the disk. Runs once and self-disables via a stamp file. Required because `wic` images are fixed-size; the 116 GB NVMe would otherwise show the image's ~2 GB root.

## NVMe Boot Configuration

EEPROM `BOOT_ORDER=0xf16`:

| Nibble | Device |
|---|---|
| `f` | Restart loop (wraps around) |
| `1` | SD card |
| `6` | NVMe (PCIe) |

Evaluated right-to-left: NVMe → SD → loop. SD card is present but silent — the Pi boots from NVMe with SD inserted, useful as emergency fallback without any EEPROM re-flash.

EEPROM update applied from the booted Pi using `rpi-eeprom-config --apply` from the `rpi-eeprom` repo (checked out alongside the layers in the project root). The Argon ONE V3 exposes the NVMe via the Pi 5's PCIe x1 interface; no additional kernel config or device tree overlay is needed — `meta-raspberrypi` on Scarthgap includes NVMe support out of the box for `raspberrypi5`.

## Build Environment

```bash
cd ~/repos/yocto-rpi5
umask 022          # Yocto sanity checker rejects umask 0002 or looser
source poky/oe-init-build-env build-rpi5
bitbake rpi5-base-image
```

`umask 022` is mandatory — the Yocto sanity checker enforces it and will abort the build if violated. Easy to forget after a fresh shell.

`BB_HASHSERVE_UPSTREAM` should be commented out if `python3-websockets` is not installed on the host — BitBake will fail trying to connect.

Fedora 44 is not in Yocto's validated distro list; the warning is cosmetic.

## Flash Procedure

```bash
# Laptop → SD (staging)
bmaptool copy core-image-minimal-raspberrypi5.wic.bz2 /dev/sdX

# Pi (over SSH, SD boot) → NVMe
scp rpi5-base-image-raspberrypi5.wic.bz2 root@169.254.100.1:/tmp/
scp rpi5-base-image-raspberrypi5.wic.bmap root@169.254.100.1:/tmp/
ssh root@169.254.100.1
bmaptool copy /tmp/rpi5-base-image-raspberrypi5.wic.bz2 /dev/nvme0n1
reboot
```

Never run `bmaptool` against a mounted device. If reflashing a live NVMe system, boot from SD first (EEPROM fallback) before writing to `nvme0n1`. See `reflash-procedure` memory for the full safe sequence.

## Package Name Surprises

These diverge from what you'd expect from other distros:

| Package | Recipe name in poky |
|---|---|
| bmap-tools | `bmaptool` |
| e2fsprogs (resize2fs only) | `e2fsprogs-resize2fs` |
| Full e2fsprogs | `e2fsprogs` |

## NVMe-Specific Wic Fixes

Yocto's wic `direct.py` imager only adds the `p` partition separator for `mmcblk` devices:

```python
prefix = 'p' if part.disk.startswith('mmcblk') else ''
```

With `--ondisk nvme0n1`, wic generates `/dev/nvme0n11` (wrong) instead of `/dev/nvme0n1p1`. This affects both `cmdline.txt` (`root=/dev/mmcblk0p2`) and `/etc/fstab` (`/dev/nvme0n11 /boot`).

All three issues are patched inside the wic image at build time via `IMAGE_POSTPROCESS_COMMAND` in `rpi5-base-image.bb`. The function:
1. Decompresses with `pbzip2`
2. Patches `cmdline.txt` using `mcopy` (mtools FAT access via `@@offset` syntax at byte 4,194,304 = sector 8192 × 512, from `--align 4096` in the wks)
3. Appends `reboot=cold` to `cmdline.txt` (see below)
4. Patches `/etc/fstab` using `debugfs` (`rm` then `write`, since `write` fails on existing files)
5. Recompresses with `pbzip2`

`IMAGE_POSTPROCESS_COMMAND` runs as part of `do_image_complete`. Use `${IMAGE_LINK_NAME}` (not `${IMAGE_NAME}`) for the wic path — `IMAGE_NAME` includes `DATETIME` and won't match sstate-served files.

## Reboot Mode: `reboot=cold`

The RPi5 firmware injects `reboot=w` (warm reboot) at the start of the kernel command line. On a warm reboot, PCIe is not fully reset. After a large `dd` write to the NVMe, the NVMe controller has pending internal operations (garbage collection, wear leveling). A subsequent warm reboot leaves the controller in this busy state; the bootloader finds it unresponsive and falls back to SD.

`reboot=cold` is appended to `cmdline.txt` in `IMAGE_POSTPROCESS_COMMAND`. Kernel parameters are processed left-to-right with last-value-wins semantics, so `reboot=cold` overrides the firmware-injected `reboot=w`. This forces a full PCIe reset on every reboot, ensuring the NVMe controller is in a clean state when the bootloader probes it.

## First Boot After Flash

Despite `reboot=cold`, the RPi5 bootloader fails to boot NVMe on the very first boot after a raw `dd` flash when the SD card is physically present (with `BOOT_ORDER=0xf16`). The exact cause is unknown without UART bootloader logs. Once NVMe has completed one successful boot, subsequent reboots with SD inserted work correctly.

**Workaround**: remove the SD card for the first NVMe boot after each reflash, then reinsert. The SD sits unmounted as a silent fallback.

## EEPROM Firmware

`firmware-2712/stable/pieeprom-2026-06-17.bin` has a regression that prevents NVMe boot via the Argon ONE V3 PCIe adapter. Use `pieeprom-2026-05-26.bin` (`default` channel).

Always place `pieeprom.upd`/`pieeprom.sig` on the SD card's boot partition (mmcblk0p1), not on nvme0n1p1. Placing them on nvme0n1p1 causes the bootloader to clear the entire NVMe boot partition after applying the update.

## Known Issues / Non-Issues

- **Fedora 44 host warning** — harmless, Yocto's validated host list lags behind actual compatibility
- **`synaptics-killswitch` license** — required for `linux-firmware-rpidistro-bcm43455` (WiFi); no workaround if you want WiFi; this build is Ethernet-only so it could be omitted, but accepting it avoids build failure if firmware gets pulled in transitively
- **SSH host key generation on read-only rootfs** — not a problem here since the root is ext4 rw, but worth knowing: `openssh` generates host keys via a postinstall scriptlet; if rootfs is read-only at first boot, `sshd` won't start
- **NetworkManager vs ifupdown** — NM ignores `/etc/network/interfaces` by default; the two image types each use the appropriate mechanism and must not be cross-applied
