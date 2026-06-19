# Yocto RPi5 Project

## Goal
Build a custom embedded Linux image for Raspberry Pi 5 with NVMe boot support using Yocto Scarthgap (5.0 LTS).

## Host
- Fedora 44, x86_64, 62GB RAM, AMD Ryzen AI 9 HX PRO 370
- Project root: ~/repos/yocto-rpi5

## Target
- Raspberry Pi 5, 8GB RAM
- Boot: microSD (initial), final target NVMe (M.2 NVMe via Argon ONE V3 PCIe)
- Headless, SSH access via Ethernet only

## Architecture

### Layers
- poky (Scarthgap 5.0)
- meta-openembedded (meta-oe, meta-python, meta-networking)
- meta-raspberrypi
- meta-john (custom layer)

### Key variables (local.conf)
- MACHINE = "raspberrypi5"
- DISTRO = "poky"
- IMAGE_FSTYPES = "wic.bz2 wic.bmap"

## Images
1. `core-image-minimal` — first boot from SD, used to flash NVMe
2. `rpi5-base-image` — custom image in meta-john, target for NVMe

## Must-have packages in image
- openssh-server
- networkmanager or systemd-networkd
- e2fsprogs (for NVMe partitioning/flashing)
- bmaptool (for efficient flashing)

## Workflow
1. Build wic image on Fedora laptop
2. Flash to SD card
3. Boot Pi 5 from SD, SSH in via Ethernet (DHCP from laptop dnsmasq)
4. Flash NVMe image to /dev/nvme0n1
5. Remove SD, reboot from NVMe

## Learning objectives
- Understand Yocto layer model
- Write custom recipes (.bb files)
- Configure MACHINE and DISTRO
- Generate SDK for cross-compilation
- BSP customization for Pi 5
