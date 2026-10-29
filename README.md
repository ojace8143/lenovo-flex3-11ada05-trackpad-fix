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

## Supported systems

The machine this was developed on:

| Thing | Value |
|---|---|
| Machine | Lenovo IdeaPad Flex 3 11ADA05 (`82G4`) |
| BIOS | `FPCN26WW` (05/2022) — fixed, **no downgrade needed** |
| Distro | Omarchy (Arch-based, Hyprland, limine UKI) |
| Kernel | `7.2.5-3-omarchy` |
| Secure Boot | OFF (required — see below) |

The mechanism is a **kernel ACPI table override**, so it is not distro-specific —
only the initramfs plumbing differs. What works today:

| System | Mechanism | Status |
|---|---|---|
| Omarchy / Arch | mkinitcpio `acpi_override` hook | tested (original unit) |
| Void Linux | dracut `acpi_override` | tested (second unit, Oct 2026) |
| Linux Mint / Ubuntu / Debian | initramfs-tools hook | semi-tested, see notes |
| Fedora / openSUSE (dracut) | dracut `acpi_override` | installer provided, untested |
| NixOS / Alpine | — | not supported, see [`docs/distros.md`](docs/distros.md) |

Installers:

- **Omarchy / Arch** (mkinitcpio, limine UKI or GRUB) — `install-omarchy.sh` / `install-arch.sh`
- **Linux Mint / Ubuntu / Debian** (initramfs-tools hook) — `install-ubuntu.sh`
- **Void Linux** — `install-void.sh`
- **Any other dracut distro** (Fedora, openSUSE, Debian/Arch with dracut) — `install-dracut.sh`

Full details, including exactly which files each one writes, are in
[`docs/distros.md`](docs/distros.md). Anything else can follow
[`docs/manual-install.md`](docs/manual-install.md).

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
needed. `install-void.sh` is a thin wrapper around the generic dracut installer:

```sh
sudo ./scripts/install-dracut.sh        # Fedora, openSUSE, or Void directly
```

It stages the table at `/etc/dracut/acpi_override/dsdt.aml`, writes
`/etc/dracut.conf.d/99-lenovo-flex3-acpi-override.conf`

```sh
acpi_override="yes"
acpi_table_dir="/etc/dracut/acpi_override"
```

and runs `dracut --force --regenerate-all`. Dracut packs every `*.aml` from
that directory into a separate uncompressed cpio placed in front of the
compressed image, which is exactly what the kernel reads. Kernel packages on
these distros normally rerun dracut on update, so this survives kernel upgrades
with nothing else to maintain. Remove it with `--uninstall`.

**Anything else:** see [`docs/distros.md`](docs/distros.md) and
[`docs/manual-install.md`](docs/manual-install.md) (manual cpio for mkinitcpio,
initramfs-tools or a hand-rolled initrd). NixOS and Alpine are documented as
unsupported.

### 3. Reboot and verify

```sh
sudo ./scripts/verify.sh; echo "exit=$?"
```

`verify.sh` exits **0** only when the override is live (`ACPI: Table Upgrade` in
dmesg, loaded DSDT identical to `build/dsdt.aml`), the `i2c-MSFT0001:00` device
exists, and the `04F3:3072` touchpad is bound. It exits **1** and names the
failing check otherwise.

Run it with `sudo`: the dmesg and `/sys/firmware/acpi/tables` checks need root.
Without root they are reported as `skip` and the summary says how many checks
were skipped, so a non-root run can never silently claim success.

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

# Void / Fedora / openSUSE (dracut)
sudo ./scripts/install-void.sh --uninstall
sudo ./scripts/install-dracut.sh --uninstall
```

If you are not sure what was installed (switched distro, hand-edited files,
distro detection picked wrong), remove everything at once:

```sh
sudo ./scripts/uninstall-all.sh       # or: sudo make purge
sudo ./scripts/uninstall-all.sh --dry-run   # show first
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
- `make distro` — print the detected distro and initramfs generator
- `make` — `build`, `install`, `verify`, `uninstall`, `purge`, `clean` helpers;
  see `make help`

Supported systems, per-installer details and the "not supported" list live in
[`docs/distros.md`](docs/distros.md).

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
> _(Edit 2026-10-28: Void Linux support landed as `scripts/install-dracut.sh`
> (with `install-void.sh` as the Void entry point), using dracut's native
> `acpi_override` instead of a custom hook. **Confirmed working on a second
> Flex 3 11ADA05 running Void Linux** — the touchpad appears after reboot and
> `verify.sh` passes. A generic dracut installer now covers Fedora/openSUSE,
> and `scripts/uninstall-all.sh` (`make purge`) removes everything regardless
> of which installer was used.)_
