#!/usr/bin/env bash
# Post-reboot verification that the DSDT override and the touchpad are live.
#
# Exit status: 0 = the touchpad checks passed, 1 = something is broken,
# 2 = usage error. Warnings (e.g. "cannot read dmesg") do not fail the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO="$(repo_root)"
BUILT_AML="$REPO/build/dsdt.aml"

usage() {
    cat <<'EOF'
Verify that the patched DSDT is active and the touchpad is present.

Usage:
  sudo ./scripts/verify.sh [options]

Options:
  -h, --help   show this help

Exit status: 0 ok, 1 broken, 2 usage error.
EOF
}

parse_args "h" "$@"
if [ "$OPT_HELP" -eq 1 ]; then
    usage
    exit 0
fi

FAILURES=0
ROOT_SKIPPED=0

pass() { printf '  OK    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  skip  %s\n' "$*"; }
# skip_root: a check that would work if we were root.
skip_root() { printf '  skip  %s\n' "$*"; ROOT_SKIPPED=$((ROOT_SKIPPED + 1)); }

echo "=== 1. boot-time restrictions ==="
if command -v mokutil >/dev/null 2>&1; then
    sb_state="$(mokutil --sb-state 2>/dev/null || true)"
    case "$sb_state" in
        *enabled*) fail "Secure Boot is enabled - the kernel ignores ACPI overrides" ;;
        *disabled*) pass "Secure Boot disabled" ;;
        *) skip "mokutil returned no usable answer" ;;
    esac
else
    skip "mokutil not installed"
fi

lockdown="$(cat /sys/kernel/security/lockdown 2>/dev/null || true)"
case "$lockdown" in
    *"[none]"*) pass "kernel lockdown: none" ;;
    "")         skip "no lockdown interface on this kernel" ;;
    *)          fail "kernel lockdown is active ($lockdown) - overrides are blocked" ;;
esac

echo "=== 2. kernel support ==="
cfg_source="$(kernel_config_source || true)"
if [ -n "$cfg_source" ]; then
    if kernel_config_grep 'CONFIG_ACPI_TABLE_UPGRADE=y'; then
        pass "CONFIG_ACPI_TABLE_UPGRADE=y in $cfg_source"
    else
        fail "CONFIG_ACPI_TABLE_UPGRADE=y missing from $cfg_source"
    fi
else
    skip "no kernel config found for $(uname -r)"
fi

echo "=== 3. ACPI table override ==="
dmesg_text=""
if dmesg >/dev/null 2>&1; then
    dmesg_text="$(dmesg 2>/dev/null)"
elif [ "$(id -u)" -ne 0 ] && sudo -n dmesg >/dev/null 2>&1; then
    dmesg_text="$(sudo -n dmesg 2>/dev/null)"
fi

if [ -z "$dmesg_text" ]; then
    skip_root "cannot read dmesg (run this script as root)"
else
    override_line="$(printf '%s\n' "$dmesg_text" \
        | grep -iE 'table upgrade|logical table override' | head -n 1)"
    if [ -n "$override_line" ]; then
        pass "override applied: $(printf '%s' "$override_line" | sed 's/^\[[^]]*\] *//')"
    else
        fail "no 'Table Upgrade' / 'Logical table override' line in dmesg"
    fi
fi

live_dsdt="/sys/firmware/acpi/tables/DSDT"
if [ ! -r "$live_dsdt" ]; then
    skip_root "cannot read $live_dsdt (run as root)"
elif [ ! -f "$BUILT_AML" ]; then
    skip "no $BUILT_AML to compare against (rebuild to enable this check)"
else
    live_hash="$(sha256sum "$live_dsdt" 2>/dev/null | cut -d' ' -f1)"
    built_hash="$(sha256sum "$BUILT_AML" | cut -d' ' -f1)"
    if [ -n "$live_hash" ] && [ "$live_hash" = "$built_hash" ]; then
        pass "loaded DSDT is exactly build/dsdt.aml"
    else
        fail "loaded DSDT differs from build/dsdt.aml - the override is not active"
    fi
fi

echo "=== 4. touchpad hardware ==="
i2c_dev=""
for dev in /sys/bus/i2c/devices/*MSFT0001*; do
    if [ -e "$dev" ]; then
        i2c_dev="${dev##*/}"
        break
    fi
done
if [ -n "$i2c_dev" ]; then
    pass "i2c device present: $i2c_dev"
else
    fail "no MSFT0001 i2c device under /sys/bus/i2c/devices"
fi

hid_dev=""
for dev in /sys/bus/hid/devices/*04F3:3072*; do
    if [ -e "$dev" ]; then
        hid_dev="${dev##*/}"
        break
    fi
done
if [ -n "$hid_dev" ]; then
    pass "HID device present: $hid_dev"
else
    fail "no 04F3:3072 HID device under /sys/bus/hid/devices"
fi

# The touchpad's block in /proc/bus/input/devices. The "I:" line prints the HID
# IDs in lowercase (Vendor=04f3 Product=3072) while the "N: Name=" line has the
# uppercase 04F3:3072, so match either.
touchpad_block="$(awk 'BEGIN { RS = ""; ORS = "\n" }
    /04F3:3072/ || (/Vendor=04f3/ && /Product=3072/) { print; exit }' \
    /proc/bus/input/devices 2>/dev/null)"

if [ -n "$touchpad_block" ]; then
    tp_name="$(printf '%s\n' "$touchpad_block" | sed -n 's/^N: Name="\(.*\)"$/\1/p')"
    tp_handlers="$(printf '%s\n' "$touchpad_block" | sed -n 's/^H: Handlers=//p')"
    tp_event="$(printf '%s\n' "$tp_handlers" | tr ' ' '\n' | grep -m1 '^event' || true)"
    if [ -n "$tp_event" ]; then
        pass "input device bound: ${tp_name:-?} (/dev/input/$tp_event)"
    else
        pass "input device bound: ${tp_name:-?}"
    fi
else
    fail "04F3:3072 does not appear in /proc/bus/input/devices"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "RESULT: $FAILURES check(s) failed."
    echo "See README.md -> Troubleshooting, and docs/diagnosis.md."
    exit 1
fi

if [ "$ROOT_SKIPPED" -gt 0 ]; then
    echo "RESULT: hardware checks passed, but $ROOT_SKIPPED override check(s) needed root."
    echo "Re-run with sudo to confirm the patched table is actually loaded:"
    echo "  sudo ./scripts/verify.sh"
    exit 0
fi

echo "RESULT: all checks passed. The touchpad should work."
exit 0
