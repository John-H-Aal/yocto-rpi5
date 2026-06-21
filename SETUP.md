# Yocto RPi5 Setup Log

## Goal

Build a custom embedded Linux image for Raspberry Pi 5 with NVMe boot support using Yocto Scarthgap (5.0 LTS). Final target: headless, SSH-only system booting from NVMe via Argon ONE V3 PCIe enclosure.

**Host:** Fedora 44, x86_64, AMD Ryzen AI 9 HX PRO 370, 62 GB RAM  
**Target:** Raspberry Pi 5, 8 GB RAM, Argon ONE V3 PCIe enclosure with NVMe

---

## Final State

| Item | Value |
|---|---|
| SSH | `ssh root@169.254.100.1` (no password) |
| Boot device | NVMe (`/dev/nvme0n1`) — EEPROM boot order `0xf61` (SD first, NVMe fallback) |
| Root filesystem | RAUC A/B: `nvme0n1p4` (slot A) / `nvme0n1p5` (slot B); `/data` on `nvme0n1p6` |
| SD card | Recovery / reflash tool — `core-image-minimal`; insert for recovery, remove to run NVMe |
| Kernel | Linux 6.6.63, `kernel_2712.img` loaded directly by firmware (tryboot, no U-Boot) |
| Network | Static IP `169.254.100.1/16` on `eth0` via systemd-networkd |
| Laptop interface | `enp195s0f0`, `169.254.163.154/16` (link-local, no DHCP needed) |

---

## 1. Host Dependencies

### Already present on Fedora 44

| Package | Version |
|---|---|
| gcc / gcc-c++ | 16.1.1 |
| git | 2.54.0 |
| python3 | 3.14.5 |
| make | 4.4.1 |
| gawk | 5.3.2 |
| tar / bzip2 / gzip / xz / zstd | system |
| cpio | 2.15 |
| texinfo | 7.2 |
| patch / diffutils / findutils / file | system |
| socat | 1.8.1.1 |
| python3-pip | 26.0.1 |

### Installed during setup

```bash
sudo dnf install -y diffstat chrpath lz4 rpcgen SDL2-devel bmap-tools
```

| Package | Version | Purpose |
|---|---|---|
| diffstat | 1.69 | Required by Yocto sanity checker |
| chrpath | 0.16 | RPATH manipulation for cross-compiled binaries |
| lz4 | 1.10.0 | Compression tool (lz4c) required by Yocto |
| rpcgen | 1.4 | RPC code generator (needed by glibc recipe) |
| SDL2-devel (sdl2-compat) | 2.32.68 | SDL frontend for qemu-system-native |
| bmap-tools | — | Fast verified image flashing to SD card |

---

## 2. Layers Cloned

All cloned into `~/repos/yocto-rpi5/`, all on the **scarthgap** branch.

```bash
git clone --branch scarthgap https://git.yoctoproject.org/poky
git clone --branch scarthgap https://github.com/openembedded/meta-openembedded
git clone --branch scarthgap https://git.yoctoproject.org/meta-raspberrypi
git clone https://github.com/raspberrypi/rpi-eeprom   # for EEPROM update tooling
```

| Layer | Purpose |
|---|---|
| `poky` | Yocto reference distro — bitbake, OE-Core, toolchain |
| `meta-openembedded/meta-oe` | Extra recipes: e2fsprogs, parted, etc. |
| `meta-openembedded/meta-python` | Python package recipes |
| `meta-openembedded/meta-networking` | NetworkManager |
| `meta-raspberrypi` | RPi5 BSP — kernel, firmware, device trees |
| `meta-john` | Custom layer — https://github.com/John-H-Aal/meta-john |

For the RAUC A/B build (`feature/rauc-tryboot`), also clone `meta-rauc` and `meta-rauc-community`, and
use the moto-timo `meta-raspberrypi` fork — see **§11.1**.

---

## 3. Custom Layer: meta-john

