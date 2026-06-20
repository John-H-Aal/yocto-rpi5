# Yocto RPi5 Project — Technical Reference

## Platform Summary

| | |
|---|---|
| **Yocto release** | Scarthgap 5.0 LTS |
| **Host** | Fedora 44, x86_64, AMD Ryzen AI 9 HX PRO 370, 62 GB RAM |
| **Target** | Raspberry Pi 5, 8 GB RAM, Cortex-A76 (aarch64) |
| **MACHINE** | `raspberrypi5` |
| **DISTRO** | `poky` |
| **Init manager** | systemd (via `DISTRO_FEATURES:append = " systemd usrmerge"`) |
| **Kernel** | Linux 6.6.63 (from meta-raspberrypi, Scarthgap branch) |
| **Boot device** | NVMe via Argon ONE V3 PCIe adapter (M.2 NVMe) |
| **Fallback** | microSD (EEPROM silent fallback — stays inserted) |
| **Network** | Static link-local, eth0, `169.254.100.1/16` via systemd-networkd |
| **SSH** | `root@169.254.100.1`, ED25519 key baked into image, no password |

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

EXTRA_IMAGE_FEATURES = "ssh-server-dropbear"

# RPi closed-source WiFi firmware — without this, bitbake errors on license check
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch"

# systemd as init manager — required for pi-ble-status and reliable service management
# WARNING: changing this requires `bitbake -c cleansstate <image>` before rebuilding.
# sstate will serve packages built without systemd support, causing silent failures
# (e.g. NetworkManager failing to configure interfaces).
DISTRO_FEATURES:append = " systemd usrmerge"
VIRTUAL-RUNTIME_init_manager = "systemd"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"

BB_NUMBER_THREADS = "24"
PARALLEL_MAKE = "-j24"

# Shared caches outside build directory — survive `bitbake cleansstate`
DL_DIR = "${TOPDIR}/../downloads"
SSTATE_DIR = "${TOPDIR}/../sstate-cache"
```

`wic.bmap` enables sparse flashing via `bmaptool`. The `.wks` file is `meta-john/wic/nvme-raspberrypi.wks` — a custom layout targeting `nvme0n1` (FAT32 boot + ext4 root, both `--align 4096`).

## Images

### `core-image-minimal` (staging / SD card)
Standard OE image. SSH added via `EXTRA_IMAGE_FEATURES += "ssh-server-dropbear"` in `local.conf`. Used solely to flash `rpi5-base-image` onto the NVMe from a running Pi. Presents an RSA host key (Dropbear); does not contain the user's ED25519 authorized key. Use `-o StrictHostKeyChecking=no` when SSHing into it.

### `rpi5-base-image` (target / NVMe)
Defined in `meta-john/recipes-core/images/rpi5-base-image.bb`. Inherits `core-image`. Key additions:

```bitbake
IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL:append = " \
    bluez5 \
    pi-ble-status \
    eth0-networkd-config \
    ssh-keys \
    e2fsprogs e2fsprogs-mke2fs e2fsprogs-e2fsck e2fsprogs-resize2fs \
    resize-rootfs \
    bmaptool \
    util-linux util-linux-lsblk util-linux-blkid \
    parted curl nano \
"
```

## `meta-john` Recipe Details

### `wlan0-config`
Installs `/etc/systemd/network/20-wlan0.network` with DHCP for wlan0. No credentials — WiFi is provisioned at runtime via BLE. Pulls in `wpa-supplicant` as an `RDEPENDS`.

Sets `RequiredForOnline=no` in the `[Link]` section. Without this, `systemd-networkd-wait-online` blocks `network-online.target` until wlan0 appears and acquires a carrier — brcmfmac takes ~33 seconds to initialize, delaying SSH by the same amount. eth0 is static and does not have this problem; wlan0 is optional so it must not gate boot.

### `eth0-networkd-config`
Installs `/etc/systemd/network/10-eth0.network` with a static IP config:

```ini
[Match]
Name=eth0

