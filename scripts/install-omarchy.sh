#!/usr/bin/env bash
# Install the patched DSDT on Omarchy (Arch + limine + UKI).
#
# Omarchy keeps its mkinitcpio hook list in a drop-in config
# (/etc/mkinitcpio.conf.d/omarchy_hooks.conf) that OVERRIDES
# /etc/mkinitcpio.conf. Drop-in files source in alphabetical order, so our
# overriding append must sort AFTER omarchy_hooks.conf -> "omarchy_zz_*".
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AML="$REPO/build/dsdt.aml"
DROPIN="/etc/mkinitcpio.conf.d/omarchy_zz_acpi_override.conf"

die() { echo "error: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || { echo "run as root:  sudo $0   (or: pkexec $0)"; exit 1; }
[ -f "$AML" ] || die "no $AML - run ./scripts/build-dsdt.sh first"

# --- Preconditions (kernel blocks ACPI overrides otherwise) ---------------
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    die "Secure Boot is active - disable it in the BIOS first."
fi
if [ -r /sys/kernel/security/lockdown ] && ! grep -q "\[none\]" /sys/kernel/security/lockdown; then
    die "kernel lockdown is active - ACPI table overrides are blocked."
fi

install -d /etc/initcpio/acpi_override
install -m 0644 "$AML" /etc/initcpio/acpi_override/dsdt.aml
echo "==> installed /etc/initcpio/acpi_override/dsdt.aml"

# mkinitcpio's built-in 'acpi_override' hook (ships with mkinitcpio >= 39)
# adds *.aml from /etc/initcpio/acpi_override/ into the early initramfs.
if ! grep -q "acpi_override" "$DROPIN" 2>/dev/null; then
    printf 'HOOKS+=(acpi_override)\n' > "$DROPIN"
fi
echo "==> enabled acpi_override hook via $DROPIN"

echo "==> rebuilding UKI(s)"
if command -v limine-mkinitcpio >/dev/null 2>&1; then
    limine-mkinitcpio
else
    mkinitcpio -P
fi

cat <<EOF

done. Reboot, then check:
  sudo dmesg | grep -i "table upgrade"
  ls /sys/bus/i2c/devices/ | grep -i msft
Revert: rm $DROPIN /etc/initcpio/acpi_override/dsdt.aml && limine-mkinitcpio
EOF