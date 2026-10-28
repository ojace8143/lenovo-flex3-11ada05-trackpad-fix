#!/usr/bin/env bash
# Build a patched DSDT from THIS machine's own ACPI tables.
# Output: build/dsdt.aml (+ build/acpi_override, a manual-fallback initrd cpio)
#
# Patch: IdeaPad Flex 3 11ADA05 touchpad TPD0 (_CRS / _DSM) - remove the
# embedded-controller dependency that breaks the ELAN 04F3:3072 touchpad on
# BIOS >= FPCN24WW. Bumps the DSDT OEM revision so the kernel applies it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO="$(repo_root)"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
PATCHER="$SCRIPT_DIR/patch-dsdt.py"
MARKER=".managed-by-build-dsdt"

usage() {
    cat <<'EOF'
Build a patched DSDT from this machine's firmware tables.

Usage:
  sudo ./scripts/build-dsdt.sh [options]

Options:
  -n, --dry-run   dump + decompile + patch, show the diff, stop before compiling
  -h, --help      show this help

Environment:
  BUILD_DIR       output directory (default: <repo>/build)

Requires root (acpidump reads firmware tables) and:
  acpidump, iasl (package: acpica / acpica-tools / acpica-utils),
  python3, cpio.
EOF
}

parse_args "nh" "$@"
if [ "$OPT_HELP" -eq 1 ]; then
    usage
    exit 0
fi

pkg_hint() {
    case "$(detect_distro)" in
        arch)   echo "pacman -S acpica python3 cpio" ;;
        debian) echo "apt install acpica-tools python3 cpio" ;;
        void)   echo "xbps-install -S acpica-utils python3 cpio" ;;
        *)      echo "install your distro's acpica/python3/cpio packages" ;;
    esac
}

require_root
for tool in acpidump iasl python3 cpio; do
    need "$tool" "$(pkg_hint)"
done

# Refuse to nuke a directory we did not create.
if [ -d "$BUILD_DIR" ] && [ -n "$(ls -A "$BUILD_DIR" 2>/dev/null)" ] \
    && [ ! -e "$BUILD_DIR/$MARKER" ]; then
    die "$BUILD_DIR exists and was not created by this script.
     Remove it yourself, or set BUILD_DIR=/some/other/directory."
fi
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/tables"
: > "$BUILD_DIR/$MARKER"

model="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)"
case "$model" in
    ""|*Flex*3*|*82G4*) ;;
    *) warn "this machine reports '$model' - not an IdeaPad Flex 3 11ADA05; continuing anyway" ;;
esac

cd "$BUILD_DIR/tables"

info "dumping ACPI tables (acpidump -b)"
acpidump -b >/dev/null 2>&1 || die "acpidump failed - are you root?"
[ -f dsdt.dat ] || die "acpidump produced no dsdt.dat"

info "decompiling DSDT (using SSDTs as externals where present)"
shopt -s nullglob
ssdts=(ssdt*.dat)
shopt -u nullglob
if [ "${#ssdts[@]}" -gt 0 ]; then
    iasl -e "${ssdts[@]}" -d dsdt.dat >/dev/null 2>&1 \
        || warn "iasl reported problems while resolving SSDT externals - continuing"
else
    iasl -d dsdt.dat >/dev/null 2>&1 \
        || warn "iasl reported problems while decompiling - continuing"
fi
[ -f dsdt.dsl ] || die "iasl produced no dsdt.dsl (decompilation failed)"
cp dsdt.dsl "$BUILD_DIR/dsdt-orig.dsl"

info "patching TPD0 (_CRS/_DSM, EC-independent)"
if [ "$OPT_DRY_RUN" -eq 1 ]; then
    python3 "$PATCHER" --diff dsdt.dsl | tee "$BUILD_DIR/dsdt.patch"
    echo
    echo "dry run: $BUILD_DIR/dsdt.patch holds the proposed change; nothing compiled."
    exit 0
fi
python3 "$PATCHER" dsdt.dsl

info "compiling"
LOG="$BUILD_DIR/iasl.log"
if ! iasl -tc dsdt.dsl >"$LOG" 2>&1; then
    grep -E 'Error|error' "$LOG" >&2 || cat "$LOG" >&2
    die "iasl failed to compile the patched DSDT (full log: $LOG)"
fi
grep -E 'Compilation (successful|complete)' "$LOG" || true
if ! grep -q '0 Errors' "$LOG"; then
    cat "$LOG" >&2
    die "iasl reported errors (full log: $LOG)"
fi
[ -f dsdt.aml ] || die "no dsdt.aml produced"

info "verifying the compiled AML (not just the source)"
mkdir -p "$BUILD_DIR/verify"
cp dsdt.aml "$BUILD_DIR/verify/"
if ! ( cd "$BUILD_DIR/verify" && iasl -d dsdt.aml >/dev/null 2>&1 ); then
    die "could not disassemble the built dsdt.aml - refusing to install an unverified table"
fi
[ -f "$BUILD_DIR/verify/dsdt.dsl" ] || die "disassembly produced no dsdt.dsl"
python3 "$PATCHER" --verify-only "$BUILD_DIR/verify/dsdt.dsl"

info "building the manual-fallback initrd cpio"
mkdir -p "$BUILD_DIR/cpio/kernel/firmware/acpi"
cp dsdt.aml "$BUILD_DIR/cpio/kernel/firmware/acpi/dsdt.aml"
( cd "$BUILD_DIR/cpio" && find kernel -type f | cpio -o -H newc --quiet ) \
    > "$BUILD_DIR/acpi_override"
chmod 0644 "$BUILD_DIR/dsdt.aml" "$BUILD_DIR/acpi_override"

# Everything above ran as root; hand the build tree back to the invoking user.
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    chown -R "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "$BUILD_DIR" 2>/dev/null || true
fi

echo
echo "done:"
printf '  %-40s %s bytes\n' "$BUILD_DIR/dsdt.aml" "$(stat -c%s "$BUILD_DIR/dsdt.aml")"
printf '  %-40s %s bytes\n' "$BUILD_DIR/acpi_override" "$(stat -c%s "$BUILD_DIR/acpi_override")"
printf '  %-40s %s\n' "$BUILD_DIR/dsdt-orig.dsl" "(your firmware's original, for diffing)"
printf '  %-40s %s\n' "$BUILD_DIR/iasl.log" "(compiler output)"

cat <<'EOF'

next (pick one):
  sudo ./scripts/install-omarchy.sh     # Omarchy / limine / UKI
  sudo ./scripts/install-arch.sh        # plain Arch (mkinitcpio)
  sudo ./scripts/install-ubuntu.sh      # Linux Mint / Ubuntu / Debian
  sudo ./scripts/install-void.sh        # Void Linux (dracut)

other distros: see docs/manual-install.md (uses build/acpi_override).
EOF
