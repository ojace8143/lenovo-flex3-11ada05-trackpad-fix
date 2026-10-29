# shellcheck shell=bash
# Shared helpers for the lenovo-flex3-11ada05-trackpad-fix scripts.
#
# Usage (from a script in scripts/):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=SCRIPTDIR/lib/common.sh
#   . "$SCRIPT_DIR/lib/common.sh"
#
# This file deliberately does NOT set shell options: verify.sh runs without
# `set -e` because it must report every failed check, not stop at the first.

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Marker written into config drop-ins this project manages, so uninstall can
# tell "ours" from "the user's" without guessing.
readonly DROPIN_MARKER='# managed by lenovo-flex3-11ada05-trackpad-fix'

# Set by parse_args(); defaulted here so `set -u` callers can read them even
# before parsing.
OPT_UNINSTALL=0
OPT_DRY_RUN=0
OPT_HELP=0

warn() { printf 'warn: %s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# need CMD [HINT]
need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found${2:+ - $2}"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "must run as root:  sudo $0   (or: pkexec $0)"
    fi
}

# repo_root: absolute path of the repository this library lives in.
repo_root() { ( cd "$_COMMON_DIR/../.." && pwd ); }

# parse_args "<allowed>" "$@"
#   allowed is any combination of:
#     u  --uninstall      (OPT_UNINSTALL)
#     n  --dry-run        (OPT_DRY_RUN)
#     h  --help           (OPT_HELP)
# shellcheck disable=SC2034  # the OPT_* results are read by the sourcing script
parse_args() {
    local allowed="${1:-}"
    shift || true
    OPT_UNINSTALL=0
    OPT_DRY_RUN=0
    OPT_HELP=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)       OPT_HELP=1 ;;
            -u|--uninstall)  case "$allowed" in *u*) OPT_UNINSTALL=1 ;;
                                  *) die "unknown argument '$1' (try --help)" ;; esac ;;
            -n|--dry-run)    case "$allowed" in *n*) OPT_DRY_RUN=1 ;;
                                  *) die "unknown argument '$1' (try --help)" ;; esac ;;
            --)              shift; break ;;
            -*)              die "unknown argument '$1' (try --help)" ;;
            *)               die "unexpected argument '$1' (try --help)" ;;
        esac
        shift
    done

    if [ "$#" -gt 0 ]; then
        die "unexpected argument '$1' (try --help)"
    fi
}

# detect_distro: prints one of arch, debian, void, unknown.
detect_distro() {
    if command -v xbps-install >/dev/null 2>&1; then
        echo void
    elif command -v pacman >/dev/null 2>&1; then
        echo arch
    elif command -v apt-get >/dev/null 2>&1; then
        echo debian
    else
        echo unknown
    fi
}

# detect_initramfs: prints initramfs-tools, dracut, mkinitcpio or unknown.
#   Prefers whichever generator owns the running kernel's image, so a Debian or
#   Arch box that uses dracut is not mistaken for a stock one.
detect_initramfs() {
    local rel
    rel="$(uname -r)"

    if [ -e "/boot/initrd.img-$rel" ]; then
        echo initramfs-tools
        return
    fi
    if [ -e "/boot/initramfs-$rel.img" ]; then
        echo dracut
        return
    fi
    if [ -e /boot/initramfs-linux.img ] && command -v mkinitcpio >/dev/null 2>&1; then
        echo mkinitcpio
        return
    fi

    if [ -d /etc/dracut.conf.d ] || command -v dracut >/dev/null 2>&1; then
        echo dracut
        return
    fi
    if [ -d /etc/initramfs-tools ]; then
        echo initramfs-tools
        return
    fi
    if command -v mkinitcpio >/dev/null 2>&1; then
        echo mkinitcpio
        return
    fi
    echo unknown
}

