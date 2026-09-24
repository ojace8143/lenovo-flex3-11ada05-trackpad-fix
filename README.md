# Lenovo IdeaPad Flex 3 11ADA05 — Fix the dead Linux touchpad

The **touchpad (ELAN `04F3:3072`)** on the IdeaPad Flex 3 11ADA05 disappears
completely under Linux on BIOS versions **FPCN24WW and newer**. No input
device, no `libinput list-devices` entry, nothing. The touchscreen still works.

The "standard" fix that circulates in forums is a **BIOS downgrade to
FPCN21WW** — which requires Windows to flash, and, on low-RAM machines, a
Windows PE that fits in memory. **This repo fixes it without touching the
BIOS at all.**

## What it does

The BIOS firmware (≥ FPCN24WW) gatekeeps the touchpad's ACPI resources behind
an embedded-controller query that Linux evaluates too early, so the device
never gets its I²C resource and the kernel never creates an input device. See
[`docs/diagnosis.md`](docs/diagnosis.md).

This repo builds a **patched DSDT** and injects it into the kernel at boot via
the standard ACPI table override mechanism (`kernel/firmware/acpi/dsdt.aml` in
the initramfs / unified kernel image). No BIOS update, no Windows, no risk of
a bricked firmware — and it survives kernel updates.

- `TPD0._CRS` returns the I2C address `0x15` + `GpioInt` unconditionally.
- `TPD0._DSM` function 1 returns `0x01` unconditionally.
- DSDT OEM revision is bumped so the kernel accepts the override.

## Tested on

| Thing | Value |
|---|---|
| Machine | Lenovo IdeaPad Flex 3 11ADA05 (`82G4`) |
| BIOS | `FPCN26WW` (05/2022) — fixed, **no downgrade needed** |
| Distro | Omarchy (Arch-based, Hyprland, limine UKI) — installer for **Linux Mint / Ubuntu / Debian** included |
| Kernel | `7.2.5-3-omarchy` (works on Ubuntu-family kernels too) |
| Secure Boot | OFF (required — see below) |

The mechanism is a **kernel ACPI table override**, so it is not distro-specific —
only the initramfs plumbing differs. Installers provided for:

- **Omarchy / Arch** (mkinitcpio `acpi_override` hook, limine UKI) — `install-omarchy.sh`
- **Linux Mint / Ubuntu / Debian** (initramfs-tools hook) — `install-ubuntu.sh`

## Prerequisites

- Root access (`sudo` or `pkexec`, depending on your setup).
- `acpica` package (`iasl`, `acpidump`).
  - Omarchy/Arch: `sudo pacman -S acpica`
  - Linux Mint/Ubuntu/Debian: `sudo apt install acpica-tools`
- **Secure Boot must be OFF.** The kernel refuses ACPI table overrides when
  Secure Boot or lockdown is active. Check with:

  ```sh
  mokutil --sb-state          # must NOT say "Secure Boot is enabled"
  cat /sys/kernel/security/lockdown   # active entry must be [none]
  ```

## Usage

### 1. Build the patched DSDT (from your own machine's tables)

```sh
sudo ./scripts/build-dsdt.sh
# or: pkexec ./scripts/build-dsdt.sh
```

Produces `build/dsdt.aml` and a ready-made `build/acpi_override` cpio.
Building from your *own* tables means it works on any BIOS ≥ FPCN24WW.

### 2. Install into the initramfs

**On Omarchy / limine / UKI (one binary, no GRUB):**

```sh
sudo ./scripts/install-omarchy.sh
```

This drops the table at `/etc/initcpio/acpi_override/dsdt.aml`, enables
mkinitcpio's `acpi_override` hook via a drop-in config
(`/etc/mkinitcpio.conf.d/omarchy_zz_acpi_override.conf`), and rebuilds the UKI
with `limine-mkinitcpio`.

**On Linux Mint / Ubuntu / Debian:**

```sh
sudo ./scripts/install-ubuntu.sh
```

Stages the table at `/etc/acpi_override/dsdt.aml`, pre-builds a tiny
uncompressed "early" initramfs archive (`/etc/acpi_override/acpi_override.cpio`)
containing `kernel/firmware/acpi/dsdt.aml`, and installs a small
`initramfs-tools` hook (`/etc/initramfs-tools/hooks/acpi_override`) that
prepends that archive on every initramfs build via
`prepend_earlyinitramfs`. It then runs `update-initramfs -u -k all`.

