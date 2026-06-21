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

---

## 3. Custom Layer: meta-john

```
meta-john/
├── conf/
│   └── layer.conf
├── wic/
│   └── nvme-raspberrypi.wks                    — wic layout targeting nvme0n1
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
│   │   └── rpi5-base-image.bb                  — NVMe target image
│   ├── ssh-keys/
│   │   ├── ssh-keys_1.0.bb                     — bakes authorized_keys into image
│   │   └── files/
│   │       └── authorized_keys
│   ├── init-ifupdown/
│   │   ├── init-ifupdown_%.bbappend            — static IP for core-image-minimal
│   │   └── files/
│   │       └── interfaces
│   ├── packagegroups/
│   │   └── packagegroup-base.bbappend          — removes ofono/neard from base
│   └── resize-rootfs/
│       ├── resize-rootfs_1.0.bb                — first-boot partition resize
│       └── files/
│           └── resize-rootfs                   — init script
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
| `resize-rootfs` | Auto-expand root partition on first boot |
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

The `rpi-eeprom/` directory contains pre-built firmware binaries and update tooling.

**BOOT_ORDER values (read right to left):** `0x6` = NVMe, `0x1` = SD, `0xf` = restart loop.  
`0xf16` = NVMe first → SD fallback → restart.

Pre-built binaries:
- `rpi-eeprom/pieeprom-nvme-first.bin` / `.sig` — `BOOT_ORDER=0xf16` ← use this
- `rpi-eeprom/pieeprom-sd-first.bin` / `.sig` — SD first

**RPi5 (BCM2712) requires `recovery.bin` — without it the bootloader silently ignores `pieeprom.upd`.**

To apply from a running Pi (SD or NVMe boot, SD card must be inserted):

```bash
# On the Pi:
mount /dev/mmcblk0p1 /mnt
cp /tmp/pieeprom-nvme-first.bin /mnt/pieeprom.upd
cp /tmp/pieeprom-nvme-first.sig /mnt/pieeprom.sig
cp /tmp/recovery.bin /mnt/recovery.bin
sync && umount /mnt && reboot
```

Or pipe all three from the laptop first:

```bash
scp rpi-eeprom/pieeprom-nvme-first.bin \
    rpi-eeprom/pieeprom-nvme-first.sig \
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
# Step 1: Zero nvme0n1p1 boot sector — forces SD fallback on next boot
# (BOOT_ORDER=0xf16 tries NVMe first; wiping the boot sector makes it fall through to SD)
ssh root@169.254.100.1 'dd if=/dev/zero of=/dev/nvme0n1p1 bs=512 count=1 && reboot'

# Step 2: Wait for SD boot — uses Dropbear (RSA host key), NOT your ED25519 key
ssh-keygen -R 169.254.100.1
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@169.254.100.1 'echo up'; do sleep 5; done

# Confirm SD boot
ssh -o StrictHostKeyChecking=no root@169.254.100.1 'cat /proc/cmdline | grep -o "root=[^ ]*"'
# expect: root=/dev/mmcblk0p2

# Step 3: Pipe NVMe image directly from laptop to Pi
bzcat ~/repos/yocto-rpi5/build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | ssh -o StrictHostKeyChecking=no root@169.254.100.1 'dd of=/dev/nvme0n1 bs=4M && sync'

# Step 4: Reboot — separate command ('reboot' inside the pipe returns Access denied on SD image)
ssh -o StrictHostKeyChecking=no root@169.254.100.1 reboot

