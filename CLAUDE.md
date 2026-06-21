# Yocto RPi5 Project

## Goal
Build a custom embedded Linux image for Raspberry Pi 5 with NVMe boot using Yocto Scarthgap (5.0 LTS),
plus RAUC A/B over-the-air updates with rollback. There is no U-Boot: U-Boot has no BCM2712 (Pi 5)
PCIe driver, so A/B slot selection runs on the Raspberry Pi firmware's native `tryboot` mechanism.

## Host
- Fedora 44, x86_64, 62GB RAM, AMD Ryzen AI 9 HX PRO 370
- Project root: ~/repos/yocto-rpi5

## Target
- Raspberry Pi 5, 8GB RAM
- Boot: NVMe (M.2 via Argon ONE V3 PCIe), RAUC A/B slots. EEPROM is SD-first
  (`BOOT_ORDER=0xf61`): insert the microSD for recovery/reflash, remove it to run the NVMe system
- Headless, SSH access via Ethernet only

## Architecture

### Layers
- poky (Scarthgap 5.0)
- meta-openembedded (meta-oe, meta-python, meta-networking)
- meta-raspberrypi
- meta-rauc, meta-rauc-community (meta-rauc-raspberrypi) — RAUC integration
- meta-john (custom layer)

### Key variables (local.conf)
- MACHINE = "raspberrypi5"
- DISTRO = "poky"
- IMAGE_FSTYPES = "wic.bz2 wic.bmap" (+ ext4, required by the RAUC bundle)
- RPI_USE_U_BOOT = "0" (firmware tryboot, no U-Boot)

## Images
1. `core-image-minimal` — SD recovery image, used to flash the NVMe
2. `rpi5-base-image` — custom RAUC A/B image in meta-john, target for NVMe
3. `rpi5-rauc-bundle` — signed `.raucb` OTA update bundle (rootfs slot)

## Must-have packages in image
- openssh-server
- networkmanager or systemd-networkd
- e2fsprogs (for NVMe partitioning/flashing)
- bmaptool (for efficient flashing)

## Workflow
1. Build `rpi5-base-image` (wic + ext4) and `rpi5-rauc-bundle` in the Docker build container
2. Flash `core-image-minimal` to the SD card (recovery image)
3. Boot Pi 5 from SD, SSH in via direct Ethernet (static link-local `169.254.100.1`)
4. Flash the `rpi5-base-image` wic to `/dev/nvme0n1`
5. Remove SD, reboot from NVMe (slot A)
6. Field updates via RAUC: `rauc install bundle.raucb` → `rauc status mark-active other` → reboot

## Learning objectives
- Understand Yocto layer model
- Write custom recipes (.bb files)
- Configure MACHINE and DISTRO
- Generate SDK for cross-compilation
- BSP customization for Pi 5