[Network]
Address=169.254.100.1/16
```

systemd-networkd is enabled by default when `systemd` is in `DISTRO_FEATURES`. No gateway or DNS — intentional for a direct-cable link-local setup.

**Why not NetworkManager:** NM built from sstate cache (before `DISTRO_FEATURES` included `systemd`) silently fails to configure interfaces. systemd-networkd is simpler, ships with systemd, and works correctly out of the box.

### `ssh-keys`
Installs `/home/root/.ssh/authorized_keys` (mode 0600, dir 0700) with the pre-defined ED25519 public key. Root's home in Yocto's `/etc/passwd` is `/home/root`, not `/root` — the file must go there or sshd silently ignores it. `PermitRootLogin prohibit-password` is set via `ROOTFS_POSTPROCESS_COMMAND` in the image recipe (required without `debug-tweaks`).

### `pi-ble-status`
A Python 3 BLE GATT server (bluez5/dbus) that advertises as the hostname and exposes read-only characteristics:

| UUID suffix | Value |
|---|---|
| `1001` | wlan0 IP |
| `1002` | eth0 IP |
| `1003` | CPU temperature |
| `1004` | Uptime |
| `1005` | Hostname |

Useful for diagnosing networking issues before SSH is reachable. Requires `bluez5`, `python3-dbus`, `python3-pygobject`, and `bluetooth.target` in systemd.

Characteristic `1006` is writable — write `SSID/password` (or `SSID:password` or `SSID\npassword`) to provision WiFi at runtime. The script writes `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`, enables and starts `wpa_supplicant@wlan0.service`. Credentials persist on the ext4 rootfs across reboots; a reflash wipes them. Read `1006` back for status (`connecting:SSID`), read `1001` for the wlan0 DHCP IP once connected.

### `init-ifupdown` bbappend (for `core-image-minimal`)
Appends a static IP stanza to `/etc/network/interfaces`. Works because `core-image-minimal` does not include NetworkManager — `init-ifupdown` owns `eth0` without conflict.

### `packagegroup-base.bbappend`
Removes `ofono` and `neard` from the image. These are pulled in as hard `RDEPENDS` via `packagegroup-base-3g` and `packagegroup-base-nfc` respectively — `BAD_RECOMMENDATIONS` has no effect. The bbappend removes them from the packagegroup's `RDEPENDS` directly.

### `resize-rootfs`
systemd oneshot service that runs `resize2fs /dev/nvme0n1p2` on first boot after `parted` expands the partition to fill the disk. Runs once and self-disables via a stamp file (`/var/lib/resize-rootfs-done`). Required because `wic` images are fixed-size; the 116 GB NVMe would otherwise show the image's ~2 GB root.

## NVMe Boot Configuration

EEPROM `BOOT_ORDER=0xf16`:

| Nibble (RTL) | Device |
|---|---|
| `6` | NVMe (PCIe) — tried first |
| `1` | SD card — fallback if NVMe fails |
| `f` | Restart loop |

SD card stays permanently inserted as a silent recovery fallback. With a healthy NVMe boot partition, the SD is never selected.

## EEPROM Update Procedure (RPi5 / BCM2712)

Pre-built binaries are in `~/repos/yocto-rpi5/rpi-eeprom/`:
- `pieeprom-nvme-first.bin` / `.sig` — `BOOT_ORDER=0xf16` (NVMe first)
- `pieeprom-sd-first.bin` / `.sig` — SD first

**RPi5 requires three files on mmcblk0p1 — `recovery.bin` is mandatory:**

```bash
# From a running Pi (SD or NVMe boot), mount the SD boot partition:
mount /dev/mmcblk0p1 /mnt
cp ~/repos/yocto-rpi5/rpi-eeprom/pieeprom-nvme-first.bin /mnt/pieeprom.upd
cp ~/repos/yocto-rpi5/rpi-eeprom/pieeprom-nvme-first.sig /mnt/pieeprom.sig
cp ~/repos/yocto-rpi5/rpi-eeprom/firmware-2712/default/recovery.bin /mnt/recovery.bin
sync && umount /mnt && reboot
```

Without `recovery.bin`, the bootloader silently ignores `pieeprom.upd`. The files are placed on the **SD's** mmcblk0p1 — placing them on nvme0n1p1 causes the bootloader to wipe the entire NVMe boot partition after applying the update.

Use `pieeprom-2026-05-26.bin` (`default` channel). The `2026-06-17` firmware has a regression preventing NVMe boot via the Argon ONE V3 PCIe adapter.

## Build Environment

```bash
cd ~/repos/yocto-rpi5
umask 022          # Yocto sanity checker rejects umask 0002 or looser
source poky/oe-init-build-env build-rpi5
bitbake rpi5-base-image
```

**After any `DISTRO_FEATURES` change:** `bitbake -c cleansstate rpi5-base-image && bitbake rpi5-base-image`. sstate aggressively caches `do_image_complete` and package compilations — stale cached packages built without systemd support will be used silently otherwise.

`BB_HASHSERVE_UPSTREAM` should be commented out if `python3-websockets` is not installed on the host.

## Flash Procedure

```bash
# Laptop → SD card (staging image)
bzcat build-rpi5/tmp/deploy/images/raspberrypi5/core-image-minimal-raspberrypi5.rootfs.wic.bz2 \
    | sudo dd of=/dev/sdX bs=4M

# Insert SD. BOOT_ORDER=0xf16 boots NVMe first, so zero the boot sector to force SD fallback:
ssh root@169.254.100.1 'dd if=/dev/zero of=/dev/nvme0n1p1 bs=512 count=1 && reboot'

# Wait for SD boot (Dropbear RSA — StrictHostKeyChecking=no required)
ssh-keygen -R 169.254.100.1
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@169.254.100.1 'echo up'; do sleep 5; done

