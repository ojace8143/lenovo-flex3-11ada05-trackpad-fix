# Diagnosis — why the touchpad dies on BIOS >= FPCN24WW

## Symptom

On BIOS versions **FPCN24WW or newer** the ELAN `04F3:3072` touchpad is
completely absent under Linux: no `i2c-MSFT0001:00` bus device, no input
device, no `04F3:3072` in `libinput list-devices`. Kernel messages show the
`MSFT0001` ACPI device is probed but gets no usable I²C resource, so the
interrupt handling device is never created. The touchscreen keeps working.

## Root cause

The touchpad lives on the `I2CD` I²C controller behind the `LPC0`-attached
embedded controller (`EC`). In the DSDT, the touchpad device `TPD0` returns
its `_CRS` resources (I²C bus address) **conditionally**, keyed on an EC
register `TPTY`:

- if `EC.TPTY == 0x01`, the pad uses I²C address `0x15` and the normal
  `GpioInt` — this is the working case;
- if `EC.TPTY == 0x02`, a different (touchscreen?) address `0x2C` is used;
- otherwise → **no resources returned → no touchpad**.

On older BIOS (FPCN21WW era), the EC happened to report `0x01` early enough in
boot that Linux got the resource. Starting with FPCN24WW, the EC no longer
reports `0x01` before Linux walks the table, so `TPD0._CRS` yields nothing and
the touchpad never registers.

`TPD0._DSM` function 1 (feature report) is gated on the same `TPTY` register,
with the same failure mode.

## The fix

Override the DSDT at boot with a patched copy in which `TPD0` no longer
depends on the EC:

- `_CRS` unconditionally returns the `0x15` I²C resource + `GpioInt`;
- `_DSM` function 1 unconditionally returns `0x01`;
- the DSDT **OEM revision field is bumped** (0x1000 in our builds) — the
  kernel’s ACPI table override mechanism compares OEM revision and ignores the
  override if it is not *newer* than the loaded table.

## Mechanism: initrd table override

Linux supports overriding firmware tables with files placed at
`kernel/firmware/acpi/<TABLE>.aml` inside the initramfs (see
[kernel docs](https://www.kernel.org/doc/html/latest/admin-guide/acpi/initrd_table_override.html)):

1. `CONFIG_ACPI_TABLE_UPGRADE=y` in the kernel config, **and** no Secure
   Boot / `lockdown` mode;
2. an early cpio in the initramfs carries `kernel/firmware/acpi/dsdt.aml`;
3. at boot the kernel maps the override for the DSDT signature, replaces the
   table, then proceeds with normal ACPI init.

mkinitcpio (>= 39) ships a built-in `acpi_override` install hook that stages
every `*.aml` in `/etc/initcpio/acpi_override/` into the **early uncompressed
cpio** of the initramfs / UKI.

Ubuntu-family systems (Linux Mint/Debian) use **initramfs-tools**, which has no
built-in hook. `scripts/install-ubuntu.sh` installs a small hook into
`/etc/initramfs-tools/hooks/` that stages the table into
`$DESTDIR/kernel/firmware/acpi/` — the same early-cpio location, so the end
result is identical.

## Why not just downgrade the BIOS?

The forum-famous fix is a BIOS downgrade to `FPCN21WW`. Downsides:

- The Lenovo flasher (`fpcn21ww.exe`) is **Windows-only** and its payload is
  encrypted (not extractable under Linux);
- the machine is UEFI-only and no bootable-CD BIOS image exists for this
  model, so you need a Windows PE — which struggles to boot in **3.2 GiB RAM**
  (Hiren's BootCD PE fails: "not enough RAM to create a ramdisk");
- flashing firmware is riskier than a table override that only lives in RAM.

This repo sidesteps all three.

## Evidence captured on the original machine

- `CONFIG_ACPI_TABLE_UPGRADE=y`, Secure Boot off (`efivar` flag byte `0x00`),
  lockdown `[none]`.
- After installing the override, the initrd's early cpio contained a
  byte-identical `kernel/firmware/acpi/dsdt.aml` (**28001 bytes**).
- Post-reboot: `i2c-MSFT0001:00` present, input device
  `MSFT0001:00 04F3:3072 Touchpad` live, HID id `04F3:3072` confirmed.