The kernel digs ACPI overrides out of the **raw initrd bytes before any
decompression** (see `docs/diagnosis.md`), so staging the table into the
leading uncompressed section is required — dropping it into the compressed
main archive would be silently ignored. This script does exactly that, so the
stock gzip/zstd initramfs works with no `COMPRESS` changes.

Remove it again with:

```sh
sudo ./scripts/install-ubuntu.sh --uninstall
```

**On plain Arch with GRUB / systemd-boot:**

```sh
sudo ./scripts/install-arch.sh
```

### 3. Reboot and verify

```sh
sudo dmesg | grep -i "table upgrade"        # ACPI: Table Upgrade: override [DSDT-...]
ls /sys/bus/i2c/devices/ | grep -i msft     # i2c-MSFT0001:00
grep -A4 "MSFT0001" /proc/bus/input/devices # MSFT0001:00 04F3:3072 Touchpad
```

or run `./scripts/verify.sh`. To confirm the table actually made it into the
initramfs, check a Mint/Ubuntu image with `lsinitramfs /boot/initrd.img-$(uname -r) | grep acpi`
(Omarchy/Arch: `unmkinitramfs ... | grep acpi`, or inspect the UKI).

## Clickpad behavior & recommended config

This touchpad is a **clickpad with no physical buttons** — and an unusual
quirk: **two-finger taps register as left-clicks**, because the firmware lifts
the finger contacts sequentially and libinput decides the tap button from the
fingers present at the *release* instant. YMMV; some units are more reliable
than others.

Dependable right-click on this hardware: **press the bottom-right corner of the
pad** (button-area). See [`docs/clickpad.md`](docs/clickpad.md) and the
snippets in [`config/hypr/`](config/hypr/) for a Hyprland/Omarchy
configuration that makes all of this behave.

## Troubleshooting / revert

If the machine hangs at boot after installing, remove the override and rebuild:

```sh
# Arch / Omarchy
sudo rm /etc/initcpio/acpi_override/dsdt.aml
sudo rm /etc/mkinitcpio.conf.d/omarchy_zz_acpi_override.conf
sudo mkinitcpio -P                          # Arch
sudo limine-mkinitcpio                      # Omarchy

# Linux Mint / Ubuntu / Debian
sudo ./scripts/install-ubuntu.sh --uninstall
# ...or manually:
# sudo rm /etc/initramfs-tools/hooks/acpi_override
# sudo rm -r /etc/acpi_override
# sudo update-initramfs -u
```

The override only swaps the ACPI table in RAM — it writes nothing to firmware,
so a full revert is always possible.

## Credits

- Original DSDT-patch technique and diagnosis: [simonsummer/lenovo-flex3-11ada05-touchpad-fix](https://github.com/simonsummer/lenovo-flex3-11ada05-touchpad-fix)
- Kernel mechanism: [ACPI tables via initrd](https://www.kernel.org/doc/html/latest/admin-guide/acpi/initrd_table_override.html)
- This repo: adapted the fix to **mkinitcpio `acpi_override` hook + Omarchy's
  limine UKIs**, documented the clickpad quirks, and condensed everything into
  `build -> install -> verify` scripts.

## Vibecoded

This repo was vibecoded with [opencode](https://opencode.ai) and **Big Pickle**
on a live machine, by pressing buttons and watching the lights. It works — the
trackpad that wrote this sentence is real. Readme also generated with opencode.

(human)
> took around 45 mintues with a nice fat prompt. a lot of the debugging was done before hand by me (not included in the time), the actual human. I just fed it the problems and how I assumed it should be fixed, and I told it to make a github > > repo for me. I will mark the human made things in this repo with "(human)." 

## Human made notes

(human)
> Will update for other distros eventually. make an issue or something i guess if you have a problem
_(Edit: Linux Mint / Ubuntu / Debian support landed 2026-09-20 — see the installers above.)_
_(Edit: Tested on linux mint/ubuntu on another laptop of the same model i have. it semi worked, but I had to do some shennanigans to get it functional)_