# kernel_config_file: prints the path of the running kernel's config, if any.
kernel_config_file() {
    local rel f
    rel="$(uname -r)"
    for f in "/boot/config-$rel" "/usr/lib/modules/$rel/config" "/lib/modules/$rel/config"; do
        if [ -r "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

# kernel_config_source: prints wherever the running kernel's config can be read.
#   Arch (and other IKCONFIG_PROC kernels) ship no /boot/config-*, only
#   /proc/config.gz, so both have to be considered.
kernel_config_source() {
    local cfg
    if cfg="$(kernel_config_file)"; then
        printf '%s\n' "$cfg"
        return 0
    fi
    if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
        printf '%s\n' "/proc/config.gz"
        return 0
    fi
    return 1
}

# kernel_config_grep PATTERN: exit 0 if the kernel config has that exact line.
#   Returns 2 when the config cannot be read at all.
kernel_config_grep() {
    local pattern="$1" cfg
    if cfg="$(kernel_config_file)"; then
        grep -qx "$pattern" "$cfg"
        return
    fi
    if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
        zcat /proc/config.gz 2>/dev/null | grep -qx "$pattern"
        return
    fi
    return 2
}

# check_kernel_config: warn if CONFIG_ACPI_TABLE_UPGRADE is definitely off.
# Returns 0 when fine (or undeterminable), 1 when the kernel cannot do this.
check_kernel_config() {
    local src
    if src="$(kernel_config_source)"; then
        if kernel_config_grep 'CONFIG_ACPI_TABLE_UPGRADE=y'; then
            return 0
        fi
        warn "$src does not enable CONFIG_ACPI_TABLE_UPGRADE=y - the override will be ignored."
        return 1
    fi
    warn "cannot find the config for kernel $(uname -r); assuming CONFIG_ACPI_TABLE_UPGRADE=y"
    return 0
}

# check_acpi_override_preconditions: Secure Boot / lockdown / kernel config.
check_acpi_override_preconditions() {
    if command -v mokutil >/dev/null 2>&1 \
        && mokutil --sb-state 2>/dev/null | grep -qiE 'secure ?boot[^a-z]*enabled'; then
        die "Secure Boot is enabled - the kernel ignores ACPI table overrides.
     Disable Secure Boot in firmware setup (and clear pending MOK enrollments)."
    fi

    if [ -r /sys/kernel/security/lockdown ] \
        && ! grep -q '\[none\]' /sys/kernel/security/lockdown; then
        die "kernel lockdown is active ($(tr -s '\n' ' ' < /sys/kernel/security/lockdown)) -
     ACPI table overrides are blocked."
    fi

    check_kernel_config >/dev/null || true
}

# ensure_dropin FILE LINE [LINE...]
#   Idempotently add each LINE to FILE, creating the parent directory if needed.
#   Never truncates an existing file: appends one marked block instead.
ensure_dropin() {
    local file="$1"
    shift || true
    local dir line
    dir="$(dirname "$file")"

    [ "$#" -gt 0 ] || return 0

    if [ ! -d "$dir" ]; then
        install -d "$dir"
    fi

    local missing=()
    for line in "$@"; do
        if [ -e "$file" ] && grep -qxF "$line" "$file"; then
            echo "    '$line' already present in $file"
        else
            missing+=("$line")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    if [ -e "$file" ]; then
        printf '\n%s\n' "$DROPIN_MARKER" >> "$file"
    else
        printf '%s\n' "$DROPIN_MARKER" > "$file"
    fi
    for line in "${missing[@]}"; do
        printf '%s\n' "$line" >> "$file"
    done
    echo "    added to $file: ${missing[*]}"
}

# remove_dropin FILE LINE [LINE...]
#   Remove the marked block this project added, leaving anything else intact.
#   Refuses to touch a file that does not carry DROPIN_MARKER.
remove_dropin() {
    local file="$1"
    shift || true
    local tmp line args=()

    if [ ! -e "$file" ]; then
        return 0
    fi

    if ! grep -qF "$DROPIN_MARKER" "$file"; then
        warn "not removing $file (not written by this project; edit it yourself)"
        return 0
    fi

    args=(-e "$DROPIN_MARKER")
    for line in "$@"; do
        args+=(-e "$line")
    done

    tmp="$(mktemp)"
    grep -vxF "${args[@]}" "$file" > "$tmp" || true

    if [ -z "$(tr -d '[:space:]' < "$tmp")" ]; then
        rm -f "$file"
        echo "    removed $file"
    else
        cat "$tmp" > "$file"
        echo "    removed this project's lines from $file"
    fi
    rm -f "$tmp"
}

# initrd_contains_acpi_table IMG
#   0 = the table is in the initramfs, 1 = not found, 2 = cannot tell.
#   The kernel reads overrides from the leading *uncompressed* cpio, so the
#   tool-based listing is preferred; the dd fallback is a heuristic and is only
#   used when no cpio-aware lister is available.
initrd_contains_acpi_table() {
    local img="$1" needle='kernel/firmware/acpi/dsdt.aml'

    [ -r "$img" ] || return 2

    # Unified kernel images are PE binaries; no cpio tool can look inside.
    if head -c 2 "$img" 2>/dev/null | grep -qa '^MZ'; then
        return 2
    fi

    if command -v lsinitramfs >/dev/null 2>&1; then
        if lsinitramfs "$img" 2>/dev/null | grep -q "$needle"; then return 0; fi
        return 1
    fi
    if command -v lsinitrd >/dev/null 2>&1; then
        # dracut: lists the early (uncompressed) cpio as well.
        if lsinitrd "$img" 2>/dev/null | grep -q "$needle"; then return 0; fi
        return 1
    fi
    if command -v lsinitcpio >/dev/null 2>&1; then
        if lsinitcpio "$img" 2>/dev/null | grep -q "$needle"; then return 0; fi
        return 1
    fi

    if dd if="$img" bs=1M count=4 status=none 2>/dev/null | grep -qa "$needle"; then
        return 0
    fi
    return 1
}

# check_initrd_for_table IMG LABEL
#   Prints a PASS/WARN line; never fails the caller (even under `set -e`).
check_initrd_for_table() {
    local img="$1" label="${2:-initramfs}" rc
    if initrd_contains_acpi_table "$img"; then
        rc=0
    else
        rc=$?
    fi
    case "$rc" in
        0) echo "    OK: $label contains kernel/firmware/acpi/dsdt.aml" ;;
        1) warn "$label does NOT contain kernel/firmware/acpi/dsdt.aml - the override will not load" ;;
        *) echo "    (cannot inspect $label - verify after reboot with ./scripts/verify.sh)" ;;
    esac
    return 0
}