```
meta-john/
├── conf/
│   └── layer.conf
├── wic/
│   └── rauc-raspberrypi-tryboot.wks            — GPT A/B wic layout targeting nvme0n1
├── recipes-connectivity/
│   ├── eth0-networkd-config/
│   │   ├── eth0-networkd-config_1.0.bb         — installs systemd-networkd profile
│   │   └── files/
│   │       └── 10-eth0.network                 — static IP 169.254.100.1/16
│   ├── pi-ble-status/
│   │   ├── pi-ble-status_1.0.bb                — BLE GATT server: diagnostics + WiFi provisioning
│   │   └── files/
│   │       ├── pi-ble-status.py
│   │       └── pi-ble-status.service
│   └── wlan0-config/
│       ├── wlan0-config_1.0.bb                 — DHCP for wlan0 via systemd-networkd + wpa-supplicant
│       └── files/
│           └── 20-wlan0.network
├── recipes-core/
│   ├── images/
│   │   └── rpi5-base-image.bb                  — RAUC A/B NVMe image + setup_tryboot_image
│   ├── rauc/                                   — system.conf (bootloader=custom) + bbappend
│   ├── rauc-tryboot-backend/                   — tryboot-backend.sh (autoboot.txt handler)
│   ├── rauc-bundle/                            — rpi5-rauc-bundle (.raucb) recipe
│   ├── data-mount/                             — mounts /data (nvme0n1p6)
│   ├── resize-data/                            — first-boot /data resize (GPT-aware, A/B-safe)
│   ├── ssh-keys/
│   │   ├── ssh-keys_1.0.bb                     — bakes authorized_keys into image
│   │   └── files/
│   │       └── authorized_keys
│   ├── init-ifupdown/
│   │   ├── init-ifupdown_%.bbappend            — static IP for core-image-minimal
│   │   └── files/
│   │       └── interfaces
│   └── packagegroups/
│       └── packagegroup-base.bbappend          — removes ofono/neard from base
├── recipes-bsp/
│   └── u-boot/                                 — autoboot_no_delay.cfg only (parse-time dep; U-Boot unused)
```

### `rpi5-base-image.bb` — packages

| Package | Purpose |
|---|---|
| `ssh-server-openssh` (IMAGE_FEATURES) | OpenSSH server |
| `bluez5` + `pi-ble-status` | BLE GATT server: chars `1001`–`1005` expose IP/temp/uptime/hostname; char `1006` (writable) provisions wlan0 WiFi at runtime |
| `wlan0-config` + `wpa-supplicant` | systemd-networkd DHCP profile for wlan0 (`RequiredForOnline=no` — does not gate SSH); credentials written by BLE provisioning |
| `eth0-networkd-config` | systemd-networkd static IP profile |
| `ssh-keys` | Bakes authorized ED25519 key into `/root/.ssh/authorized_keys` |
| `e2fsprogs` + `e2fsprogs-mke2fs` + `e2fsprogs-e2fsck` + `e2fsprogs-resize2fs` | Filesystem tools |
| `bmaptool` | Image flashing |
| `util-linux` (lsblk, blkid) | Block device tools |
| `parted` | Partition management |
| `rauc` + `rauc-tryboot-backend` + `rauc-mark-good` | A/B OTA: `bootloader=custom` + `autoboot.txt` handler |
| `data-mount` + `resize-data` | Mount `/data` (p6) and grow it on first boot (A/B-safe) |
| `curl` | Network transfers |
| `nano` | Basic editor |

### Network: two approaches, one per image

| Image | Method | Why |
|---|---|---|
| `core-image-minimal` | `init-ifupdown` bbappend | No NetworkManager — ifupdown handles eth0 |
| `rpi5-base-image` | systemd-networkd `10-eth0.network` | Reliable with systemd init; NM fails silently from sstate cache |

Both result in `eth0` at `169.254.100.1/16` on boot.

### `packagegroup-base.bbappend` — removing unwanted services

```bitbake
RDEPENDS:packagegroup-base-extended:remove = "packagegroup-base-3g packagegroup-base-nfc"
```

Removes `ofono` (mobile telephony), `neard` (NFC) — no relevant hardware.

### First-boot auto-resize (`resize-data`)

