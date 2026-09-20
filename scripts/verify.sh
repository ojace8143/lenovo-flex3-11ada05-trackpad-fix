#!/usr/bin/env bash
# Post-reboot verification that the DSDT override and touchpad are live.
set -u

echo "--- 1. ACPI Table Upgrade in dmesg (needs root) ---"
sudo dmesg 2>/dev/null | grep -i "table upgrade" || echo "  (nothing - check as root)"

echo "--- 2. touchpad i2c device ---"
ls /sys/bus/i2c/devices/ 2>/dev/null | grep -i msft || echo "  NOT FOUND"

echo "--- 3. input devices ---"
grep -H "Touchpad" /proc/bus/input/devices 2>/dev/null || echo "  no touchpad input device"

echo "--- 4. lock/sb (must be none/disabled) ---"
cat /sys/kernel/security/lockdown 2>/dev/null
mokutil --sb-state 2>/dev/null || true