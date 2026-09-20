#!/usr/bin/env bash
# Install the patched DSDT on a plain Arch setup (GRUB / systemd-boot / etc.)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AML="$REPO/build/dsdt.aml"

die() { echo "error: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || { echo "run as root:  sudo $0   (or: pkexec $0)"; exit 1; }
[ -f "$AML" ] || die "no $AML - run ./scripts/build-dsdt.sh first"

if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    die "Secure Boot is active - disable it in the BIOS first."
fi
if [ -r /sys/kernel/security/lockdown ] && ! grep -q "\[none\]" /sys/kernel/security/lockdown; then
    die "kernel lockdown is active - ACPI table overrides are blocked."
fi

install -d /etc/initcpio/acpi_override
install -m 0644 "$AML" /etc/initcpio/acpi_override/dsdt.aml
echo "==> installed /etc/initcpio/acpi_override/dsdt.aml"

if ! grep -q "^HOOKS=.*acpi_override" /etc/mkinitcpio.conf; then
    sed -i 's/^HOOKS=(/HOOKS=(acpi_override /' /etc/mkinitcpio.conf
    echo "==> added acpi_override to HOOKS in /etc/mkinitcpio.conf"
fi

echo "==> rebuilding initramfs / UKI"
mkinitcpio -P

cat <<EOF

done. Reboot, then check:
  sudo dmesg | grep -i "table upgrade"
  ls /sys/bus/i2c/devices/ | grep -i msft
Revert: remove acpi_override from HOOKS and delete
        /etc/initcpio/acpi_override/dsdt.aml, then run mkinitcpio -P
EOF