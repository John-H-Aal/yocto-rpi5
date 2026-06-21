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
| **Boot device** | NVMe via Argon ONE V3 PCIe adapter (M.2 NVMe), RAUC A/B slots, firmware `tryboot` (no U-Boot) |
| **Recovery** | microSD — SD-first EEPROM (`0xf61`); insert for recovery/reflash, remove to run NVMe |
| **Network** | Static link-local, eth0, `169.254.100.1/16` via systemd-networkd |
| **SSH** | `root@169.254.100.1`, ED25519 key baked into image, no password |

## Layer Stack

```
poky/                          # Scarthgap branch — core OE, BitBake, poky DISTRO
meta-openembedded/meta-oe      # Scarthgap branch
meta-openembedded/meta-python  # Scarthgap branch
meta-openembedded/meta-networking  # Scarthgap branch
meta-raspberrypi/              # Scarthgap branch — RPi BSP, kernel, firmware
meta-rauc/                     # Scarthgap branch — RAUC core + bbclass
meta-rauc-community/meta-rauc-raspberrypi  # RAUC RPi integration
meta-john/                     # Custom layer (git submodule → github.com/John-H-Aal/meta-john)
```

> Note: `meta-lts-mixins` was previously in the stack solely to backport the Scarthgap U-Boot recipe.
> With U-Boot dropped (firmware `tryboot` instead), it has been removed.

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

`wic.bmap` enables sparse flashing via `bmaptool`. The `.wks` file is
`meta-john/wic/rauc-raspberrypi-tryboot.wks` — a GPT A/B layout targeting `nvme0n1`, all partitions
`--align 4096`:

| Part | Label | FS | Size | Purpose |
|---|---|---|---|---|
| p1 | `bootsel` | vfat | 64 MB | `autoboot.txt` selector — stable, never written by RAUC |
| p2 | `boot-a` | vfat | 256 MB | Slot A boot files (kernel, dtb, config.txt, cmdline-*) |
| p3 | `boot-b` | vfat | 256 MB | Slot B boot files (cloned from p2 at wic build) |
| p4 | `rootfs-a` | ext4 | 4 GB | RAUC rootfs slot A |
| p5 | `rootfs-b` | ext4 | 4 GB | RAUC rootfs slot B |
| p6 | `data` | ext4 | rest | Persistent `/data` (grown on first boot) |

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
    eth0-networkd-config wlan0-config \
    ssh-keys \
    e2fsprogs e2fsprogs-mke2fs e2fsprogs-e2fsck e2fsprogs-resize2fs \
    bmaptool \
    util-linux util-linux-lsblk util-linux-blkid \
    parted curl nano \
    rauc rauc-tryboot-backend rauc-mark-good \
    data-mount resize-data \
"
```

`rauc` + `rauc-tryboot-backend` provide the A/B OTA machinery (`bootloader=custom` handler);
`data-mount` mounts `/data` (p6) and `resize-data` grows it on first boot. (The pre-A/B
`resize-rootfs` recipe was removed — it was a no-op on the A/B layout, where rootfs slots are
fixed-size and only `/data` grows.)

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

### `resize-data`
systemd oneshot service that grows the last partition (`/data`, `nvme0n1p6`) to fill the disk on
first boot, then expands the filesystem. Self-disables via a stamp file (`/var/lib/resize-data-done`).
Because the wic is `dd`'d onto a much larger disk, the GPT **backup** header sits at the old image
end, so `parted` is first fed `Fix` to relocate it before `resizepart`. A/B-safe: `/data` is shared
across both rootfs slots but the stamp is per-slot, so the script also skips (via sysfs geometry)
when the partition already fills the disk — otherwise the second slot's first boot would re-run the
resize and fail. (The rootfs slots themselves are fixed-size; only `/data` grows.)

## NVMe Boot Configuration

EEPROM `BOOT_ORDER=0xf61` (read right-to-left):

| Nibble (RTL) | Device |
|---|---|
| `1` | SD card — tried first |
| `6` | NVMe (PCIe) — used when no SD is present |
| `f` | Restart loop |

**SD-first**, deliberately: the microSD always wins when inserted, giving a guaranteed recovery and
reflash path (flashing is always done from SD, never against the running NVMe root). Remove the SD to
run the NVMe system. Everyday resilience is the RAUC A/B rootfs slots on the NVMe — a bad update boots
the other slot, no SD involved.

## EEPROM Update Procedure (RPi5 / BCM2712)

Pre-built binaries are in `~/repos/yocto-rpi5/rpi-eeprom/`:
- `pieeprom-sd-first.bin` / `.sig` — `BOOT_ORDER=0xf61` (SD first) ← current
- `pieeprom-nvme-first.bin` / `.sig` — `BOOT_ORDER=0xf16` (NVMe first, legacy)

**RPi5 requires three files on mmcblk0p1 — `recovery.bin` is mandatory:**

```bash
# From a running Pi (SD or NVMe boot), mount the SD boot partition:
mount /dev/mmcblk0p1 /mnt
cp ~/repos/yocto-rpi5/rpi-eeprom/pieeprom-sd-first.bin /mnt/pieeprom.upd
cp ~/repos/yocto-rpi5/rpi-eeprom/pieeprom-sd-first.sig /mnt/pieeprom.sig
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

