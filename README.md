# Yocto RPi5 — RAUC A/B OTA on NVMe

Custom embedded Linux image for Raspberry Pi 5 built with Yocto Scarthgap (5.0 LTS).
Headless, SSH-only, booting from NVMe via an Argon ONE V3 PCIe enclosure, with
**RAUC A/B over-the-air updates** driven by the Raspberry Pi firmware's native
`tryboot` mechanism — **no U-Boot**.

> **Why no U-Boot?** U-Boot has no BCM2712 (Pi 5) PCIe driver yet, so it cannot read
> an NVMe drive (`nvme scan`/`fatload nvme` fail). Instead the RPi firmware loads the
> kernel directly and A/B slot selection is done with the firmware's `tryboot` feature.
> See [SETUP.md §11](SETUP.md) for the full rationale.

---

## Hardware

| Component | Details |
|---|---|
| SBC | Raspberry Pi 5, 8 GB RAM |
| Enclosure | Argon ONE V3 PCIe |
| Storage | NVMe (~128 GB) via PCIe FFC connector + microSD (flash/recovery tool) |
| Network | Direct Ethernet to host laptop — no router, no switch |

---

## What This Builds

| Image | Target | Purpose |
|---|---|---|
| `core-image-minimal` | microSD | Recovery / NVMe flashing tool (Dropbear SSH) |
| `rpi5-base-image` | NVMe | Primary RAUC A/B system (OpenSSH) |
| `rpi5-rauc-bundle` | — | Signed `.raucb` OTA update bundle |

Both bootable images come up at `169.254.100.1/16` on `eth0` — static IP, no DHCP.

---

## Boot Architecture (firmware tryboot A/B)

```
Power on
  └── EEPROM (BOOT_ORDER=0xf61 — SD first, NVMe fallback)
        ├── microSD present  → boots core-image-minimal (flash/recovery)
        └── microSD absent    → boots NVMe:
              └── p1 bootsel (FAT) → autoboot.txt
                    ├── [all]     boot_partition=2  (committed slot)
                    └── [tryboot] boot_partition=3  (one-shot try target)
                          │
                          ▼ firmware loads config.txt from the chosen boot partition
                    p2 boot-A / p3 boot-B (FAT)  → kernel_2712.img + dtb + config.txt
                          config.txt: [boot_partition=2] cmdline=cmdline-rootfs-A.txt
                                      [boot_partition=3] cmdline=cmdline-rootfs-B.txt
                          │
                          ▼
                    p4 rootfs-A (root=…p4) / p5 rootfs-B (root=…p5)
```

The EEPROM is **SD-first**, so inserting the microSD always gives a recovery path
and is how the NVMe gets (re)flashed. Remove the SD to boot the NVMe system.

### NVMe partition layout (GPT, 6 partitions)

| Part | Label | FS | Size | Purpose |
|---|---|---|---|---|
| p1 | `bootsel` | vfat | 64 MB | `autoboot.txt` selector — stable, never written by RAUC |
| p2 | `boot-a` | vfat | 256 MB | Slot A boot files (kernel, dtb, config.txt, cmdline-*) |
| p3 | `boot-b` | vfat | 256 MB | Slot B boot files |
| p4 | `rootfs-a` | ext4 | 4 GB | RAUC rootfs slot A |
| p5 | `rootfs-b` | ext4 | 4 GB | RAUC rootfs slot B |
| p6 | `data` | ext4 | rest | Persistent `/data` (auto-expanded on first boot) |

`config.txt` is identical in both boot partitions; the firmware's `[boot_partition=N]`
conditional selects the matching `cmdline-rootfs-{A,B}.txt`, so the same boot image
works in either slot.

---

## Layer Structure

```
yocto-rpi5/
├── build-rpi5/conf/        — local.conf (RPI_USE_U_BOOT="0"), bblayers.conf
├── meta-john/              — custom layer (git submodule)
│   ├── wic/rauc-raspberrypi-tryboot.wks              — GPT A/B layout (nvme0n1)
│   ├── recipes-core/images/rpi5-base-image.bb        — image + tryboot image setup
│   ├── recipes-core/rauc/files/system.conf           — RAUC bootloader=custom + slots
│   ├── recipes-core/rauc-tryboot-backend/            — custom backend (autoboot.txt)
│   ├── recipes-core/rauc-bundle/                     — signed .raucb bundle recipe
│   ├── recipes-core/resize-data/                     — first-boot /data expand (GPT-aware)
│   ├── recipes-core/data-mount/                      — /data mount unit (nvme0n1p6)
│   ├── recipes-connectivity/eth0-networkd-config/    — static IP via systemd-networkd
│   ├── recipes-connectivity/pi-ble-status/           — BLE GATT: diagnostics + WiFi provisioning
│   ├── recipes-connectivity/wlan0-config/            — wlan0 DHCP (RequiredForOnline=no)
│   └── recipes-core/ssh-keys/                        — bakes authorized SSH key into image
├── SETUP.md                — full build, flash, and RAUC OTA procedure
└── boot.log                — annotated dmesg from a clean boot
```

Upstream / external layers (cloned separately — see SETUP.md):
`poky`, `meta-openembedded`, `meta-raspberrypi`, `meta-rauc`, `meta-rauc-community`.

