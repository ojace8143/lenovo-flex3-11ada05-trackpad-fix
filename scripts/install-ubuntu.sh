#!/usr/bin/env bash
# Install the patched DSDT on Linux Mint / Ubuntu / Debian (initramfs-tools).
#
# Ubuntu-family systems have no built-in 'acpi_override' hook like Arch's
# mkinitcpio. initramfs-tools builds the initramfs by running executable
# scripts in /etc/initramfs-tools/hooks/, so we install a tiny hook that
# stages /etc/acpi_override/dsdt.aml into kernel/firmware/acpi/ (the kernel's
# documented location for ACPI table overrides).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AML="$REPO/build/dsdt.aml"
SRC=/etc/acpi_override
HOOK=/etc/initramfs-tools/hooks/acpi_override

die() { echo "error: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || { echo "run as root:  sudo $0"; exit 1; }
[ -f "$AML" ] || die "no $AML - run './scripts/build-dsdt.sh' first (needs 'acpica-tools': sudo apt install acpica-tools)"
command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found - is this Ubuntu/Mint/Debian with initramfs-tools?"

echo "==> preconditions"
# The kernel ignores ACPI table overrides under Secure Boot / lockdown.
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    die "Secure Boot is ENABLED - the kernel refuses ACPI overrides in this state.
         Disable Secure Boot in the BIOS (firmware setup) and delete any pending MOK
         enrollments, then retry."
fi
if [ -r /sys/kernel/security/lockdown ] && ! grep -q "\[none\]" /sys/kernel/security/lockdown; then
    die "kernel lockdown is active ($(tr '\n' ' ' < /sys/kernel/security/lockdown)) - overrides blocked."
fi

# Kernel must have been built with CONFIG_ACPI_TABLE_UPGRADE=y.
CFG="/boot/config-$(uname -r)"
if [ -f "$CFG" ] && ! grep -q "^CONFIG_ACPI_TABLE_UPGRADE=y" "$CFG"; then
    echo "WARN: $CFG does not enable CONFIG_ACPI_TABLE_UPGRADE=y - the override may be ignored."
fi
echo "    Secure Boot/lockdown OK"

echo "==> installing table at $SRC/dsdt.aml"
install -d "$SRC"
install -m 0644 "$AML" "$SRC/dsdt.aml"

echo "==> installing initramfs-tools hook"
cat > "$HOOK" <<'EOS'
#!/bin/sh
# Stage the patched DSDT into the initramfs for the kernel's ACPI table
# override mechanism (docs/diagnosis.md). Installed by install-ubuntu.sh.
PREREQ=""
prereqs() {
    echo "$PREREQ"
}
case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /usr/share/initramfs-tools/hook-functions

mkdir -p "$DESTDIR/kernel/firmware/acpi"
cat /etc/acpi_override/dsdt.aml > "$DESTDIR/kernel/firmware/acpi/dsdt.aml"
exit 0
EOS
chmod 0755 "$HOOK"

echo "==> rebuilding initramfs (update-initramfs -u)"
if ! update-initramfs -u; then
    echo "WARN: update-initramfs failed - build the initramfs manually:" >&2
    echo "      sudo update-initramfs -c -k \$(uname -r)" >&2
    exit 1
fi

cat <<EOF

done. Reboot, then check:
  sudo dmesg | grep -i "table upgrade"
  ls /sys/bus/i2c/devices/ | grep -i msft
Debug (table actually staged?):
  lsinitramfs /boot/initrd.img-\$(uname -r) | grep "acpi"
Revert:
  sudo rm $HOOK $SRC/dsdt.aml && sudo update-initramfs -u
EOF