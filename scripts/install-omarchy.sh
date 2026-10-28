#!/usr/bin/env bash
# Install the patched DSDT on Omarchy (Arch + limine + UKI).
#
# Omarchy keeps its mkinitcpio hook list in a drop-in config
# (/etc/mkinitcpio.conf.d/omarchy_hooks.conf) that OVERRIDES
# /etc/mkinitcpio.conf. Drop-in files source in alphabetical order, so our
# appending drop-in must sort AFTER omarchy_hooks.conf -> "omarchy_zz_*".
#
# Drop-in files are appended to, never rewritten: if you already have a file at
# that path, your contents survive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO="$(repo_root)"
AML="$REPO/build/dsdt.aml"
STAGE_DIR="/etc/initcpio/acpi_override"
STAGE_AML="$STAGE_DIR/dsdt.aml"
DROPIN="/etc/mkinitcpio.conf.d/omarchy_zz_acpi_override.conf"
HOOK_LINE='HOOKS+=(acpi_override)'
MKINITCPIO_HOOK="/usr/lib/initcpio/install/acpi_override"

usage() {
    cat <<'EOF'
Install (or remove) the patched DSDT on Omarchy (mkinitcpio + limine UKI).

Usage:
  sudo ./scripts/install-omarchy.sh [options]

Options:
  -u, --uninstall   remove the override and rebuild the UKI(s)
  -n, --dry-run     show what would happen, change nothing
  -h, --help        show this help

Run ./scripts/build-dsdt.sh first (it writes build/dsdt.aml).
EOF
}

rebuild_uki() {
    if command -v limine-mkinitcpio >/dev/null 2>&1; then
        info "rebuilding UKI(s) (limine-mkinitcpio)"
        limine-mkinitcpio
    else
        info "limine-mkinitcpio not found - rebuilding with mkinitcpio -P"
        mkinitcpio -P
    fi
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
        echo "    would rebuild the UKI(s)"
        exit 0
    fi
    remove_dropin "$DROPIN" "$HOOK_LINE"
    rm -f "$STAGE_AML"
    rmdir "$STAGE_DIR" 2>/dev/null || true
    rebuild_uki
    echo
    echo "done. The override is gone; reboot to return to the firmware table."
    exit 0
fi

[ "$OPT_DRY_RUN" -eq 1 ] || require_root
[ -f "$AML" ] || die "no $AML - run './scripts/build-dsdt.sh' first"
if [ ! -f "$MKINITCPIO_HOOK" ]; then
    die "this mkinitcpio has no 'acpi_override' hook ($MKINITCPIO_HOOK is missing).
     Update mkinitcpio, or use the manual cpio method in docs/manual-install.md."
fi

info "checking preconditions"
check_acpi_override_preconditions
echo "    no blocking Secure Boot / lockdown state found"

if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "    would install $AML -> $STAGE_AML"
    echo "    would add '$HOOK_LINE' to $DROPIN"
    echo "    would rebuild the UKI(s)"
    exit 0
fi

info "staging the table"
install -d "$STAGE_DIR"
install -m 0644 "$AML" "$STAGE_AML"

info "enabling the acpi_override hook"
ensure_dropin "$DROPIN" "$HOOK_LINE"

rebuild_uki

echo
echo "installed:"
echo "  table:  $STAGE_AML"
echo "  hook:   $HOOK_LINE in $DROPIN"
echo
echo "note: the UKI is a PE binary, so its contents cannot be inspected here."
echo "      verification happens after reboot:"

print_verify_steps
