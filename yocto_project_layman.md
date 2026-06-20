# Yocto RPi5 Project — Explained for a General Audience

## What is this project?

This project builds a custom operating system for a Raspberry Pi 5 — a small, credit-card-sized computer — and makes it boot from a fast internal SSD (NVMe) instead of the usual slow SD card.

The end result is a headless Linux server: no screen, no keyboard, controlled entirely over the network via SSH (a secure terminal connection).

## The hardware

| Component | What it is |
|---|---|
| **Raspberry Pi 5 (8 GB)** | The small computer being set up. About the size of a deck of cards. |
| **Argon ONE V3 case** | A metal case for the Pi that adds an M.2 NVMe slot — a slot for a fast SSD. |
| **NVMe SSD** | The solid-state drive the Pi boots from. Much faster than an SD card. |
| **microSD card** | A recovery fallback — stays inserted in the Pi as a silent spare. |
| **Fedora laptop (x86_64)** | John's laptop, used to build the operating system image. |
| **Ethernet cable** | How the laptop and Pi talk to each other — no router, direct cable. |

## What is Yocto?

Yocto is a kind of **factory** for building custom Linux operating systems. Instead of taking an existing OS (like Raspberry Pi OS) and modifying it, Yocto builds the entire OS from scratch — just the pieces you actually need, nothing more.

Think of it like the difference between buying a pre-made meal (Raspberry Pi OS) and assembling your own ingredients (Yocto). More work up front, but you know exactly what's in it and it's tailored to your needs.

The factory runs on John's laptop and can take several hours to produce the final result: an image file that can be written onto a storage device.

## What software is in the image?

The custom OS is intentionally minimal. It contains:

- A Linux kernel (the core of the operating system)
- An SSH server (so you can log in remotely)
- A networking stack that gives the Pi a fixed IP address on boot
- Tools for managing storage (formatting, partitioning, copying)
- A script that automatically expands the filesystem to fill the drive on first boot
- A Bluetooth Low Energy (BLE) service that broadcasts the Pi's IP address, temperature, and uptime — useful for diagnostics when the network isn't yet up

There is no desktop, no browser, no GUI of any kind. It does exactly one job: run as a small networked server.

## How the setup works, step by step

```
Laptop (Fedora)
   │
   │  Build the OS image (takes hours)
   ▼
Image file (.wic.bz2)
   │
   │  Flash to SD card (minutes)
   ▼
SD card
   │
   │  Insert into Pi, boot
   ▼
Pi running from SD
   │
   │  SSH in from laptop over Ethernet
   │  Flash NVMe image to the internal SSD
   ▼
NVMe SSD has the OS
   │
   │  Reboot — Pi comes up from NVMe automatically
   ▼
Pi running from NVMe (permanent state)
SD card stays inserted as a silent recovery fallback
```

The SD card is used as a temporary tool to get the OS onto the faster NVMe drive, and then remains in the Pi as a recovery option in case the NVMe ever fails to boot.

## How the laptop and Pi communicate

The laptop and Pi are connected directly by an Ethernet cable — no router involved. The Pi has a fixed IP address (`169.254.100.1`) and the laptop knows to look for it there. This is called a link-local connection.

Logging in looks like this:

```
ssh root@169.254.100.1
```

No password is required — access is controlled by a cryptographic key instead, which is more secure.

## Why go through all this trouble?

1. **Speed** — NVMe is dramatically faster than an SD card for an OS drive.
2. **Reliability** — SD cards wear out quickly under constant read/write activity. NVMe drives do not.
3. **Learning** — The project is also a hands-on way to learn how embedded Linux systems are built from scratch.
4. **Control** — Every package in the OS is explicitly chosen. There is no bloat, no mystery software running in the background.
