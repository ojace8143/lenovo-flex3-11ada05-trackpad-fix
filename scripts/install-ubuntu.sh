#!/usr/bin/env bash
# Install the patched DSDT on Linux Mint / Ubuntu / Debian (initramfs-tools).
#
# The kernel reads ACPI table overrides out of the RAW initrd bytes with
# find_cpio_data() BEFORE any decompression phase runs (drivers/acpi/tables.c),
# so the table MUST live in the leading, uncompressed cpio of the initramfs.
# initramfs-tools builds that leading section - the "early initramfs", see
# prepend_earlyinitramfs in initramfs-tools(7) - and appends the compressed
# main archive after it.
#
# scripts/hooks/initramfs-tools-acpi_override is installed as an
# initramfs-tools hook; it rebuilds a tiny early cpio from
# /etc/acpi_override/dsdt.aml on every initramfs build and prepends it. That
# means the fix keeps working with the stock gzip/zstd initrd, needs no
# COMPRESS change, and can never go stale after you rebuild the table.
#
# Usage:
#   sudo ./scripts/install-ubuntu.sh              # install the override
#   sudo ./scripts/install-ubuntu.sh --uninstall  # remove it again
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO="$(repo_root)"
AML="$REPO/build/dsdt.aml"
SRC_DIR="/etc/acpi_override"
STAGED_AML="$SRC_DIR/dsdt.aml"
HOOK_DST="/etc/initramfs-tools/hooks/acpi_override"
HOOK_SRC="$REPO/scripts/hooks/initramfs-tools-acpi_override"
LEGACY_CPIO="$SRC_DIR/acpi_override.cpio"

usage() {
    cat <<'EOF'
Install (or remove) the patched DSDT on Linux Mint / Ubuntu / Debian.

Usage:
  sudo ./scripts/install-ubuntu.sh [options]

Options:
  -u, --uninstall   remove the hook and the staged table, rebuild initramfs
  -n, --dry-run     show what would happen, change nothing
  -h, --help        show this help

Run ./scripts/build-dsdt.sh first (it writes build/dsdt.aml).
Needs: initramfs-tools, cpio, update-initramfs.
EOF
}

parse_args "unh" "$@"
if [ "$OPT_HELP" -eq 1 ]; then
    usage
    exit 0
fi

# --- uninstall --------------------------------------------------------------
if [ "$OPT_UNINSTALL" -eq 1 ]; then
    require_root
    info "removing the override"
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "    would remove $HOOK_DST, $STAGED_AML and $LEGACY_CPIO"
        echo "    would run: update-initramfs -u -k all"
        exit 0
    fi
    rm -f "$HOOK_DST" "$STAGED_AML" "$LEGACY_CPIO"
    rmdir "$SRC_DIR" 2>/dev/null || true

    if command -v update-initramfs >/dev/null 2>&1; then
        info "rebuilding initramfs"
        if ! update-initramfs -u -k all; then
            warn "'update-initramfs -u -k all' failed - retrying for $(uname -r) only"
            update-initramfs -u -k "$(uname -r)" \
                || die "initramfs rebuild failed; the override is already removed, but
     rebuild manually: sudo update-initramfs -u -k \$(uname -r)"
        fi
    else
        warn "update-initramfs not found - rebuild your initramfs before rebooting"
    fi

    echo
    echo "done. The DSDT override was removed; reboot to return to the firmware table."
    exit 0
fi

# --- install ----------------------------------------------------------------
require_root
info "checking preconditions"
[ -f "$AML" ] || die "no $AML - run './scripts/build-dsdt.sh' first (needs 'acpica-tools')"
need update-initramfs "is this Ubuntu/Mint/Debian with initramfs-tools?"
need cpio "initramfs-tools normally depends on it"
[ -f "$HOOK_SRC" ] || die "missing $HOOK_SRC (incomplete checkout?)"
[ -d /etc/initramfs-tools ] || die "/etc/initramfs-tools not found - not an initramfs-tools system"

check_acpi_override_preconditions
echo "    no blocking Secure Boot / lockdown state found"

if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "    would install $AML -> $STAGED_AML"
    echo "    would install $HOOK_SRC -> $HOOK_DST"
    echo "    would run: update-initramfs -u -k all"
    exit 0
fi

info "staging the table at $STAGED_AML"
install -d "$SRC_DIR"
install -m 0644 "$AML" "$STAGED_AML"
# Older versions of this installer pre-built this archive; the hook now builds
# it fresh on every run, so a stale copy must not be left behind.
rm -f "$LEGACY_CPIO"

info "installing the initramfs-tools hook"
install -d "$(dirname "$HOOK_DST")"
install -m 0755 "$HOOK_SRC" "$HOOK_DST"

info "rebuilding initramfs (update-initramfs -u -k all)"
rebuild_rc=0
if ! update-initramfs -u -k all; then
    warn "'update-initramfs -u -k all' failed - retrying for $(uname -r) only"
    update-initramfs -u -k "$(uname -r)" || rebuild_rc=1
fi

info "checking the generated initramfs"
check_initrd_for_table "/boot/initrd.img-$(uname -r)"

if [ "$rebuild_rc" -ne 0 ]; then
    die "some initramfs images could not be rebuilt. The override is staged, but only
     the running kernel's image (if any) is guaranteed to carry it. Re-run:
       sudo update-initramfs -u -k all"
fi

cat <<EOF

installed:
  table:  $STAGED_AML
  hook:   $HOOK_DST

Revert with:
  sudo $0 --uninstall
EOF
print_verify_steps
