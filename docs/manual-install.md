# Manual install (any distro)

The installers cover mkinitcpio (Arch/Omarchy) and initramfs-tools (Mint/
Ubuntu/Debian). Everything else works the same way; only the plumbing that puts
the table into the initramfs differs. The kernel requirement is always the same:

- `CONFIG_ACPI_TABLE_UPGRADE=y` in the kernel config,
- Secure Boot **off** and lockdown `[none]`,
- the table at `kernel/firmware/acpi/dsdt.aml` inside the initramfs'
  **leading, uncompressed** cpio archive (see
  [`diagnosis.md`](diagnosis.md) for why the compressed part is invisible).

Build the table first:

```sh
sudo ./scripts/build-dsdt.sh
```

That produces `build/dsdt.aml` plus `build/acpi_override`, a ready-made
uncompressed cpio containing `kernel/firmware/acpi/dsdt.aml`. Commit nothing
from `build/`; it is per-machine output.

## dracut

dracut supports ACPI table overrides natively (`dracut.conf(5)`):

```sh
sudo install -d /etc/dracut/acpi_override
sudo install -m 0644 build/dsdt.aml /etc/dracut/acpi_override/dsdt.aml
sudo install -d /etc/dracut.conf.d
sudo tee /etc/dracut.conf.d/99-acpi-override.conf >/dev/null <<'EOF'
acpi_override="yes"
acpi_table_dir="/etc/dracut/acpi_override"
EOF
sudo dracut --force --regenerate-all
```

dracut collects every `*.aml` in `acpi_table_dir` into a separate uncompressed
cpio concatenated ahead of the compressed image, which is exactly what the
kernel wants. It also refuses (with a warning) if `CONFIG_ACPI_TABLE_UPGRADE`
is missing.

This is the documented path for **Void Linux** too; a dedicated
`install-void.sh` arrives in the next step and will do exactly the above.

## GRUB with a separate initrd

Add the cpio as an extra initrd **before** the real initramfs, because the
kernel scans the raw bytes front-to-back:

```
# /etc/grub.d/40_custom or a hand-written menu entry
linux   /vmlinuz-linux root=UUID=... rw
initrd  /acpi_override.cpio /initramfs-linux.img
```

Copy `build/acpi_override` to `/boot/acpi_override.cpio` (or wherever your
loader can read it) and regenerate the bootloader config.

## systemd-boot / UKI

When building a unified kernel image, pass the cpio first in the initrd list
(for example `ukify build --initrd build/acpi_override ...`). A UKI is a PE
binary, so nothing can inspect it afterwards; verify after reboot instead.

## Verify

```sh
sudo ./scripts/verify.sh; echo "exit=$?"
```

Exit 0 means the override is live, the loaded DSDT matches `build/dsdt.aml`,
and the touchpad is bound. A non-zero exit prints exactly which check failed.

## Revert

Delete the table and the config line you added, then rebuild the initramfs /
UKI. Nothing is written to firmware, so this always restores the original
behaviour after a reboot.
