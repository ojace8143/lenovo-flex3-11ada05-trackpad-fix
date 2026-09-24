#!/usr/bin/env bash
# Build a patched DSDT from THIS machine's own ACPI tables.
# Output: build/dsdt.aml (+ build/acpi_override, a ready-made initrd cpio)
#
# Patch: IdeaPad Flex 3 11ADA05 touchpad TPD0 (_CRS / _DSM) — remove the
# embedded-controller dependency that breaks the ELAN 04F3:3072 touchpad on
# BIOS >= FPCN24WW. Bumps the DSDT OEM revision so the kernel applies it.
set -euo pipefail

BUILD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' missing (Debian/Ubuntu/Mint: sudo apt install acpica-tools | Arch/Omarchy: sudo pacman -S acpica)"; }

for t in iasl acpidump python3; do need "$t"; done
[ "$EUID" -eq 0 ] || { echo "run as root:  sudo $0   (or: pkexec $0)"; exit 1; }

rm -rf "$BUILD"; mkdir -p "$BUILD/tables"
cd "$BUILD/tables"

echo "==> dumping ACPI tables (acpidump -b)"
acpidump -b >/dev/null 2>&1
[ -f dsdt.dat ] || die "acpidump produced no dsdt.dat"

echo "==> decompiling DSDT (SSDTs as externals)"
iasl -e ssdt*.dat -d dsdt.dat >/dev/null 2>&1 || true
[ -f dsdt.dsl ] || die "decompilation failed"
cp dsdt.dsl "$BUILD/dsdt-orig.dsl"

echo "==> patching TPD0 (_CRS/_DSM, EC-independent)"
python3 - "$BUILD/tables/dsdt.dsl" <<'PY'
import re, sys

path = sys.argv[1]
src  = open(path, encoding="utf-8", errors="surrogateescape").read()

start = src.find("        Device (TPD0)")
if start < 0:
    sys.exit("error: 'Device (TPD0)' not found in DSDT")

i, depth, end = src.index("{", start), 0, -1
while i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
    i += 1
if end < 0:
    sys.exit("error: TPD0 block not closed (bad decompilation?)")

block = src[start:end]

old_dsm = r"""                        Case (0x01)
                        {
                            If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
                            {
                                Return (0x01)
                            }

                            If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))
                            {
                                Return (0x20)
                            }
                        }"""
new_dsm = r"""                        Case (0x01)
                        {
                            Return (0x01)
                        }"""

old_crs = r"""                If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
                {
                    Name (SBFB, ResourceTemplate ()
                    {
                        I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
                            AddressingMode7Bit, "\\_SB.I2CD",
                            0x00, ResourceConsumer, , Exclusive,
                            )
                    })
                    Return (ConcatenateResTemplate (SBFB, SBFG))
                }

                If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))
                {
                    Name (SBFC, ResourceTemplate ()
                    {
                        I2cSerialBusV2 (0x002C, ControllerInitiated, 0x00061A80,
                            AddressingMode7Bit, "\\_SB.I2CD",
                            0x00, ResourceConsumer, , Exclusive,
                            )
                    })
                    Return (ConcatenateResTemplate (SBFC, SBFG))
                }"""
new_crs = r"""                Name (SBFB, ResourceTemplate ()
                {
                    I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
                        AddressingMode7Bit, "\\_SB.I2CD",
                        0x00, ResourceConsumer, , Exclusive,
                        )
                })
                Return (ConcatenateResTemplate (SBFB, SBFG))"""

if "TPTY" in block:
    for name, old, new in (("_DSM", old_dsm, new_dsm), ("_CRS", old_crs, new_crs)):
        n = block.count(old)
        if n != 1:
            sys.exit(f"error: {name} pattern found {n}x in TPD0 (expected 1). "
                     f"Different BIOS variant? Patch manually.")
        block = block.replace(old, new)
        print(f"    {name} patched")

    if "TPTY" in block:
        sys.exit("error: TPD0 still contains TPTY after patching")
else:
    # Already patched (override active and acpidump returned the patched table).
    if "I2cSerialBusV2 (0x0015" not in block:
        sys.exit("error: TPD0 has no EC dependency and no 0x15 I2C resource "
                 "- unknown BIOS variant.")
    print("    TPD0 already patched (override active) - used as-is")

src = src[:start] + block + src[end:]

m = re.search(r'(DefinitionBlock \("", "DSDT", \d+, "[^"]*", "[^"]*", )(0x[0-9A-Fa-f]+)(\))', src)
if not m:
    sys.exit("error: DefinitionBlock line not found")
old_rev = int(m.group(2), 16)
new_rev = old_rev + 0x1000
src = src[:m.start()] + m.group(1) + f"0x{new_rev:08X}" + m.group(3) + src[m.end():]
print(f"    OEM revision 0x{old_rev:08X} -> 0x{new_rev:08X}")

open(path, "w", encoding="utf-8", errors="surrogateescape").write(src)
PY

echo "==> compiling"
LOG="$(iasl -tc dsdt.dsl 2>&1)" || die "compile failed"
echo "$LOG" | grep -E "Compilation successful|Error" || true
echo "$LOG" | grep -q "0 Errors" || die "compile reported errors"
[ -f dsdt.aml ] || die "no dsdt.aml produced"

echo "==> sanity check (verify loop)"
mkdir -p "$BUILD/verify"
cp dsdt.aml "$BUILD/verify/"
( cd "$BUILD/verify" && iasl -d dsdt.aml >/dev/null 2>&1 )
if sed -n '/Device (TPD0)/,/^        }$/p' "$BUILD/verify/dsdt.dsl" | grep -q TPTY; then
    die "TPD0 still references TPTY - patch incomplete"
fi
echo "    OK: no EC dependency left in TPD0"

echo "==> building initrd cpio"
mkdir -p "$BUILD/cpio/kernel/firmware/acpi"
cp dsdt.aml "$BUILD/cpio/kernel/firmware/acpi/dsdt.aml"
( cd "$BUILD/cpio" && find kernel | cpio -H newc --create 2>/dev/null ) > "$BUILD/acpi_override"

echo
echo "done:"
echo "  $BUILD/dsdt.aml        ($(stat -c%s "$BUILD/dsdt.aml") bytes)"
echo "  $BUILD/acpi_override   ($(stat -c%s "$BUILD/acpi_override") bytes)"
echo
echo "next: sudo ./scripts/install-omarchy.sh   (or install-arch.sh / install-ubuntu.sh)"
