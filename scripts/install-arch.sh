#!/usr/bin/env bash
# Install the patched DSDT on a plain Arch setup (mkinitcpio + GRUB,
# systemd-boot or a UKI). Omarchy users want install-omarchy.sh instead.
#
# The hook is enabled through a drop-in in /etc/mkinitcpio.conf.d/ rather than
# by editing HOOKS= in /etc/mkinitcpio.conf, so your config is never touched
# and --uninstall is a clean one-liner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO="$(repo_root)"
AML="$REPO/build/dsdt.aml"
STAGE_DIR="/etc/initcpio/acpi_override"
STAGE_AML="$STAGE_DIR/dsdt.aml"
DROPIN="/etc/mkinitcpio.conf.d/zz-lenovo-flex3-acpi-override.conf"
HOOK_LINE='HOOKS+=(acpi_override)'
MKINITCPIO_HOOK="/usr/lib/initcpio/install/acpi_override"

usage() {
    cat <<'EOF'
Install (or remove) the patched DSDT for mkinitcpio-based Arch systems.

Usage:
  sudo ./scripts/install-arch.sh [options]

Options:
  -u, --uninstall   remove the override and rebuild the initramfs
  -n, --dry-run     show what would happen, change nothing
  -h, --help        show this help

Run ./scripts/build-dsdt.sh first (it writes build/dsdt.aml).
EOF
}

rebuild_initramfs() {
    info "rebuilding initramfs / UKI (mkinitcpio -P)"
    mkinitcpio -P
}

report_installed() {
    echo
    echo "installed:"
    echo "  table:  $STAGE_AML"
    echo "  hook:   $HOOK_LINE in $DROPIN"
}

parse_args "unh" "$@"
if [ "$OPT_HELP" -eq 1 ]; then
    usage
    exit 0
fi

if [ "$OPT_UNINSTALL" -eq 1 ]; then
    [ "$OPT_DRY_RUN" -eq 1 ] || require_root
    info "removing the ACPI override"
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "    would remove $STAGE_AML and $DROPIN"
        echo "    would run: mkinitcpio -P"
        exit 0
    fi
    remove_dropin "$DROPIN" "$HOOK_LINE"
    rm -f "$STAGE_AML"
    rmdir "$STAGE_DIR" 2>/dev/null || true
    if grep -qE '^[[:space:]]*HOOKS=.*\bacpi_override\b' /etc/mkinitcpio.conf 2>/dev/null; then
        warn "acpi_override is still listed in HOOKS in /etc/mkinitcpio.conf (left over
     from an older install). It is harmless now that the table is gone, but you
     can delete the word from that line."
    fi
    rebuild_initramfs
    echo
    echo "done. The override is gone; reboot to return to the firmware table."
    exit 0
fi

[ "$OPT_DRY_RUN" -eq 1 ] || require_root
need mkinitcpio "pacman -S mkinitcpio"
check_aml_file "$AML"
if [ ! -f "$MKINITCPIO_HOOK" ]; then
    die "this mkinitcpio has no 'acpi_override' hook ($MKINITCPIO_HOOK is missing).
     Update mkinitcpio (pacman -Syu mkinitcpio), or use the manual cpio method in
     docs/manual-install.md."
fi

info "checking preconditions"
check_acpi_override_preconditions
echo "    no blocking Secure Boot / lockdown state found"

if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "    would install $AML -> $STAGE_AML"
    echo "    would add '$HOOK_LINE' to $DROPIN"
    echo "    would run: mkinitcpio -P"
    exit 0
fi

info "staging the table"
install -d "$STAGE_DIR"
install -m 0644 "$AML" "$STAGE_AML"

info "enabling the acpi_override hook"
ensure_dropin "$DROPIN" "$HOOK_LINE"
if grep -qE '^[[:space:]]*HOOKS=.*\bacpi_override\b' /etc/mkinitcpio.conf 2>/dev/null; then
    warn "acpi_override is also listed in HOOKS in /etc/mkinitcpio.conf - that is
     redundant but harmless; drop-in removal on --uninstall does not touch it."
fi

rebuild_initramfs
report_installed

info "checking the generated initramfs"
check_boot_images_for_table

echo
echo "revert with:  sudo $0 --uninstall"
print_verify_steps