---

## Build (Docker — Ubuntu 22.04)

Scarthgap does not officially support Fedora 44 as a build host, so builds run in a
Docker container. See [SETUP.md §11](SETUP.md) for full layer setup and signing keys.

```bash
# inside the build container, from the build dir:
umask 022
bitbake rpi5-base-image     # rootfs + GPT wic.bz2 (+ ext4 for the bundle)
bitbake rpi5-rauc-bundle    # signed .raucb OTA bundle
```

---

## Initial NVMe flash

The EEPROM is SD-first, so flashing is done from the SD recovery image.

```bash
# 1. Insert microSD (boots core-image-minimal), SSH in
ssh -o StrictHostKeyChecking=no root@169.254.100.1 'cat /sys/block/nvme0n1/size'

# 2. Stream the GPT image straight onto the NVMe (BusyBox dd — no status=progress)
bzcat build-rpi5/tmp/deploy/images/raspberrypi5/rpi5-base-image-raspberrypi5.rootfs.wic.bz2 \
    | ssh -o StrictHostKeyChecking=no root@169.254.100.1 'dd of=/dev/nvme0n1 bs=4M && sync'

# 3. Power off, REMOVE the SD card, power on → firmware boots the NVMe (slot A)
```

On first boot `resize-data` relocates the GPT backup header and expands `/data` (p6)
to fill the drive.

---

## RAUC A/B OTA update

```bash
# On the laptop: copy the bundle to the Pi (use /data — large, persistent)
scp rpi5-rauc-bundle-raspberrypi5.raucb root@169.254.100.1:/data/update.raucb

# On the Pi: install to the INACTIVE slot, activate it, reboot
rauc install /data/update.raucb        # writes the new rootfs to the other slot
rauc status mark-active other          # flips autoboot.txt [all] to that slot
reboot                                 # boots the updated slot
```

After reboot, `rauc status` shows `Booted from`/`Activated` on the new slot, and
`cat /etc/build-version` shows the new build. **Rollback** is `rauc status
mark-active other` + `reboot` back to the previous slot.

> **Note:** `rauc install` does not auto-activate in this setup — the explicit
> `rauc status mark-active other` step calls the custom backend that rewrites
> `autoboot.txt`. Automatic rollback-on-failure (firmware one-shot `tryboot`) needs
> `raspberrypi-utils`/`vcmailbox` and is not yet wired in (see SETUP.md §11).

---

## SSH Access

```bash
ssh root@169.254.100.1   # ED25519 key, no password
```

Connect the laptop's Ethernet port directly to the Pi — both sides use
`169.254.0.0/16` link-local addressing, no router required.

---

## Key Design Decisions

**No U-Boot — firmware tryboot** — U-Boot lacks a Pi 5 (BCM2712) PCIe driver, so it
cannot boot NVMe. The RPi firmware loads the kernel directly; A/B is done via
`autoboot.txt` (`[all]`/`[tryboot]` → `boot_partition`).

**RAUC `bootloader=custom`** — a small backend (`tryboot-backend.sh`) implements
`get/set-primary` and `get/set-state` by editing `autoboot.txt` on the selector
partition (p1).

**Per-slot boot + rootfs, shared `config.txt`** — `[boot_partition=N]` selects the
matching `cmdline-rootfs-{A,B}.txt`, so one boot image works in either slot.

**SD-first EEPROM (`0xf61`)** — inserting the microSD always wins, giving a reliable
flash/recovery path; the NVMe boots only when the SD is absent.

**systemd-networkd over NetworkManager** — NM built from sstate before `systemd` was a
`DISTRO_FEATURE` silently fails; networkd with a `.network` file is reliable.

**First-boot `/data` resize** — wic images are fixed size; `resize-data` relocates the
GPT backup header (needed after `dd` onto a larger disk) then grows `/data` to fill.

**WiFi provisioning over BLE — credential-free image** — WiFi credentials are **never** baked
into the image or stored in the repo. The `pi-ble-status` BLE GATT server (service `00001000-…`)
provisions WiFi at runtime: write `SSID`/`password` to characteristic `…1006`, and the Pi writes
`wpa_supplicant-wlan0.conf` and brings up `wlan0`. The loop is self-contained over BLE — you don't
need to know the DHCP address in advance:

| Characteristic | Access | Value |
|---|---|---|
| `…1006` | write / read | write `SSID`/`password` to provision; read provisioning status |
| `…1001` | read | `wlan0` IP (the DHCP-assigned WiFi address — read it back here after provisioning) |
| `…1002` | read | `eth0` IP |
| `…1003` / `…1004` / `…1005` | read | CPU temperature / uptime / hostname |

Because the credentials live only in the running slot's rootfs, they do **not** survive a reflash or
a RAUC A/B OTA — re-provision over BLE on the new slot (this is by design, not a gap). Useful when
SSH is unreachable or the WiFi IP has changed.

---

## See Also

- [SETUP.md](SETUP.md) — full build, flash, RAUC OTA, and gotchas
- [meta-john](https://github.com/John-H-Aal/meta-john) — custom Yocto layer
- [boot.log](boot.log) — annotated dmesg from a clean boot
