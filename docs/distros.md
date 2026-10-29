# Supported systems

The fix is a kernel ACPI-table override, so the only thing that differs between
distros is *how the table gets into the leading uncompressed cpio of the
initramfs*. This page lists what each installer writes and what to run instead
if your system is not covered.

| System | Initramfs tool | Installer | Status |
|---|---|---|---|
| Omarchy (Arch + limine UKI) | mkinitcpio | `install-omarchy.sh` | tested on the original unit (BIOS `FPCN26WW`) |
| Void Linux | dracut | `install-void.sh` | tested on a second unit (Oct 2026) |
| Linux Mint / Ubuntu / Debian | initramfs-tools | `install-ubuntu.sh` | semi-tested (see the notes in the README) |
| plain Arch (GRUB / systemd-boot / UKI) | mkinitcpio | `install-arch.sh` | installer provided, not yet reported |
| Fedora / openSUSE (dracut) | dracut | `install-dracut.sh` | installer provided, not yet reported |
| Debian or Arch **using dracut** | dracut | `install-dracut.sh` | works, same as above |
| NixOS | declarative initrd | — | not supported, see below |
| Alpine (mkinitfs) | mkinitfs | — | not supported, see below |

`make install` / `make uninstall` pick the right one automatically: they detect
the initramfs generator that owns the running kernel's image, not the package
manager. `make distro` shows what was detected.

## What each installer touches

| Installer | Table staged at | Configuration | Rebuild command |
|---|---|---|---|
| `install-omarchy.sh` | `/etc/initcpio/acpi_override/dsdt.aml` | `/etc/mkinitcpio.conf.d/omarchy_zz_acpi_override.conf` | `limine-mkinitcpio` (falls back to `mkinitcpio -P`) |
| `install-arch.sh` | `/etc/initcpio/acpi_override/dsdt.aml` | `/etc/mkinitcpio.conf.d/zz-lenovo-flex3-acpi-override.conf` | `mkinitcpio -P` |
| `install-ubuntu.sh` | `/etc/acpi_override/dsdt.aml` | `/etc/initramfs-tools/hooks/acpi_override` | `update-initramfs -u -k all` |
| `install-dracut.sh` (and `install-void.sh`) | `/etc/dracut/acpi_override/dsdt.aml` | `/etc/dracut.conf.d/99-lenovo-flex3-acpi-override.conf` | `dracut --force --regenerate-all` |

All of them support `--uninstall`, `--dry-run` and `--help`, and all only remove
config files that carry this project's marker.

`scripts/uninstall-all.sh` (`make purge`) removes every artefact above,
regardless of which distro installed it — useful after switching distros or if
detection picked the wrong installer.

## Why the table must be in the *early* cpio

The kernel scans the raw initrd bytes with `find_cpio_data()` before any
decompression runs, so a table inside the compressed main archive is invisible.
See [`diagnosis.md`](diagnosis.md) for the gory details and the mechanism each
tool uses:

- **mkinitcpio**: built-in `acpi_override` hook (early cpio via `add_file_early`).
- **initramfs-tools**: `prepend_earlyinitramfs()` from a hook.
- **dracut**: native `acpi_override="yes"` + `acpi_table_dir=` options.

## Not supported

- **NixOS** builds the initramfs declaratively, so the "drop a file in /etc and
  rebuild" model does not apply. It would need a custom initrd module; nobody
  has written one for this fix. The BIOS downgrade or a kernel patch are the
  alternatives.
- **Alpine** uses `mkinitfs` with a different hook model; the manual cpio
  approach in [`manual-install.md`](manual-install.md) may work but is untested.

## Atomic / ostree hosts (Silverblue, Bazzite, …)

`/etc` persists across deployments, so the dracut drop-in survives updates and
is honoured when rpm-ostree/bootc regenerate the initramfs. This is untested —
if you try it, please report back.

## Secure Boot

Any of this requires Secure Boot **off** (or lockdown `[none]`), because the
kernel refuses ACPI table overrides when either is active. Signing the initramfs
does not help; there is no MOK/shim path for this. All installers check and
refuse to continue if they detect it.
