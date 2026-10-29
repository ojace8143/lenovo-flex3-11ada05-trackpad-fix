#!/usr/bin/env bash
# Install the patched DSDT on any dracut-based distro (Void, Fedora, openSUSE,
# Debian/Arch with dracut, ...).
#
# dracut has native support for ACPI table overrides (dracut.conf(5)):
#
#   acpi_override="yes"
#   acpi_table_dir="<dir>"
#
# It packs every *.aml found in that directory into a separate, *uncompressed*
# cpio archive that is concatenated in front of the compressed image - exactly
# the layout the kernel wants, because it reads overrides out of the raw initrd
# bytes before decompression (drivers/acpi/tables.c). No custom hook is needed.
#
# install-void.sh is a thin wrapper around this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO="$(repo_root)"
AML="$REPO/build/dsdt.aml"
TABLE_DIR="/etc/dracut/acpi_override"
TABLE="$TABLE_DIR/dsdt.aml"
# "99-" so it sorts last: files in /etc/dracut.conf.d are sourced in
# alphabetical order and later values win.
DROPIN="/etc/dracut.conf.d/99-lenovo-flex3-acpi-override.conf"
DROPIN_LINES=('acpi_override="yes"' "acpi_table_dir=\"$TABLE_DIR\"")

usage() {
    cat <<'EOF'
Install (or remove) the patched DSDT on a dracut-based system.

Usage:
  sudo ./scripts/install-dracut.sh [options]

Options:
  -u, --uninstall   remove the override and rebuild the initramfs
  -n, --dry-run     show what would happen, change nothing (no root needed)
  -h, --help        show this help

Run ./scripts/build-dsdt.sh first (it writes build/dsdt.aml).

What it does:
  1. stages build/dsdt.aml as /etc/dracut/acpi_override/dsdt.aml
  2. writes /etc/dracut.conf.d/99-lenovo-flex3-acpi-override.conf containing
       acpi_override="yes"
       acpi_table_dir="/etc/dracut/acpi_override"
  3. rebuilds every initramfs with: dracut --force --regenerate-all

Needs: dracut. Building the table needs iasl/acpidump (acpica), python3, cpio.
EOF
}

pkg_hint() {
    case "$(detect_distro)" in
        arch)   echo "pacman -S acpica python3 cpio" ;;
        debian) echo "apt install acpica-tools python3 cpio" ;;
        void)   echo "xbps-install -S acpica-utils python3 cpio" ;;
        *)      echo "install your distro's acpica/python3/cpio packages" ;;
    esac
}

rebuild_initramfs() {
    info "rebuilding initramfs for all installed kernels (dracut --force --regenerate-all)"
    dracut --force --regenerate-all
}

parse_args "unh" "$@"
if [ "$OPT_HELP" -eq 1 ]; then
    usage
    exit 0
fi

# --- uninstall --------------------------------------------------------------
if [ "$OPT_UNINSTALL" -eq 1 ]; then
    [ "$OPT_DRY_RUN" -eq 1 ] || require_root
    info "removing the ACPI override"
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "    would remove $TABLE and $DROPIN"
        echo "    would run: dracut --force --regenerate-all"
        exit 0
    fi

    remove_dropin "$DROPIN" "${DROPIN_LINES[@]}"
    rm -f "$TABLE"
    rmdir "$TABLE_DIR" 2>/dev/null || true

    if command -v dracut >/dev/null 2>&1; then
        rebuild_initramfs
    else
        warn "dracut not found - rebuild your initramfs before rebooting"
    fi

    echo
    echo "done. The override is gone; reboot to return to the firmware table."
    exit 0
fi

# --- install ----------------------------------------------------------------
[ "$OPT_DRY_RUN" -eq 1 ] || require_root

info "checking preconditions"
check_aml_file "$AML"

if ! command -v dracut >/dev/null 2>&1; then
    if command -v mkinitcpio >/dev/null 2>&1; then
        die "dracut not found, but mkinitcpio is installed - use ./scripts/install-arch.sh"
    fi
    if [ -d /etc/initramfs-tools ]; then
        die "dracut not found, but initramfs-tools is installed - use ./scripts/install-ubuntu.sh"
    fi
    die "dracut not found - install it with: $(case "$(detect_distro)" in
        void) echo 'xbps-install -S dracut' ;;
        arch) echo 'pacman -S dracut' ;;
        debian) echo 'apt install dracut' ;;
        *) echo 'your package manager' ;;
    esac)"
fi

DRACUT_BIN="$(command -v dracut)"
if ! grep -q 'acpi_override' "$DRACUT_BIN" 2>/dev/null; then
    die "this dracut ($DRACUT_BIN) has no acpi_override support - it is too old.
     Update dracut first."
fi

check_acpi_override_preconditions
echo "    no blocking Secure Boot / lockdown state found"

# /etc/dracut.conf.d is sourced in order and later assignments win, so a
# different file setting these options would be surprising; point it out.
other_configs="$(grep -lE '^[[:space:]]*(acpi_override|acpi_table_dir)=' \
    /etc/dracut.conf /etc/dracut.conf.d/*.conf 2>/dev/null \
    | grep -vF "$DROPIN" || true)"
if [ -n "$other_configs" ]; then
    warn "these dracut config files also set acpi_override/acpi_table_dir:
$(printf '%s\n' "$other_configs" | sed 's/^/       /')
     $DROPIN sorts last (99-), so its values win."
fi

if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "    would install $AML -> $TABLE"
    echo "    would write to $DROPIN:"
    printf '      %s\n' "${DROPIN_LINES[@]}"
    echo "    would run: dracut --force --regenerate-all"
    exit 0
fi

info "staging the table"
install -d "$TABLE_DIR"
install -m 0644 "$AML" "$TABLE"

info "enabling dracut's acpi_override"
ensure_dropin "$DROPIN" "${DROPIN_LINES[@]}"

rebuild_initramfs

cat <<EOF

installed:
  table:  $TABLE
  config: $DROPIN

Kernel packages on dracut-based distros regenerate the initramfs on update, so
this survives kernel upgrades. Nothing else to maintain.

Revert with:
  sudo $0 --uninstall
EOF

info "checking the generated initramfs"
check_boot_images_for_table

print_verify_steps
