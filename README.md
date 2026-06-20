# Yocto RPi5 — NVMe Boot

Custom embedded Linux image for Raspberry Pi 5 built with Yocto Scarthgap (5.0 LTS).
Headless, SSH-only, booting from NVMe via Argon ONE V3 PCIe enclosure.

---

## Hardware

| Component | Details |
|---|---|
| SBC | Raspberry Pi 5, 8 GB RAM |
| Enclosure | Argon ONE V3 PCIe |
| Storage | NVMe via PCIe FFC connector (primary) + microSD (silent fallback) |
| Network | Direct Ethernet to host laptop — no router, no switch |

---

## What This Builds

| Image | Target | SSH server | Purpose |
|---|---|---|---|
| `core-image-minimal` | microSD | Dropbear | Recovery fallback, NVMe flash tool |
| `rpi5-base-image` | NVMe | OpenSSH | Primary running system |

Both images come up at `169.254.100.1/16` on `eth0` — static IP, no DHCP required.

---

## Boot Architecture

```
Power on
  └── EEPROM (BOOT_ORDER=0xf16 — NVMe first, SD fallback)
        ├── nvme0n1p1 (FAT32) ← normal path
        │     ├── Linux 6.6.63 + bcm2712-rpi-5-b.dtb
        │     └── root=/dev/nvme0n1p2 (116 GB, auto-resized on first boot)
        └── mmcblk0p1 (FAT32) ← fallback if NVMe fails
              └── root=/dev/mmcblk0p2 (core-image-minimal)
```

SD card stays inserted permanently — it does not interfere with NVMe boot.

---

## Layer Structure

```
yocto-rpi5/
├── build-rpi5/conf/        — local.conf, bblayers.conf
├── meta-john/              — custom layer (git submodule)
│   ├── wic/nvme-raspberrypi.wks                   — wic layout targeting nvme0n1
│   ├── recipes-core/images/rpi5-base-image.bb
│   ├── recipes-connectivity/eth0-networkd-config/ — static IP via systemd-networkd
│   ├── recipes-connectivity/pi-ble-status/        — BLE GATT server: diagnostics + WiFi provisioning
│   ├── recipes-connectivity/wlan0-config/         — DHCP for wlan0 via systemd-networkd + wpa-supplicant
│   ├── recipes-core/ssh-keys/                     — bakes authorized SSH key into image
│   ├── recipes-core/init-ifupdown/                — static IP for minimal image
│   ├── recipes-core/packagegroups/                — removes ofono, neard
│   └── recipes-core/resize-rootfs/                — auto-expands root on first boot
├── SETUP.md                — full build and reflash procedure
└── boot.log                — dmesg from first clean NVMe boot
```

Upstream layers (not included — clone separately):

```bash
git clone --branch scarthgap https://git.yoctoproject.org/poky
git clone --branch scarthgap https://github.com/openembedded/meta-openembedded
git clone --branch scarthgap https://git.yoctoproject.org/meta-raspberrypi
```

---

## Quick Start

### 1. Clone

```bash
git clone --recurse-submodules https://github.com/John-H-Aal/yocto-rpi5
cd yocto-rpi5
```

### 2. Clone upstream layers

```bash
git clone --branch scarthgap https://git.yoctoproject.org/poky
git clone --branch scarthgap https://github.com/openembedded/meta-openembedded
git clone --branch scarthgap https://git.yoctoproject.org/meta-raspberrypi
```

### 3. Install host dependencies (Fedora)

```bash
sudo dnf install -y diffstat chrpath lz4 rpcgen SDL2-devel bmap-tools
```

### 4. Build

```bash
umask 022
source poky/oe-init-build-env build-rpi5
bitbake core-image-minimal     # SD recovery image
bitbake rpi5-base-image        # NVMe target image
```

### 5. Flash SD card

```bash
sudo umount -l /dev/sdX1 /dev/sdX2 2>/dev/null
bzcat build-rpi5/tmp/deploy/images/raspberrypi5/core-image-minimal-raspberrypi5.rootfs.wic.bz2 \
    | sudo dd of=/dev/sdX bs=4M
sudo eject /dev/sdX
```

### 6. Flash NVMe (from SD, via SSH)

```bash
# BOOT_ORDER=0xf16 boots NVMe first — zero the boot sector to force SD fallback
ssh root@169.254.100.1 'dd if=/dev/zero of=/dev/nvme0n1p1 bs=512 count=1 && reboot'

# Wait for SD to boot (uses Dropbear — StrictHostKeyChecking=no required)
ssh-keygen -R 169.254.100.1
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@169.254.100.1 'echo up'; do sleep 5; done

# Confirm SD boot
ssh -o StrictHostKeyChecking=no root@169.254.100.1 'cat /proc/cmdline | grep -o "root=[^ ]*"'
# expect: root=/dev/mmcblk0p2

# Pipe NVMe image directly from laptop
bzcat build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | ssh -o StrictHostKeyChecking=no root@169.254.100.1 'dd of=/dev/nvme0n1 bs=4M && sync'

# Reboot as a separate command ('reboot' inside the pipe returns Access denied on SD image)
ssh -o StrictHostKeyChecking=no root@169.254.100.1 reboot

# Pi reboots from NVMe automatically (SD stays in as silent fallback)
ssh-keygen -R 169.254.100.1 && ssh root@169.254.100.1
```

Root partition auto-expands to fill the NVMe on first boot.

---

## SSH Access

```bash
ssh root@169.254.100.1   # ED25519 key, no password
```

Connect your laptop's Ethernet port directly to the Pi. No router needed — both sides use `169.254.0.0/16` link-local addressing.

---

## Key Design Decisions

**Static IP over DHCP** — link-local static IP (`169.254.100.1/16`) needs no infrastructure and is consistent across reboots.

**systemd-networkd over NetworkManager** — NM built from sstate cache (before `DISTRO_FEATURES` included `systemd`) silently fails to configure interfaces. systemd-networkd with a `.network` file is simpler and reliable.

**SSH key baked into image** — `debug-tweaks` + OpenSSH `PermitEmptyPasswords` is unreliable. The `ssh-keys` recipe installs `authorized_keys` at build time.

**NVMe-first EEPROM** — boot order `0xf16` (NVMe → SD → restart). SD card stays inserted as silent recovery fallback — no need to remove it between normal reboots.

**Always flash from SD** — never write to NVMe while it is the running root. Insert SD (boots automatically as SD-first fallback) then pipe the image from the laptop.

**First-boot resize** — Yocto wic images create a fixed-size root partition. `resize-rootfs` expands it to fill the disk on first boot, runs once, then never again.

**BLE diagnostic + WiFi provisioning** — `pi-ble-status` advertises IP, temperature, uptime, and hostname over BLE (chars `1001`–`1005`). Char `1006` is writable: send `SSID/password` to provision wlan0 at runtime without reflashing. Useful when SSH is unreachable or WiFi credentials need updating.

---

## See Also

- [meta-john](https://github.com/John-H-Aal/meta-john) — custom Yocto layer
- [SETUP.md](SETUP.md) — full build log, gotchas, and reflash procedure
- [boot.log](boot.log) — annotated dmesg from first clean NVMe boot