# Confirm SD boot
ssh -o StrictHostKeyChecking=no root@169.254.100.1 'cat /proc/cmdline | grep -o "root=[^ ]*"'
# expect: root=/dev/mmcblk0p2

# Pipe NVMe image from laptop directly to Pi
bzcat build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | ssh -o StrictHostKeyChecking=no root@169.254.100.1 'dd of=/dev/nvme0n1 bs=4M && sync'

# Reboot (separate command — 'reboot' inside the pipe returns Access denied on SD image)
ssh -o StrictHostKeyChecking=no root@169.254.100.1 'reboot'

# Pi boots from NVMe (SD stays in as silent fallback)
ssh-keygen -R 169.254.100.1 && ssh root@169.254.100.1

# Re-provision WiFi via BLE: write "SSID/password" to characteristic 1006
# Read characteristic 1001 for wlan0 DHCP IP, then: ssh root@<wlan0-ip>
```

Never write to `nvme0n1` while it is the running root — ext4 corruption, read-only remounts, sshd unable to generate host keys.

## NVMe-Specific Wic Fixes

Yocto's wic `direct.py` imager only adds the `p` partition separator for `mmcblk` devices:

```python
prefix = 'p' if part.disk.startswith('mmcblk') else ''
```

With `--ondisk nvme0n1`, wic generates `/dev/nvme0n11` (wrong) instead of `/dev/nvme0n1p1` in fstab, and `root=/dev/mmcblk0p2` in `cmdline.txt`. Both are patched inside the wic image at build time via `IMAGE_POSTPROCESS_COMMAND` in `rpi5-base-image.bb`:

1. Decompress with `pbzip2`
2. Patch `cmdline.txt` using `mcopy` (mtools FAT access via `@@offset` at byte 4,194,304 = sector 8192 × 512, from `--align 4096` in the wks)
3. Append `reboot=cold` to `cmdline.txt`
4. Patch `/etc/fstab` using `debugfs` (`rm` then `write` — `write` fails on existing files)
5. Recompress with `pbzip2`

Use `${IMAGE_LINK_NAME}` (not `${IMAGE_NAME}`) for the wic path — `IMAGE_NAME` includes `DATETIME` and won't match sstate-served files.

## Reboot Mode: `reboot=cold`

The RPi5 firmware injects `reboot=w` (warm reboot) at the start of the kernel command line. On a warm reboot, PCIe is not fully reset. After a large `dd` write to NVMe, the controller has pending internal operations; a warm reboot leaves it in a busy state and the bootloader falls back to SD.

`reboot=cold` is appended to `cmdline.txt` in `IMAGE_POSTPROCESS_COMMAND`. Kernel parameters are last-value-wins, so `reboot=cold` overrides the firmware-injected `reboot=w`, ensuring a full PCIe reset on every reboot.

## Package Name Surprises

| Package | Recipe name in poky |
|---|---|
| bmap-tools | `bmaptool` |
| e2fsprogs (resize2fs only) | `e2fsprogs-resize2fs` |
| Full e2fsprogs | `e2fsprogs` |

## Known Issues / Non-Issues

- **Fedora 44 host warning** — harmless, Yocto's validated host list lags behind actual compatibility
- **`synaptics-killswitch` license** — required for `linux-firmware-rpidistro-bcm43455` (WiFi); this build is Ethernet-only but accepting it avoids build failure if firmware is pulled in transitively
- **SSH host key generation on read-only rootfs** — not a problem here (ext4 rw), but worth knowing: `openssh` generates host keys via postinstall; read-only rootfs at first boot = sshd won't start
- **systemd-networkd + NetworkManager conflict** — do not enable both; they fight over the interface. If both are in `multi-user.target.wants` with no `.network` config file for networkd and a broken NM, neither will configure eth0 and the failure is silent
- **`debug-tweaks` + OpenSSH `PermitEmptyPasswords`** — unreliable; bake the authorized key into the image via `ssh-keys` recipe instead
- **Root home directory is `/home/root`, not `/root`** — Yocto's default `/etc/passwd` sets root's home to `/home/root`. The `ssh-keys` recipe must install `authorized_keys` to `${D}/home/root/.ssh/`, not `${D}/root/.ssh/`. sshd resolves `AuthorizedKeysFile .ssh/authorized_keys` relative to the user's home — wrong path = silent key auth failure even when `PermitRootLogin prohibit-password` is correctly set
- **`PermitRootLogin` must be explicitly set** — without `debug-tweaks`, the compiled-in OpenSSH default blocks root login. Set `PermitRootLogin prohibit-password` via `ROOTFS_POSTPROCESS_COMMAND` in the image recipe
- **WiFi regulatory domain** — wpa_supplicant requires `country=DK` in `wpa_supplicant-wlan0.conf` or the AP rejects association at the driver level (status_code=16, BSSID all-zeros). The BLE provisioning script now writes `country=DK` automatically