# Step 5: Pi reboots from NVMe — SD stays in as silent fallback
# resize-rootfs runs on first NVMe boot
ssh-keygen -R 169.254.100.1 && ssh root@169.254.100.1
# ED25519 key accepted, no password
```

**Why pipe instead of scp to /tmp?** Avoids filling the SD root filesystem. The image streams directly from the laptop into dd on the Pi.

**SD card SSH note:** The SD image (core-image-minimal) uses Dropbear and presents an RSA host key. Your ED25519 key is not in the SD image. Always use `-o StrictHostKeyChecking=no` for SD SSH sessions.

**No manual cmdline.txt patch needed.** The `rpi5-base-image` recipe uses `IMAGE_POSTPROCESS_COMMAND` to patch `cmdline.txt` and `/etc/fstab` inside the wic image at build time:
- `root=/dev/mmcblk0p2` → `root=/dev/nvme0n1p2`
- `reboot=cold` appended (overrides the firmware-injected `reboot=w`, ensuring a full PCIe reset on every reboot)
- `/dev/nvme0n11` → `/dev/nvme0n1p1` in fstab (wic's `direct.py` lacks the `p` separator for nvme devices)

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
| Changing `DISTRO_FEATURES` requires full cleansstate | Run `bitbake -c cleansstate rpi5-base-image && bitbake rpi5-base-image` — sstate serves stale packages built without systemd support, causing silent failures (e.g. NM not configuring eth0) |
| BLE available on Pi | `pi-ble-status` broadcasts IP (wlan0/eth0), CPU temp, uptime, hostname — useful diagnostic when SSH is unreachable. Pi BT MAC: D8:3A:DD:E6:3E:9C |

---

## 11. RAUC A/B OTA — feature/rauc-uboot branch

> **Branch:** `feature/rauc-uboot`  
> **Reference:** [Qbee RAUC tutorial for RPi5](https://docs.qbee.io/tutorial-rpi5-rauc.html) (Qbee-agent steps omitted)  
> **Build environment:** Docker (Ubuntu 22.04) is the primary path — Fedora 44 is unsupported by Scarthgap.

### 11.1 Layer setup (clone on host before Docker)

Clone all external layers into `~/repos/yocto-rpi5/`. The moto-timo forks and `meta-lts-mixins` replace the upstream `meta-raspberrypi` and provide U-Boot support for RPi5 on Scarthgap.

```bash
cd ~/repos/yocto-rpi5

# meta-lts-mixins — U-Boot version override; MUST come before meta-raspberrypi
# in bblayers.conf or the build fails with a recipe version conflict.
git clone --branch scarthgap/u-boot \
    https://github.com/moto-timo/meta-lts-mixins.git

# moto-timo fork of meta-raspberrypi — adds RPi5 U-Boot support (branch: scarthgap)
# NOTE: the branch was named scarthgap/raspberrypi5_u-boot in the Qbee tutorial
#       but has since been merged/renamed to scarthgap.
mv meta-raspberrypi meta-raspberrypi-upstream-bkp
git clone --branch scarthgap \
    https://github.com/moto-timo/meta-raspberrypi.git

# Official RAUC layer (Scarthgap branch)
git clone --branch scarthgap \
    https://github.com/rauc/meta-rauc.git

# moto-timo fork of meta-rauc-community — adds RPi5 RAUC+U-Boot integration
git clone --branch scarthgap/raspberrypi5_u-boot \
    https://github.com/moto-timo/meta-rauc-community.git
```

> **TODO / fork stability note:** The moto-timo branches (`scarthgap/raspberrypi5_u-boot`, `scarthgap/u-boot`) are development forks, not official releases. Pin to a specific commit SHA for reproducible builds.

### 11.2 Docker quickstart

```bash
cd ~/repos/yocto-rpi5

# Step 1 — Switch bblayers.conf to Docker paths (restore with git checkout afterwards)
cp build-rpi5/conf/bblayers-docker.conf.example build-rpi5/conf/bblayers.conf

# Step 2 — Enter the build container (sources oe-init-build-env automatically)
docker compose run yocto-builder

# Inside the container:
umask 022
bitbake rpi5-base-image      # builds rootfs + wic + ext4
bitbake rpi5-rauc-bundle     # assembles signed .raucb update bundle
```

Built artifacts land in `build-rpi5/tmp/deploy/images/raspberrypi5/`.  
Copy the bundle to `./output/` for serving:

```bash
cp build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-rauc-bundle.raucb output/
```

> **sstate note:** The existing native `sstate-cache/` is NOT reusable inside Docker (different host toolchains = different hashes). Expect a full rebuild on first Docker run. Subsequent Docker runs reuse the `yocto-sstate` named volume.

> **Native Fedora 44 build (unsupported):** Scarthgap does not officially support Fedora 44 as a host. The original native build instructions in sections 1–9 still apply for the non-RAUC main branch, but for the `feature/rauc-uboot` branch use Docker.

### 11.3 RAUC signing keys (generate once)

```bash
cd ~/repos/yocto-rpi5

# create-example-keys.sh is in the meta-rauc-community repo
# It generates a self-signed CA and a development signing keypair.
bash meta-rauc-community/scripts/create-example-keys.sh

