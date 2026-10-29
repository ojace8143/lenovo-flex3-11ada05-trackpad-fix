#!/usr/bin/env bash
# Void Linux entry point. dracut is Void's initramfs generator, so the generic
# dracut installer is all that is needed; this name is kept because the README
# and earlier versions of the repo point at it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Void Linux entry point - using the generic dracut installer."
    echo
fi

exec "$SCRIPT_DIR/install-dracut.sh" "$@"
