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
| Boot device | NVMe (`/dev/nvme0n1`) — EEPROM boot order `0xf16` |
| Root filesystem | `nvme0n1p2` — `rpi5-base-image`, 116 GB available |
| SD card | Silent fallback — `core-image-minimal` on `mmcblk0` |
| Kernel | Linux 6.6.63, loaded from NVMe boot partition (`nvme0n1p1`) |
| Network | Static IP `169.254.100.1/16` on `eth0` via NetworkManager |
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

---

## 3. Custom Layer: meta-john

```
meta-john/
├── conf/
│   └── layer.conf
├── wic/
│   └── nvme-raspberrypi.wks               — wic layout targeting nvme0n1
├── recipes-connectivity/
│   └── nm-eth0-config/
│       ├── nm-eth0-config_1.0.bb          — installs NM connection profile
│       └── files/
│           └── eth0-static.nmconnection   — static IP 169.254.100.1/16
├── recipes-core/
│   ├── images/
│   │   └── rpi5-base-image.bb             — NVMe target image
│   ├── init-ifupdown/
│   │   ├── init-ifupdown_%.bbappend       — static IP for core-image-minimal
│   │   └── files/
│   │       └── interfaces
│   ├── packagegroups/
│   │   └── packagegroup-base.bbappend     — removes ofono/neard from base
│   └── resize-rootfs/
│       ├── resize-rootfs_1.0.bb           — first-boot partition resize
│       └── files/
│           └── resize-rootfs              — init script
```

### `rpi5-base-image.bb` — packages

| Package | Purpose |
|---|---|
| `ssh-server-openssh` (IMAGE_FEATURES) | OpenSSH server |
| `networkmanager` + `nm-eth0-config` | Networking with static IP |
| `e2fsprogs` + `e2fsprogs-mke2fs` + `e2fsprogs-e2fsck` + `e2fsprogs-resize2fs` | Filesystem tools |
| `bmaptool` | Image flashing |
| `util-linux` (lsblk, blkid) | Block device tools |
| `parted` | Partition management |
| `resize-rootfs` | Auto-expand root partition on first boot |
| `curl` | Network transfers |
| `nano` | Basic editor |

### Network: two approaches, one per image

| Image | Method | Why |
|---|---|---|
| `core-image-minimal` | `init-ifupdown` bbappend | No NetworkManager — ifupdown handles eth0 |
| `rpi5-base-image` | NetworkManager `.nmconnection` file | NM ignores `/etc/network/interfaces` |

Both result in `eth0` at `169.254.100.1/16` on boot.

### `packagegroup-base.bbappend` — removing unwanted services

```bitbake
RDEPENDS:packagegroup-base-extended:remove = "packagegroup-base-3g packagegroup-base-nfc"
```

Removes `ofono` (mobile telephony), `neard` (NFC) — no relevant hardware.

### First-boot auto-resize

`resize-rootfs` init script runs at priority S05 on first boot:
1. Detects root device and disk
2. Expands the root partition to fill the disk via `parted`
3. Runs `resize2fs` online (ext4 supports this while mounted)
4. Creates `/var/lib/resize-rootfs-done` flag — never runs again until next reflash

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
| `EXTRA_IMAGE_FEATURES` | `debug-tweaks ssh-server-dropbear` | Empty root password + SSH on minimal image |
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
| NetworkManager ignores `/etc/network/interfaces` | Use `.nmconnection` keyfile for `rpi5-base-image` |

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

## 6. Boot Architecture

```
Power on
  └── EEPROM bootloader (BOOT_ORDER=0xf16)
        ├── NVMe first (0x6) ← normal path
        │     └── nvme0n1p1 (FAT32 boot partition)
        │           ├── kernel_2712.img + bcm2712-rpi-5-b.dtb
        │           └── cmdline.txt → root=/dev/nvme0n1p2
        │                 └── Kernel mounts nvme0n1p2 (rpi5-base-image, 116GB)
        │                       └── resize-rootfs runs once on first boot
        └── SD fallback (0x1) ← if NVMe boot fails
              └── mmcblk0p1 boot partition
                    └── cmdline.txt → root=/dev/mmcblk0p2 (core-image-minimal)
```

---

## 7. EEPROM Boot Order

The rpi-eeprom repo contains firmware binaries and tools. To update the EEPROM:

```bash
cd ~/repos/yocto-rpi5/rpi-eeprom

# Use firmware-2712/stable/pieeprom-2026-05-26.bin — NOT 2026-06-17.
# The 2026-06-17 firmware has a regression that prevents NVMe boot via the
# Argon ONE V3 PCIe adapter. The 2026-05-26 (default) version works correctly.

printf '[all]\nBOOT_UART=1\nBOOT_ORDER=0xf16\nNET_INSTALL_AT_POWER_ON=1\n' \
    > /tmp/bootconf.txt

python3 rpi-eeprom-config \
    --config /tmp/bootconf.txt \
    --out /tmp/pieeprom.upd \
    firmware-2712/stable/pieeprom-2026-05-26.bin

python3 rpi-eeprom-config /tmp/pieeprom.upd   # verify before applying

bash rpi-eeprom-digest -i /tmp/pieeprom.upd -o /tmp/pieeprom.sig

scp /tmp/pieeprom.upd /tmp/pieeprom.sig root@169.254.100.1:/boot/

ssh root@169.254.100.1 'sync && reboot'
```

The bootloader finds `pieeprom.upd` on the SD boot partition, applies the update, and reboots.

**BOOT_ORDER values (read right to left):** `0x1` = SD, `0x6` = NVMe, `0xf` = restart loop.

**Important:** After an EEPROM update, the Pi reboots into NVMe-first mode. If the SD card is still inserted, the post-update reboot may fail to boot NVMe (the SD confuses the firmware during this transition). Remove the SD card before or immediately after the reboot that applies the EEPROM update. Reinsert it once NVMe is booted — it sits unmounted as a silent fallback.

---

## 8. NVMe Reflash Procedure

**Always flash from SD, never while NVMe is the running root** — writing to a mounted root corrupts the filesystem.

```bash
# Step 1: Force SD boot by zeroing the NVMe boot sector, then reboot
ssh root@169.254.100.1 'dd if=/dev/zero of=/dev/nvme0n1p1 bs=512 count=1 && reboot'

# Step 2: Wait for SD to come up, then pipe image directly from laptop
ssh-keygen -R 169.254.100.1
bzcat ~/repos/yocto-rpi5/build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | ssh root@169.254.100.1 'dd of=/dev/nvme0n1 bs=4M && sync && reboot'

# Step 3: Remove SD card before/during the NVMe boot (see EEPROM note in §7)
# Step 4: Wait for NVMe to come up — resize-rootfs runs automatically on first boot
ssh-keygen -R 169.254.100.1
ssh root@169.254.100.1
# Reinsert SD card — it will appear as mmcblk0 unmounted, available as fallback
```

**Why pipe instead of scp to /tmp?** Avoids filling the SD root filesystem. The image streams directly from the laptop into dd on the Pi.

**Why zero nvme0n1p1?** Makes the NVMe boot partition unreadable by the EEPROM bootloader, forcing fallback to SD for the next boot only. The full reflash restores a valid boot partition.

**No manual cmdline.txt patch needed.** The `rpi5-base-image` recipe uses `IMAGE_POSTPROCESS_COMMAND` to patch `cmdline.txt` (root device) and `/etc/fstab` (/boot mount) inside the wic image at build time. Yocto's wic tool uses `--ondisk mmcblk0` naming by default; the patch corrects both to `nvme0n1p*` device names.

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
| wic generates `nvme0n11` instead of `nvme0n1p1` | `direct.py` only adds `p` separator for `mmcblk` devices. Fixed via `IMAGE_POSTPROCESS_COMMAND` in `rpi5-base-image.bb` using `debugfs` to patch `/etc/fstab` and `mcopy` to patch `cmdline.txt` inside the wic image. |
| Yocto sstate mirror disabled | Enable after `sudo dnf install python3-websockets` and uncommenting `BB_HASHSERVE_UPSTREAM` in `local.conf` |
| Poky WARNING in MOTD | Remove `/etc/motd` in `rpi5-base-image.bb` if desired |
| `meta-john` layer shows `<unknown>` revision | Not a git repo — `git init` in `meta-john/` to fix |
| WiFi/Bluetooth present but unused | `wpa_supplicant` and `bluetoothd` run but do nothing — leave for future experimentation |