# Copy output to meta-john/files/rauc-keys/ (gitignored — never commit .pem files)
cp *.pem meta-john/files/rauc-keys/
# Expected files:
#   ca.cert.pem           — installed to /etc/rauc/ca.cert.pem on the Pi
#   development-1.cert.pem — used by rauc-bundle.bb for bundle signing
#   development-1.key.pem  — private key, keep off the Pi
ls meta-john/files/rauc-keys/
```

Keys must exist before running `bitbake rpi5-rauc-bundle`.

### 11.4 Partition layout

| Partition | Device | Size | Label | Purpose |
|---|---|---|---|---|
| p1 | `/dev/mmcblk0p1` | 256 MB | `boot` | U-Boot + kernel + dtb |
| p2 | `/dev/mmcblk0p2` | 4 GB fixed | `rootfs-a` | RAUC slot A (active after flash) |
| p3 | `/dev/mmcblk0p3` | 4 GB fixed | `rootfs-b` | RAUC slot B (cloned from A; OTA target) |
| p4 | `/dev/mmcblk0p4` | remainder | `data` | Persistent `/data`, survives OTA |

WKS file: `meta-john/wic/rauc-raspberrypi.wks`  
Alternative: `sdimage-dual-raspberrypi.wks.in` from `meta-rauc-community/meta-rauc-raspberrypi/` (no `/data` partition).

### 11.5 Initial SD flash and slot clone

```bash
# Flash the full wic image to SD (replaces entire card including partition table)
sudo umount -l /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4 2>/dev/null
sudo systemctl stop udisks2
bzcat build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | sudo dd of=/dev/sda bs=4M status=progress
sudo systemctl start udisks2
sudo eject /dev/sda

# Boot the Pi from SD, SSH in
ssh root@169.254.100.1

# Clone slot A → slot B (so B is also bootable from the start)
dd if=/dev/mmcblk0p2 of=/dev/mmcblk0p3 bs=4M status=progress && sync
# Format /data partition (only needed on first flash)
mkfs.ext4 -L data /dev/mmcblk0p4
reboot
```

After reboot, `rauc status` should show slot A as `good` and slot B as `good`.

### 11.6 OTA test procedure

```bash
# On Fedora laptop — serve output/ directory (plain HTTP is safe: bundles are signed)
python3 -m http.server 8080 --directory output/

# On the Pi — download and install the bundle
curl http://<laptop-eth0-ip>:8080/rpi5-rauc-bundle.raucb -o /tmp/update.raucb
rauc install /tmp/update.raucb
reboot

# After reboot — verify slot switched and mark is applied
rauc status
# Expect: booted slot = B, status = good
```

### 11.7 Rollback test

```bash
# On the Pi — corrupt slot B boot metadata to force rollback
dd if=/dev/zero of=/dev/mmcblk0p2 bs=512 count=1   # zero slot A's superblock
# (U-Boot will exhaust BOOT_A_LEFT=3 attempts on A, then fall back to B)
reboot

# After reboot — confirm we're on slot B
cat /proc/cmdline | grep -o "root=[^ ]*"   # expect root=/dev/mmcblk0p3
rauc status
```

### 11.8 U-Boot environment variables

| Variable | Default | Meaning |
|---|---|---|
| `BOOT_ORDER` | `A B` | Try slot A first, then B |
| `BOOT_A_LEFT` | `3` | Remaining boot attempts for slot A |
| `BOOT_B_LEFT` | `3` | Remaining boot attempts for slot B |

RAUC updates these via `fw_setenv` (from `u-boot-fw-utils`) using `/etc/fw_env.config` which points to the raw U-Boot environment partition offset.

> **TODO:** Verify `/etc/fw_env.config` offsets against the moto-timo U-Boot defconfig (`CONFIG_ENV_OFFSET`). If the fork uses `CONFIG_ENV_IS_IN_FAT`, update `fw_env.config` to use the FAT-file form instead of raw offsets. See `meta-john/recipes-core/rauc/files/fw_env.config`.

> **TODO:** Verify `boot.cmd.in` kernel image name and load addresses against the moto-timo fork output. The fork may already provide a `boot.scr`; if so, remove or adjust `meta-john/recipes-bsp/u-boot/u-boot_%.bbappend` to avoid conflicts.
