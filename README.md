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
only the initramfs plumbing differs. Installers are provided for Omarchy/Arch,
Linux Mint/Ubuntu/Debian and Void Linux; anything else can follow
[`docs/manual-install.md`](docs/manual-install.md).

- **Omarchy / Arch** (mkinitcpio `acpi_override` hook, limine UKI) — `install-omarchy.sh`
- **Linux Mint / Ubuntu / Debian** (initramfs-tools hook) — `install-ubuntu.sh`
- **Void Linux** (dracut's native `acpi_override`) — `install-void.sh`

## Prerequisites

- Root access (`sudo` or `pkexec`, depending on your setup).
- `acpica` package (`iasl`, `acpidump`), plus `python3` and `cpio`.
  - Omarchy/Arch: `sudo pacman -S acpica python3 cpio`
  - Linux Mint/Ubuntu/Debian: `sudo apt install acpica-tools python3 cpio`
  - Void: `sudo xbps-install -S acpica-utils python3 cpio`
- **Secure Boot must be OFF.** The kernel refuses ACPI table overrides when
  Secure Boot or lockdown is active. Check with:

  ```sh
  mokutil --sb-state          # must NOT say "Secure Boot is enabled"
  cat /sys/kernel/security/lockdown   # active entry must be [none]
  ```

## Usage

Everything is also wrapped in a `Makefile`, so `sudo make build install` and
`make verify` work on any supported distro. The scripts are the source of truth.

### 1. Build the patched DSDT (from your own machine's tables)

```sh
sudo ./scripts/build-dsdt.sh          # or: pkexec ./scripts/build-dsdt.sh
sudo ./scripts/build-dsdt.sh --dry-run   # show the diff, compile nothing
```

Produces `build/dsdt.aml`, a rebuild of your firmware's `dsdt.dsl` for diffing
(`build/dsdt-orig.dsl`), and a ready-made `build/acpi_override` cpio for the
[manual install](docs/manual-install.md) path. Building from your *own* tables
means it works on any BIOS ≥ FPCN24WW.

The patcher refuses anything it does not recognise (unknown BIOS variant,
`TPTY` used outside the two methods it fixes) instead of guessing, and it
re-checks the compiled AML — not just the source — before writing output.
Re-running it on an already-patched table changes nothing.

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

Stages the table at `/etc/acpi_override/dsdt.aml` and installs a small
`initramfs-tools` hook (`/etc/initramfs-tools/hooks/acpi_override`) that
rebuilds a tiny uncompressed "early" initramfs archive containing
`kernel/firmware/acpi/dsdt.aml` on every initramfs build and prepends it via
`prepend_earlyinitramfs`. It then runs `update-initramfs -u -k all`.

The kernel digs ACPI overrides out of the **raw initrd bytes before any
decompression** (see `docs/diagnosis.md`), so staging the table into the
leading uncompressed section is required — dropping it into the compressed
main archive is silently ignored. Because the hook regenerates the archive from
`/etc/acpi_override/dsdt.aml` each time, rebuilding the table can never leave a
stale copy in the initramfs.

Remove it again with:

```sh
sudo ./scripts/install-ubuntu.sh --uninstall
```

**On plain Arch with GRUB / systemd-boot / UKI:**

```sh
sudo ./scripts/install-arch.sh
```

Arch is handled through a drop-in (`/etc/mkinitcpio.conf.d/zz-lenovo-flex3-acpi-override.conf`)
so `/etc/mkinitcpio.conf` is never edited. All installers accept
`--uninstall`, `--dry-run` and `--help`.

**On Void Linux:**

```sh
sudo ./scripts/install-void.sh
```

Void uses `dracut`, which supports ACPI table overrides natively — no hook
needed. The script stages the table at `/etc/dracut/acpi_override/dsdt.aml`,
writes `/etc/dracut.conf.d/99-lenovo-flex3-acpi-override.conf`

```sh
acpi_override="yes"
acpi_table_dir="/etc/dracut/acpi_override"
```

and runs `dracut --force --regenerate-all`. Dracut packs every `*.aml` from
that directory into a separate uncompressed cpio placed in front of the
compressed image, which is exactly what the kernel reads. Void's kernel
packages rerun dracut on update, so this survives kernel upgrades with nothing
else to maintain. Remove it with `sudo ./scripts/install-void.sh --uninstall`.
(`sudo xbps-install -S acpica-utils python3 cpio` is what the table build needs.)

**Anything else (Fedora, openSUSE, …):** see
[`docs/manual-install.md`](docs/manual-install.md). dracut has native support
for ACPI overrides; mkinitcpio and initramfs-tools need the early-cpio trick
described above.

### 3. Reboot and verify

```sh
sudo ./scripts/verify.sh; echo "exit=$?"
```

`verify.sh` exits **0** only when the override is live (`ACPI: Table Upgrade` in
dmesg, loaded DSDT identical to `build/dsdt.aml`), the `i2c-MSFT0001:00` device
exists, and the `04F3:3072` touchpad is bound. It exits **1** and names the
failing check otherwise; missing root just skips the checks that need it.

By hand:

```sh
sudo dmesg | grep -i "table upgrade"        # ACPI: Table Upgrade: override [DSDT-...]
ls /sys/bus/i2c/devices/ | grep -i msft     # i2c-MSFT0001:00
grep -A4 "MSFT0001" /proc/bus/input/devices # MSFT0001:00 04F3:3072 Touchpad
```

To confirm the table actually made it into the initramfs, check a Mint/Ubuntu
image with `lsinitramfs /boot/initrd.img-$(uname -r) | grep acpi`
(Omarchy/Arch: `lsinitcpio ...` or inspect the UKI).

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

If the machine hangs at boot after installing, remove the override and rebuild.
The installers can undo themselves:

```sh
# Arch / Omarchy
sudo ./scripts/install-arch.sh --uninstall
sudo ./scripts/install-omarchy.sh --uninstall     # Omarchy

# Linux Mint / Ubuntu / Debian
sudo ./scripts/install-ubuntu.sh --uninstall
```

If the scripts are gone, do it by hand:

```sh
# Arch / Omarchy
sudo rm /etc/initcpio/acpi_override/dsdt.aml
sudo rm /etc/mkinitcpio.conf.d/zz-lenovo-flex3-acpi-override.conf   # plain Arch
sudo rm /etc/mkinitcpio.conf.d/omarchy_zz_acpi_override.conf        # Omarchy
sudo mkinitcpio -P                          # Arch
sudo limine-mkinitcpio                      # Omarchy

# Linux Mint / Ubuntu / Debian
sudo rm /etc/initramfs-tools/hooks/acpi_override
sudo rm -r /etc/acpi_override
sudo update-initramfs -u
```

The override only swaps the ACPI table in RAM — it writes nothing to firmware,
so a full revert is always possible.

## Credits

- Original DSDT-patch technique and diagnosis: [simonsummer/lenovo-flex3-11ada05-touchpad-fix](https://github.com/simonsummer/lenovo-flex3-11ada05-touchpad-fix)
- Kernel mechanism: [ACPI tables via initrd](https://www.kernel.org/doc/html/latest/admin-guide/acpi/initrd_table_override.html)
- This repo: adapted the fix to **mkinitcpio `acpi_override` hook + Omarchy's
  limine UKIs**, documented the clickpad quirks, and condensed everything into
  `build -> install -> verify` scripts.

## Development

- `make test` — offline tests for the DSDT patcher (synthetic table fixtures, no
  hardware and no firmware dumps involved)
- `make lint` — shellcheck on every script plus a Python syntax check
- `make` — `build`, `install`, `verify`, `uninstall`, `clean` helpers; see
  `make help`

## License

MIT — see [`LICENSE`](LICENSE).

## Vibecoded

This repo was vibecoded with [opencode](https://opencode.ai) and **Big Pickle**
on a live machine, by pressing buttons and watching the lights. It works — the
trackpad that wrote this sentence is real. Readme also generated with opencode.

(human)
> took around 45 minutes with a nice fat prompt. a lot of the debugging was done
> beforehand by me (not included in the time), the actual human. I just fed it
> the problems and how I assumed it should be fixed, and I told it to make a
> GitHub repo for me. I will mark the human-made things in this repo with
> "(human)."

## Notes

(human)
> Will update for other distros eventually. make an issue or something i guess
> if you have a problem

_(Edit 2026-09-20: Linux Mint / Ubuntu / Debian support landed — see the
installers above.)_
_(Edit 2026-09-20: tested on Linux Mint/Ubuntu on another laptop of the same
model. It semi-worked; I had to do some shenanigans to get it functional.)_

> _(Edit 2026-09-23: `install-ubuntu.sh` was rewritten so the DSDT reaches the
> initramfs' leading **uncompressed** section via `prepend_earlyinitramfs` — the
> kernel reads ACPI overrides out of the raw initrd bytes before decompression,
> so the old `$DESTDIR` staging was invisible in the default gzip/zstd image.)_
>
> _(Edit: that rewrite now regenerates the early archive from
> `/etc/acpi_override/dsdt.aml` on every initramfs build, so a rebuilt table can
> no longer be shadowed by a stale archive. Still **not yet exercised on real
> Mint/Ubuntu hardware** — if you test it, please report back.)_
>
> _(Edit 2026-10-28: Void Linux support via `scripts/install-void.sh`, using
> dracut's native `acpi_override` instead of a custom hook. The initramfs
> plumbing was verified with dracut 112 in a sandbox build (the table lands in
> `kernel/firmware/acpi/dsdt.aml` inside the leading uncompressed cpio), but it
> has **not been booted on the Flex 3 yet** — report back if it misbehaves.)_