# check_boot_images_for_table
#   Find the initramfs/UKI images this machine actually boots and check them.
#   Needed because mkinitcpio presets name their output freely
#   (/boot/initramfs-linux.img, UKIs, ...), not initramfs-$(uname -r).img.
check_boot_images_for_table() {
    local image found=0
    for image in /boot/initramfs-*.img; do
        [ -e "$image" ] || continue
        found=1
        check_initrd_for_table "$image" "${image##*/}"
    done

    if [ "$found" -eq 0 ]; then
        for image in /boot/EFI/Linux/*.efi /efi/EFI/Linux/*.efi /boot/*.efi; do
            [ -e "$image" ] || continue
            found=1
            check_initrd_for_table "$image" "${image##*/}"
        done
    fi

    if [ "$found" -eq 0 ]; then
        echo "    (no initramfs image found under /boot - verify after reboot)"
    fi
    return 0
}

# check_aml_file FILE
#   Refuse to install something that is not a plausible DSDT, instead of
#   discovering it after a reboot.
check_aml_file() {
    local file="$1" signature size
    if [ ! -f "$file" ]; then
        die "no $file - run './scripts/build-dsdt.sh' first"
    fi
    signature="$(dd if="$file" bs=1 count=4 status=none 2>/dev/null)"
    if [ "$signature" != "DSDT" ]; then
        die "$file does not start with the 'DSDT' signature (got '${signature}')
     - rebuild it with './scripts/build-dsdt.sh'."
    fi
    size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
    if [ "$size" -le 1024 ]; then
        die "$file is only ${size} bytes - that is not a real DSDT; rebuild it."
    fi
}

# print_verify_steps: the shared "now reboot and check" footer.
print_verify_steps() {
    cat <<'EOF'

done. Reboot, then run:
  sudo ./scripts/verify.sh

or check by hand:
  sudo dmesg | grep -iE "acpi: (override|table upgrade)"
  ls /sys/bus/i2c/devices/ | grep -i msft
  grep -B2 -A6 "04F3:3072" /proc/bus/input/devices
EOF
}
