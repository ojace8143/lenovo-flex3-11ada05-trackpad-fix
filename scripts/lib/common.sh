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

# check_kernel_config: warn if CONFIG_ACPI_TABLE_UPGRADE is definitely off.
# Returns 0 when fine (or undeterminable), 1 when the kernel cannot do this.
check_kernel_config() {
    local cfg
    if cfg="$(kernel_config_file)"; then
        if ! grep -qx 'CONFIG_ACPI_TABLE_UPGRADE=y' "$cfg"; then
            warn "$cfg does not enable CONFIG_ACPI_TABLE_UPGRADE=y - the override will be ignored."
            return 1
        fi
        return 0
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

# ensure_dropin FILE LINE
#   Idempotently add LINE to FILE, creating the parent directory if needed.
#   Never truncates an existing file: appends a marked block instead.
ensure_dropin() {
    local file="$1" line="$2" dir
    dir="$(dirname "$file")"

    if [ ! -d "$dir" ]; then
        install -d "$dir"
    fi

    if [ -e "$file" ] && grep -qxF "$line" "$file"; then
        echo "    $line already present in $file"
        return 0
    fi

    if [ -e "$file" ]; then
        printf '\n%s\n%s\n' "$DROPIN_MARKER" "$line" >> "$file"
    else
        printf '%s\n%s\n' "$DROPIN_MARKER" "$line" > "$file"
    fi
    echo "    added '$line' to $file"
}

# remove_dropin FILE LINE
#   Remove the marked block this project added, leaving anything else intact.
#   Refuses to touch a file that does not carry DROPIN_MARKER.
remove_dropin() {
    local file="$1" line="$2" tmp

    if [ ! -e "$file" ]; then
        return 0
    fi

    if ! grep -qF "$DROPIN_MARKER" "$file"; then
        warn "not removing $file (not written by this project; edit it yourself)"
        return 0
    fi

    tmp="$(mktemp)"
    grep -vF -e "$DROPIN_MARKER" -e "$line" "$file" > "$tmp" || true

    if [ -z "$(tr -d '[:space:]' < "$tmp")" ]; then
        rm -f "$file"
        echo "    removed $file"
    else
        cat "$tmp" > "$file"
        echo "    removed '$line' from $file"
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
