#!/usr/bin/env bash
# Install the patched DSDT on Linux Mint / Ubuntu / Debian (initramfs-tools).
#
# The kernel reads ACPI table overrides out of the RAW initrd bytes with
# find_cpio_data() BEFORE any decompression phase runs (drivers/acpi/tables.c),
# so the table MUST live in the leading, uncompressed cpio of the initramfs.
# initramfs-tools builds that leading section - the "early initramfs", see
# prepend_earlyinitramfs in initramfs-tools(7) - and appends the compressed
# main archive after it. This installer stages a tiny early cpio holding
# kernel/firmware/acpi/dsdt.aml and prepends it via a small hook, so the fix
# works with the stock gzip/zstd initrd and no COMPRESS change is needed.
#
# Usage:
#   sudo ./scripts/install-ubuntu.sh          # install the override
#   sudo ./scripts/install-ubuntu.sh --uninstall   # remove it again
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AML="$REPO/build/dsdt.aml"
SRC=/etc/acpi_override
HOOK=/etc/initramfs-tools/hooks/acpi_override
EARLY="$SRC/acpi_override.cpio"

die() { echo "error: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || { echo "run as root:  sudo $0 [--uninstall]" >&2; exit 1; }

case "${1:-}" in
    --uninstall|-u)
        # Does not need ./build/dsdt.aml or even initramfs-tools to still be
        # present; just clean up what the installer laid down.
        echo "==> removing hook and staged files"
        rm -f "$HOOK" "$EARLY" "$SRC/dsdt.aml"
        rmdir "$SRC" 2>/dev/null || true
        if command -v update-initramfs >/dev/null 2>&1; then
            echo "==> rebuilding initramfs"
            update-initramfs -u -k all || update-initramfs -u
        fi
        cat <<EOF

done. The DSDT override was removed and update-initramfs was run.
The kernel only maps the override in RAM, so nothing else to undo.
EOF
        exit 0
        ;;
    "") ;;
    *) die "unknown argument '${1}' (usage: $0 [--uninstall])" ;;
esac

echo "==> preconditions"
[ -f "$AML" ] || die "no $AML - run './scripts/build-dsdt.sh' first (needs 'acpica-tools': sudo apt install acpica-tools)"
command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found - is this Ubuntu/Mint/Debian with initramfs-tools?"
command -v cpio >/dev/null 2>&1 || die "cpio not found - required to build the early initramfs archive (initramfs-tools depends on it)"

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
[ -f "$CFG" ] || CFG="/lib/modules/$(uname -r)/config"
if [ -f "$CFG" ] && ! grep -q "^CONFIG_ACPI_TABLE_UPGRADE=y" "$CFG"; then
    echo "WARN: $CFG does not enable CONFIG_ACPI_TABLE_UPGRADE=y - the override may be ignored."
fi
echo "    Secure Boot/lockdown OK"

echo "==> staging table at $SRC/dsdt.aml"
install -d "$SRC"
install -m 0644 "$AML" "$SRC/dsdt.aml"

echo "==> building early initramfs archive $EARLY"
TMP="$(mktemp -d)"
mkdir -p "$TMP/kernel/firmware/acpi"
cp -p "$SRC/dsdt.aml" "$TMP/kernel/firmware/acpi/dsdt.aml"
( cd "$TMP" && find kernel | cpio -o -H newc --quiet ) > "$EARLY"
rm -rf "$TMP"
chmod 0644 "$EARLY"

echo "==> installing initramfs-tools hook"
cat > "$HOOK" <<'EOS'
#!/bin/sh
# Stage the patched DSDT into the initramfs' EARLY (uncompressed) section so
# the kernel's ACPI table override can find it (docs/diagnosis.md). The kernel
# scans the raw initrd with find_cpio_data() before decompression runs, so a
# file that lands inside the compressed main archive would be invisible.
# Installed by install-ubuntu.sh (sudo ./scripts/install-ubuntu.sh).
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

SRC=/etc/acpi_override
[ -f "$SRC/dsdt.aml" ] && [ -s "$SRC/acpi_override.cpio" ] || exit 0

. /usr/share/initramfs-tools/hook-functions

# Same mechanism initramfs-tools documents for firmware/microcode preimages
# (initramfs-tools(7), "Including a system firmware preimage").
if command -v prepend_earlyinitramfs >/dev/null 2>&1; then
    prepend_earlyinitramfs "$SRC/acpi_override.cpio"
else
    echo "W: initramfs-tools too old for prepend_earlyinitramfs; staging DSDT" >&2
    echo "W: into the main archive instead. If that archive is compressed the" >&2
    echo "W: kernel will NOT see the override - prefer COMPRESS-free setup." >&2
    mkdir -p "$DESTDIR/kernel/firmware/acpi"
    cat "$SRC/dsdt.aml" > "$DESTDIR/kernel/firmware/acpi/dsdt.aml"
fi
exit 0
EOS
chmod 0755 "$HOOK"

echo "==> rebuilding initramfs (update-initramfs -u -k all)"
if ! update-initramfs -u -k all; then
    echo "WARN: 'update-initramfs -u -k all' failed - retrying for the running kernel only" >&2
    update-initramfs -u || { echo "WARN: update-initramfs failed - build the initramfs manually:" >&2
                             echo "      sudo update-initramfs -c -k \$(uname -r)" >&2; exit 1; }
fi

cat <<EOF

done. Reboot, then check:
  sudo dmesg | grep -i "table upgrade"
  ls /sys/bus/i2c/devices/ | grep -i msft
Debug (table really in the leading uncompressed initramfs?):
  lsinitramfs /boot/initrd.img-\$(uname -r) | grep "acpi"
Revert:
  sudo $0 --uninstall
EOF