# Insert SD and power on. SD-first EEPROM (0xf61) boots the SD recovery image directly —
# no need to disable NVMe boot.
ssh-keygen -R 169.254.100.1
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@169.254.100.1 'echo up'; do sleep 5; done

# Confirm SD boot
ssh -o StrictHostKeyChecking=no root@169.254.100.1 'cat /proc/cmdline | grep -o "root=[^ ]*"'
# expect: root=/dev/mmcblk0p2

# Pipe NVMe image from laptop directly to Pi (BusyBox dd — no status=progress)
bzcat build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | ssh -o StrictHostKeyChecking=no root@169.254.100.1 'dd of=/dev/nvme0n1 bs=4M && sync'

# Power off, REMOVE the SD card, power on — firmware boots the NVMe (slot A).
# (Leaving the SD in would just boot the recovery image again — SD-first.)
ssh-keygen -R 169.254.100.1 && ssh root@169.254.100.1

# Re-provision WiFi via BLE: write "SSID/password" to characteristic 1006
# Read characteristic 1001 for wlan0 DHCP IP, then: ssh root@<wlan0-ip>
```

Never write to `nvme0n1` while it is the running root — ext4 corruption, read-only remounts, sshd unable to generate host keys.

## Tryboot Wic Post-Processing (`setup_tryboot_image`)

`wic` populates the slot-A boot partition (p2) via `bootimg-partition`, but it knows nothing about the
tryboot selector (p1), the per-slot cmdline files, the `config.txt [boot_partition=N]` conditional, or
the slot-B boot partition (p3). An `IMAGE_POSTPROCESS_COMMAND` in `rpi5-base-image.bb` injects all of
that into the compressed wic after creation, computing FAT offsets from the GPT (`sfdisk -J`) rather
than hardcoding them:

1. Decompress with `pbzip2`.
2. **p1 (selector):** write `autoboot.txt` — `[all] boot_partition=2`, `[tryboot] boot_partition=3`
   (slot A is the committed default at flash time).
3. **p2 (boot-A):** write `cmdline-rootfs-A.txt` (`root=/dev/nvme0n1p4 rauc.slot=A`) and
   `cmdline-rootfs-B.txt` (`root=…p5 rauc.slot=B`) via `mcopy`.
4. **p2:** prepend the firmware `[boot_partition=N]` selector to `config.txt` so the *same* boot image
   picks the matching rootfs in whichever slot it runs from.
5. **Clone p2 → p3 (boot-B):** byte-range `dd` of the now fully-populated boot-A onto boot-B, so slot B
   is bootable straight from a flash (a rootfs-only RAUC bundle never writes boot files). `config.txt`
   is identical in both slots, so the copy is correct as-is. The `dd` uses
   `skip_bytes`/`seek_bytes`/`count_bytes` with raw byte offsets — **bitbake's pysh shell parser
   rejects `$((...))` arithmetic.**
6. Recompress with `pbzip2`.

`/etc/fstab` is handled separately by `fixup_fstab` in `ROOTFS_POSTPROCESS_COMMAND` (baked into the
rootfs so the standalone `.ext4` used for OTA is correct too). It is intentionally **slot-agnostic with
no `/boot` entry** — RAUC installs the same rootfs to either slot, so it must not hardcode a boot
device; the boot partitions are written via their block device and the tryboot backend mounts the
selector (p1) on demand. This also sidesteps the old `wic`/`direct.py` `nvme0n11` quirk (it only adds
the `p` separator for `mmcblk` devices), since no `/boot` fstab entry is generated and `root=` is set
explicitly per slot.

Use `${IMAGE_LINK_NAME}` (not `${IMAGE_NAME}`) for the wic path — `IMAGE_NAME` includes `DATETIME` and
won't match sstate-served files.

## Reboot Mode: `reboot=cold` (historical note)

The RPi5 firmware injects `reboot=w` (warm reboot), which does not fully reset PCIe. In the old
NVMe-first layout, a warm reboot right after a large `dd` to NVMe could leave the controller busy and
make the bootloader fall back to SD, so `patch_nvme_image` appended `reboot=cold` to `cmdline.txt`
(last-value-wins overrides `reboot=w`).

The current tryboot `cmdline-rootfs-{A,B}.txt` do **not** set `reboot=cold`, and it has not been
needed: A↔B OTA swaps and rollbacks reboot reliably warm, and the only large NVMe `dd` (the initial
flash) is followed by a physical power-cycle anyway (SD removal). If a warm-reboot PCIe issue ever
resurfaces, re-add `reboot=cold` to both cmdline files in `setup_tryboot_image`.

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
- **RAUC bundle is rootfs-only** (`RAUC_BUNDLE_SLOTS = "rootfs"`) — an OTA updates only the inactive rootfs slot; the boot partitions (kernel/dtb/config.txt) change only on a full wic flash. Fine for userspace/rootfs updates; a kernel OTA would need a boot+rootfs bundle
- **`bootloader=custom`, `mark-active other` required** — `rauc install` writes the inactive slot but does **not** auto-activate in this config. The explicit `rauc status mark-active other` calls the tryboot backend that rewrites `autoboot.txt`. Automatic rollback-on-failure (firmware one-shot `tryboot` via `vcmailbox`) is not wired in — `raspberrypi-utils` is not installed
