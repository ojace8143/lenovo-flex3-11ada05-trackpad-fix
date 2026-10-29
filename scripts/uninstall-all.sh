#!/usr/bin/env bash
# Remove every artefact this project can install, on any supported initramfs
# generator. Useful after switching distros, when distro detection is wrong, or
# when a hand-edited install left something behind.
#
# This is deliberately conservative: config drop-ins are only removed when they
# carry this project's marker (see ensure_dropin in lib/common.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MKINITCPIO_LINE='HOOKS+=(acpi_override)'
DRACUT_LINES=('acpi_override="yes"' 'acpi_table_dir="/etc/dracut/acpi_override"')

# Files that are ours no matter what: plain tables and the initramfs hook.
OUR_FILES=(
    /etc/initcpio/acpi_override/dsdt.aml
    /etc/acpi_override/dsdt.aml
    /etc/acpi_override/acpi_override.cpio
    /etc/initramfs-tools/hooks/acpi_override
    /etc/dracut/acpi_override/dsdt.aml
)

# Directories we created (only removed when empty).
OUR_DIRS=(
    /etc/initcpio/acpi_override
    /etc/acpi_override
    /etc/dracut/acpi_override
)

usage() {
    cat <<'EOF'
Remove every trace of the patched-DSDT override from this machine.

Usage:
  sudo ./scripts/uninstall-all.sh [options]

Options:
  -n, --dry-run   show what would be removed, change nothing (no root needed)
  -h, --help      show this help

This checks all supported initramfs generators (mkinitcpio, initramfs-tools,
dracut), not just the one this distro uses, then rebuilds whichever generators
are present.
EOF
}

parse_args "nh" "$@"
if [ "$OPT_HELP" -eq 1 ]; then
    usage
    exit 0
fi

[ "$OPT_DRY_RUN" -eq 1 ] || require_root

if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "would remove (if present):"
    printf '  %s\n' "${OUR_FILES[@]}"
    echo "would clean this project's lines from:"
    echo "  /etc/mkinitcpio.conf.d/zz-lenovo-flex3-acpi-override.conf"
    echo "  /etc/mkinitcpio.conf.d/omarchy_zz_acpi_override.conf"
    echo "  /etc/dracut.conf.d/99-lenovo-flex3-acpi-override.conf"
    echo "would then rebuild with whichever generators are installed."
    exit 0
fi

info "removing files"
for file in "${OUR_FILES[@]}"; do
    if [ -e "$file" ]; then
        rm -f "$file"
        echo "    removed $file"
    fi
done

info "cleaning managed config drop-ins"
remove_dropin /etc/mkinitcpio.conf.d/zz-lenovo-flex3-acpi-override.conf \
    "$MKINITCPIO_LINE"
remove_dropin /etc/mkinitcpio.conf.d/omarchy_zz_acpi_override.conf \
    "$MKINITCPIO_LINE"
remove_dropin /etc/dracut.conf.d/99-lenovo-flex3-acpi-override.conf \
    "${DRACUT_LINES[@]}"

for dir in "${OUR_DIRS[@]}"; do
    rmdir "$dir" 2>/dev/null || true
done

if grep -qE '^[[:space:]]*HOOKS=.*\bacpi_override\b' /etc/mkinitcpio.conf 2>/dev/null; then
    warn "acpi_override is still listed in HOOKS in /etc/mkinitcpio.conf (from an
     older install). It is harmless now that the table is gone; delete the word
     from that line if you like."
fi

info "rebuilding initramfs"
rebuilt=0
if command -v update-initramfs >/dev/null 2>&1; then
    rebuilt=1
    update-initramfs -u -k all || warn "'update-initramfs -u -k all' failed"
fi
if command -v dracut >/dev/null 2>&1; then
    rebuilt=1
    dracut --force --regenerate-all || warn "dracut --regenerate-all failed"
fi
if command -v mkinitcpio >/dev/null 2>&1; then
    rebuilt=1
    if command -v limine-mkinitcpio >/dev/null 2>&1; then
        limine-mkinitcpio || warn "limine-mkinitcpio failed"
    else
        mkinitcpio -P || warn "mkinitcpio -P failed"
    fi
fi
if [ "$rebuilt" -eq 0 ]; then
    warn "no initramfs generator found - rebuild manually before rebooting"
fi

echo
echo "done. Reboot to return to the firmware table."