`resize-data.service` grows `/data` (the last partition, `nvme0n1p6`) to fill the disk on first boot:
1. Skip if already done (`/var/lib/resize-data-done`) **or** if the partition already reaches the end
   of the disk — A/B safety: `/data` is shared but the stamp is per-slot, so the second slot's first
   boot must not re-run the resize (it would fail).
2. Feed `Fix` to `parted` to relocate the GPT **backup** header (the wic was `dd`'d onto a larger disk).
3. `parted resizepart 6 100%`, `partx -u` (BLKPG online update — root is on the same disk), `e2fsck`,
   then `resize2fs`.

> The old `resize-rootfs` init script (root-partition resize, pre-A/B) has been removed — it was a
> no-op on the A/B layout (rootfs slots are fixed-size; only `/data` grows).

---

## 4. Build Configuration

### Build directory

```bash
cd ~/repos/yocto-rpi5
umask 022                               # required — Yocto sanity check enforces this
source poky/oe-init-build-env build-rpi5
```

### `build-rpi5/conf/bblayers.conf`

```
poky/meta
poky/meta-poky
poky/meta-yocto-bsp
meta-openembedded/meta-oe
meta-openembedded/meta-python
meta-openembedded/meta-networking
meta-raspberrypi
meta-john
```

### `build-rpi5/conf/local.conf` — key settings

| Variable | Value | Reason |
|---|---|---|
| `MACHINE` | `raspberrypi5` | Target hardware |
| `DISTRO` | `poky` | Reference distro |
| `IMAGE_FSTYPES` | `wic.bz2 wic.bmap` | Partition-aware image for flashing |
| `EXTRA_IMAGE_FEATURES` | `ssh-server-dropbear` | Dropbear SSH on core-image-minimal |
| `DISTRO_FEATURES:append` | `systemd usrmerge` | systemd as init manager (required for pi-ble-status) |
| `VIRTUAL-RUNTIME_init_manager` | `systemd` | Selects systemd over sysvinit |
| `LICENSE_FLAGS_ACCEPTED` | `synaptics-killswitch` | Required for RPi WiFi firmware in packagegroup |
| `BB_NUMBER_THREADS` | `24` | Ryzen AI 9 HX PRO 370 thread count |
| `PARALLEL_MAKE` | `-j24` | Per-recipe make parallelism |
| `DL_DIR` | `${TOPDIR}/../downloads` | Shared, survives `tmp` cleans |
| `SSTATE_DIR` | `${TOPDIR}/../sstate-cache` | Shared sstate cache |

### Build commands

```bash
cd ~/repos/yocto-rpi5
umask 022
source poky/oe-init-build-env build-rpi5

bitbake core-image-minimal    # SD recovery image (dropbear, static IP via ifupdown)
bitbake rpi5-base-image       # NVMe target image (openssh, NM, full tooling)
```

### Build gotchas

| Issue | Fix |
|---|---|
| `umask` too restrictive | Run `umask 022` before sourcing build env — every time |
| `BB_HASHSERVE_UPSTREAM` failing | `python3-websockets` not installed; commented out |
| Fedora 44 not validated | Warning only, works fine |
| `bmap-tools` wrong package name | Recipe uses `bmaptool` (poky), not `bmap-tools` |
| `synaptics-killswitch` license | Must add `LICENSE_FLAGS_ACCEPTED` for RPi WiFi firmware |
| `ssh-server-*` not in `core-image-minimal` | Must add to `EXTRA_IMAGE_FEATURES` explicitly |
| `ofono` hard dependency via `packagegroup-base-3g` | Remove via `packagegroup-base.bbappend` |
| NetworkManager fails silently after `DISTRO_FEATURES` change | NM from sstate cache lacks systemd integration; use systemd-networkd + `.network` file instead; run `cleansstate` after changing `DISTRO_FEATURES` |

---

## 5. Flashing SD Card

bmaptool requires exclusive device access — udisks2 auto-mounts and blocks it:

```bash
sudo umount -l /dev/sda1 /dev/sda2 2>/dev/null
sudo systemctl stop udisks2

cd ~/repos/yocto-rpi5/build-rpi5
bzcat tmp/deploy/images/raspberrypi5/core-image-minimal-raspberrypi5.rootfs.wic.bz2 \
    | sudo dd of=/dev/sda bs=4M

sudo systemctl start udisks2
sudo eject /dev/sda
```

---

## 6. Boot Architecture (firmware tryboot A/B — no U-Boot)

U-Boot has no BCM2712 (Pi 5) PCIe driver, so it cannot boot NVMe. Instead the Pi firmware loads the
kernel directly and A/B slot selection uses the firmware's native `tryboot` mechanism.

```
Power on
  └── EEPROM (BOOT_ORDER=0xf61 — SD first, NVMe fallback)
        ├── microSD present → boots core-image-minimal (recovery / flashing tool)
        └── microSD absent  → boots NVMe:
              └── p1 bootsel (FAT) → autoboot.txt
                    ├── [all]     boot_partition=2   (committed slot)
                    └── [tryboot] boot_partition=3   (one-shot try target)
                          │
                          ▼ firmware loads config.txt from the chosen boot partition
                    p2 boot-A / p3 boot-B (FAT) → kernel_2712.img + dtb + config.txt
                          config.txt: [boot_partition=2] cmdline=cmdline-rootfs-A.txt
                                      [boot_partition=3] cmdline=cmdline-rootfs-B.txt
                          │
                          ▼
                    p4 rootfs-A (root=…p4, rauc.slot=A) / p5 rootfs-B (root=…p5, rauc.slot=B)
                    p6 data (/data, shared, grown on first boot)
```

`config.txt` is identical in both boot partitions; the firmware's `[boot_partition=N]` conditional
selects the matching `cmdline-rootfs-{A,B}.txt`, so one boot image works in either slot.

---

## 7. EEPROM Boot Order

The `rpi-eeprom/` directory contains pre-built firmware binaries and update tooling.

**BOOT_ORDER values (read right to left):** `0x6` = NVMe, `0x1` = SD, `0xf` = restart loop.  
`0xf61` = SD first → NVMe fallback → restart.

Pre-built binaries:
- `rpi-eeprom/pieeprom-sd-first.bin` / `.sig` — `BOOT_ORDER=0xf61` ← current (SD first)
- `rpi-eeprom/pieeprom-nvme-first.bin` / `.sig` — `BOOT_ORDER=0xf16` (NVMe first, legacy)

**Why SD-first?** Reflashing is always done from the SD recovery image (never against the running NVMe
root). SD-first makes that deterministic: insert the SD → it always boots recovery; remove it → the
NVMe boots. The old NVMe-first order needed a fragile "zero the NVMe boot sector to force fallback"
hack to get into recovery. Everyday resilience now comes from the RAUC A/B slots, not the SD.

**RPi5 (BCM2712) requires `recovery.bin` — without it the bootloader silently ignores `pieeprom.upd`.**

To apply from a running Pi (SD card must be inserted):

```bash
# On the Pi:
mount /dev/mmcblk0p1 /mnt
cp /tmp/pieeprom-sd-first.bin /mnt/pieeprom.upd
cp /tmp/pieeprom-sd-first.sig /mnt/pieeprom.sig
cp /tmp/recovery.bin /mnt/recovery.bin
sync && umount /mnt && reboot
```

Or pipe all three from the laptop first:

```bash
scp rpi-eeprom/pieeprom-sd-first.bin \
    rpi-eeprom/pieeprom-sd-first.sig \
    rpi-eeprom/firmware-2712/default/recovery.bin \
    root@169.254.100.1:/tmp/
```

The bootloader applies the update and reboots automatically. Files are cleared from mmcblk0p1 after the update.

**Always place update files on `mmcblk0p1` (SD), never on `nvme0n1p1`.** Placing them on nvme0n1p1 causes the bootloader to wipe the entire NVMe boot partition after applying the update.

**Firmware version:** Use `pieeprom-2026-05-26.bin` (`default` channel). The `2026-06-17` firmware has a regression preventing NVMe boot via the Argon ONE V3 PCIe adapter.

---

## 8. NVMe Reflash Procedure

**Always flash from SD, never while NVMe is the running root** — writing to a mounted root corrupts the filesystem.

```bash
# Step 1: Insert the SD and power on. SD-first EEPROM (0xf61) boots the SD recovery
#         image directly — no need to disable NVMe boot.
ssh-keygen -R 169.254.100.1
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@169.254.100.1 'echo up'; do sleep 5; done

# Confirm SD boot (Dropbear RSA host key — StrictHostKeyChecking=no required)
ssh -o StrictHostKeyChecking=no root@169.254.100.1 'cat /proc/cmdline | grep -o "root=[^ ]*"'
# expect: root=/dev/mmcblk0p2

# Step 2: Pipe the NVMe image directly from laptop to Pi (BusyBox dd — no status=progress)
bzcat ~/repos/yocto-rpi5/build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | ssh -o StrictHostKeyChecking=no root@169.254.100.1 'dd of=/dev/nvme0n1 bs=4M && sync'

# Step 3: Power off, REMOVE the SD card, power on — firmware boots the NVMe (slot A).
#         (Leaving the SD in would just boot the recovery image again — SD-first.)
#         resize-data grows /data on first boot.
ssh-keygen -R 169.254.100.1 && ssh root@169.254.100.1
# ED25519 key accepted, no password
```

**Why pipe instead of scp to /tmp?** Avoids filling the SD root filesystem. The image streams directly from the laptop into dd on the Pi.

**SD card SSH note:** The SD image (core-image-minimal) uses Dropbear and presents an RSA host key. Your ED25519 key is not in the SD image. Always use `-o StrictHostKeyChecking=no` for SD SSH sessions. Each NVMe rootfs slot also generates its own host key on first boot, so `ssh-keygen -R` is needed after an A↔B swap too.

**No manual post-flash patching needed.** The `rpi5-base-image` recipe injects the tryboot boot files
into the wic at build time via `setup_tryboot_image` (`IMAGE_POSTPROCESS_COMMAND`): `autoboot.txt` on
p1, per-slot `cmdline-rootfs-{A,B}.txt` and the `config.txt [boot_partition=N]` selector on p2, and a
byte-range clone of boot-A onto boot-B (p3) so slot B is bootable straight from the flash. `/etc/fstab`
is baked slot-agnostic (no `/boot` entry) by `fixup_fstab` in `ROOTFS_POSTPROCESS_COMMAND`.

---

## 9. Day-to-Day Usage

```bash
# SSH in
ssh root@169.254.100.1

# Rebuild image
cd ~/repos/yocto-rpi5
umask 022
source poky/oe-init-build-env build-rpi5
bitbake rpi5-base-image

# Reflash — see Section 8
```

---

## 10. Known Issues / Future Work

| Item | Notes |
|---|---|
| Clock resets to 1970 on boot | No RTC battery — add `ntp`/`chrony` + internet access to fix |
| wic generates `nvme0n11` instead of `nvme0n1p1` | `direct.py` only adds the `p` separator for `mmcblk` devices. Sidestepped now: `/etc/fstab` is baked slot-agnostic with no `/boot` entry (`fixup_fstab`), and `root=` is set explicitly per slot in `cmdline-rootfs-{A,B}.txt` — nothing relies on wic's nvme fstab. |
| Yocto sstate mirror disabled | Enable after `sudo dnf install python3-websockets` and uncommenting `BB_HASHSERVE_UPSTREAM` in `local.conf` |
| Poky WARNING in MOTD | Remove `/etc/motd` in `rpi5-base-image.bb` if desired |
| Changing `DISTRO_FEATURES` requires full cleansstate | Run `bitbake -c cleansstate rpi5-base-image && bitbake rpi5-base-image` — sstate serves stale packages built without systemd support, causing silent failures (e.g. NM not configuring eth0) |
| BLE available on Pi | `pi-ble-status` broadcasts IP (wlan0/eth0), CPU temp, uptime, hostname — useful diagnostic when SSH is unreachable. Pi BT MAC: D8:3A:DD:E6:3E:9C |

---

## 11. RAUC A/B OTA — feature/rauc-tryboot branch (firmware tryboot, no U-Boot)

> **Branch:** `feature/rauc-tryboot`  
> **Reference:** [Bootlin — Safe updates using RAUC on Raspberry Pi 5](https://bootlin.com/blog/safe-updates-using-rauc-on-raspberry-pi-5/)  
> **Build environment:** Docker (Ubuntu 22.04) — Fedora 44 is unsupported by Scarthgap.

**Why no U-Boot:** U-Boot has no BCM2712 (Pi 5) PCIe driver, so `nvme scan` / `fatload nvme` / `saveenv`
can never work — it cannot boot or write an environment on NVMe. A/B is therefore built on the Pi
firmware's native `tryboot` instead (`RPI_USE_U_BOOT = "0"`), with a custom RAUC `bootloader=custom`
backend that edits `autoboot.txt` on a stable selector partition.

### 11.1 Layer setup (clone on host before Docker)

```bash
cd ~/repos/yocto-rpi5

# meta-raspberrypi — moto-timo Scarthgap fork (retained for its RPi5 fixes).
# Upstream meta-raspberrypi would likely also work now that U-Boot is unused.
mv meta-raspberrypi meta-raspberrypi-upstream-bkp   # only if replacing an upstream clone
git clone --branch scarthgap https://github.com/moto-timo/meta-raspberrypi.git

# Official RAUC layer (Scarthgap branch)
git clone --branch scarthgap https://github.com/rauc/meta-rauc.git

# meta-rauc-community — RAUC RPi integration
git clone --branch scarthgap/raspberrypi5_u-boot \
    https://github.com/moto-timo/meta-rauc-community.git
```

> **`meta-lts-mixins` is no longer needed** — it existed solely to backport the Scarthgap U-Boot
> recipe, and was removed from `bblayers.conf` when U-Boot was dropped.
>
> **Parse-time note:** the U-Boot recipe is still *parsed* (not built) with `RPI_USE_U_BOOT="0"`, and
> bitbake checksums every recipe's `SRC_URI` at parse time. The moto-timo u-boot bbappend references
> `autoboot_no_delay.cfg`, which `meta-john/recipes-bsp/u-boot/` supplies so parsing succeeds.
>
> **Fork stability:** the moto-timo branches are development forks — pin to a commit SHA for
> reproducible builds.

### 11.2 Docker quickstart

```bash
cd ~/repos/yocto-rpi5

# Step 1 — Switch bblayers.conf to Docker paths (restore with git checkout afterwards)
cp build-rpi5/conf/bblayers-docker.conf.example build-rpi5/conf/bblayers.conf

# Step 2 — Enter the build container (sources oe-init-build-env automatically)
docker compose run --rm yocto-builder

# Inside the container:
umask 022
bitbake rpi5-base-image      # rootfs + GPT wic.bz2 (+ ext4 for the bundle)
bitbake rpi5-rauc-bundle     # assembles the signed .raucb update bundle
```

Built artifacts land in `build-rpi5/tmp/deploy/images/raspberrypi5/`.

> **cleansstate after image/postprocess changes:** sstate caches `do_image_complete` (and the bundle)
> aggressively. After editing `setup_tryboot_image`, `DEMO_VERSION`, the `.wks`, or recipe files, run
> `bitbake -c cleansstate rpi5-base-image rpi5-rauc-bundle` before rebuilding.

> **sstate note:** the native `sstate-cache/` is NOT reusable inside Docker (different host toolchains
> = different hashes). The Docker sstate lives in `./sstate-cache-docker/` (host bind mount).

### 11.3 RAUC signing keys (generate once)

```bash
cd ~/repos/yocto-rpi5

# create-example-keys.sh is in the meta-rauc-community repo
bash meta-rauc-community/scripts/create-example-keys.sh

# Copy output to meta-john/files/rauc-keys/ (gitignored — never commit .pem files)
cp *.pem meta-john/files/rauc-keys/
# Expected files:
#   ca.cert.pem            — installed to /etc/rauc/ca.cert.pem on the Pi (keyring)
#   development-1.cert.pem — bundle signing cert (used by rauc-bundle.bb)
#   development-1.key.pem  — private key, keep off the Pi
```

Keys must exist before running `bitbake rpi5-rauc-bundle`.

### 11.4 Partition layout (GPT, on `nvme0n1`)

WKS file: `meta-john/wic/rauc-raspberrypi-tryboot.wks`

| Part | Device | Size | Label | Purpose |
|---|---|---|---|---|
| p1 | `nvme0n1p1` | 64 MB | `bootsel` | `autoboot.txt` selector — stable, never written by RAUC |
| p2 | `nvme0n1p2` | 256 MB | `boot-a` | Slot A boot files (kernel, dtb, config.txt, cmdline-*) |
| p3 | `nvme0n1p3` | 256 MB | `boot-b` | Slot B boot files (cloned from p2 at wic build) |
| p4 | `nvme0n1p4` | 4 GB | `rootfs-a` | RAUC rootfs slot A |
| p5 | `nvme0n1p5` | 4 GB | `rootfs-b` | RAUC rootfs slot B |
| p6 | `nvme0n1p6` | remainder | `data` | Persistent `/data`, grown on first boot |

`system.conf` groups each vfat boot slot with its ext4 rootfs child (`boot.0`+`rootfs.0` = A,
`boot.1`+`rootfs.1` = B), `bootloader=custom`, handler `tryboot-backend.sh`.

### 11.5 Initial flash

Flash from the SD recovery image — see **§8**. Slot B's boot partition is populated automatically:
`setup_tryboot_image` clones boot-A onto boot-B at wic-build time, so **no manual `dd` slot clone is
needed**. After the first NVMe boot, `rauc status` shows slot A booted/good and slot B inactive/good;
`resize-data` has grown `/data`.

### 11.6 OTA update + slot switch

```bash
# On the laptop — copy the bundle to the Pi (use /data: large, persistent)
scp build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-rauc-bundle-raspberrypi5.raucb \
    root@169.254.100.1:/data/update.raucb

# On the Pi — install to the INACTIVE slot, activate it, reboot
rauc install /data/update.raucb     # writes the new rootfs to the other slot (verifies signature)
rauc status mark-active other        # backend rewrites autoboot.txt [all] to that slot
reboot

# After reboot — verify the swap
cat /proc/cmdline | grep -o "rauc.slot=[AB]"   # expect the other slot
rauc status                                     # Booted from / Activated = new slot
```

> **`rauc install` does NOT auto-activate** in this config — the explicit `rauc status mark-active
> other` is required; it calls the tryboot backend's `set-primary`, which rewrites `autoboot.txt`.
> The bundle is **rootfs-only**, so an OTA updates only the inactive rootfs slot; boot partitions
> change only on a full wic flash.

### 11.7 Rollback

Rollback is symmetric — re-activate the previous slot and reboot:

```bash
rauc status mark-active other   # flip autoboot.txt back to the previous slot
reboot
```

Automatic rollback-on-failure (the firmware one-shot `tryboot`) is **not yet wired in**: it needs
`raspberrypi-utils`/`vcmailbox` to set the firmware tryboot flag, which is not installed. The firmware
does not count boot attempts (booted = good), so rollback is the manual `mark-active other` above.

### 11.8 RAUC custom bootloader backend (`tryboot-backend.sh`)

In place of U-Boot environment variables, `bootloader=custom` invokes
`meta-john/recipes-core/rauc-tryboot-backend/files/tryboot-backend.sh`:

| Command | Action |
|---|---|
| `get-primary` | read `[all] boot_partition` from `autoboot.txt` → bootname (2→A, 3→B) |
| `set-primary <name>` | write `autoboot.txt` `[all]` = that slot, `[tryboot]` = the other |
| `get-state <name>` | always `good` (firmware keeps no attempt counter) |
| `set-state <name> good` | commit that slot as `[all]` |

The selector partition `nvme0n1p1` is mounted on demand at `/run/rauc-bootsel`.

### 11.9 Status

Built, flashed, and verified end-to-end on hardware: clean flash boots slot A; `rauc install` +
`mark-active other` + reboot swaps to slot B and back, both slots `running` and healthy. Optional/
deferred: automatic rollback-on-failure (firmware one-shot `tryboot` via `vcmailbox`), and a
boot+rootfs bundle for kernel OTAs (the current bundle is rootfs-only).
