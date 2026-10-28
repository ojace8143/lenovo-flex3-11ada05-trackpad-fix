#!/usr/bin/env python3
"""Patch the IdeaPad Flex 3 11ADA05 DSDT so TPD0 stops depending on the EC.

On BIOS >= FPCN24WW `TPD0._CRS` / `TPD0._DSM` return their resources only when
the embedded-controller register `TPTY` already reads 0x01. Linux walks the
table before the EC reports that value, so the ELAN 04F3:3072 touchpad never
gets an I2C resource and no input device is created.

This tool rewrites those two methods so they are unconditional and bumps the
DSDT OEM revision so the kernel accepts the table as an override.

Patching strategy
-----------------
1. Exact match against the known iasl output for this machine (bit-identical
   result to the original inline heredoc in scripts/build-dsdt.sh).
2. Structural fallback: locate `Device (TPD0)`, then `Method (_CRS)` /
   `Method (_DSM)` by brace matching, and replace just the EC-gated branches.
   This survives whitespace/formatting differences between iasl versions.

Anything it does not understand is refused with a non-zero exit code - it
never guesses, because a wrong table is worse than no table.

Exit codes: 0 ok, 1 I/O error, 2 usage, 3 unsupported/unknown table.

Only the standard library is used, so it runs on any distro with python3.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from dataclasses import dataclass
from pathlib import Path

EXIT_OK = 0
EXIT_IO = 1
EXIT_USAGE = 2
EXIT_UNSUPPORTED = 3

# ACPI path as iasl writes it: the backslash is escaped inside ASL strings.
I2C_PATH = r'"\\_SB.I2CD"'

# --- known-good iasl output on this machine (exact-match fast path) ---------
# Keep these byte-identical to what scripts/build-dsdt.sh used to contain.
EXACT_DSM_OLD = r"""                        Case (0x01)
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

EXACT_DSM_NEW = r"""                        Case (0x01)
                        {
                            Return (0x01)
                        }"""

EXACT_CRS_OLD = r"""                If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
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

EXACT_CRS_NEW = r"""                Name (SBFB, ResourceTemplate ()
                {
                    I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
                        AddressingMode7Bit, "\\_SB.I2CD",
                        0x00, ResourceConsumer, , Exclusive,
                        )
                })
                Return (ConcatenateResTemplate (SBFB, SBFG))"""

DEFINITION_RE = re.compile(
    r'(DefinitionBlock\s*\(\s*"[^"]*"\s*,\s*"DSDT"\s*,[^,]*,[^,]*,[^,]*,\s*)'
    r'(0x[0-9A-Fa-f]+)(\s*\))'
)


def int_literal(value: int) -> str:
    """Regex matching an ASL integer constant in every form iasl may print.

    The disassembler renders small constants as keywords: `Return (0x01)` from
    our patcher comes back as `Return (One)`, and `Zero`/`Ones` for 0/0xFFFFFFFF.
    Resource addresses may come back in decimal. All of these mean the same
    thing, so verification must accept all of them.
    """
    alternatives = [rf"0x0*{value:X}", str(value)]
    if value == 0:
        alternatives.append("Zero")
    elif value == 1:
        alternatives.append("One")
    elif value == 0xFFFFFFFF:
        alternatives.append("Ones")
    return "(?:" + "|".join(alternatives) + ")"


class PatchError(Exception):
    """The table is not something we know how to patch."""

    def __init__(self, message: str, code: int = EXIT_UNSUPPORTED) -> None:
        super().__init__(message)
        self.code = code


@dataclass
class Block:
    start: int       # index of the leading keyword
    body_start: int  # index of '{'
    end: int         # index just past '}'


# --- low-level ASL scanning -------------------------------------------------

def match_brace(text: str, open_index: int) -> int:
    """Return the index of the '}' matching text[open_index] == '{'."""
    if text[open_index] != "{":
        raise PatchError(f"internal: expected '{{' at offset {open_index}")
    depth = 0
    for i in range(open_index, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
    raise PatchError("unbalanced braces - is this really iasl output?")


def open_brace_after(text: str, index: int) -> int:
    brace = text.find("{", index)
    if brace < 0:
        raise PatchError("no '{' found after statement")
    return brace


def line_indent(text: str, index: int) -> str:
    line_start = text.rfind("\n", 0, index) + 1
    return re.match(r"[ \t]*", text[line_start:index]).group(0)


def line_number(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def find_block(text: str, pattern: str, what: str,
               start: int = 0, end: int | None = None) -> Block:
    span_end = len(text) if end is None else end
    match = re.compile(pattern).search(text, start, span_end)
    if not match:
        raise PatchError(f"{what} not found")
    brace = open_brace_after(text, match.end())
    return Block(match.start(), brace, match_brace(text, brace) + 1)


def case_blocks(body: str, value: int) -> list[tuple[int, int]]:
    """(body_start, body_end) of every `Case (value)` block in `body`."""
    blocks: list[tuple[int, int]] = []
    pattern = r"Case\s*\(\s*" + int_literal(value) + r"\s*\)"
    for match in re.finditer(pattern, body):
        brace = open_brace_after(body, match.end())
        blocks.append((brace + 1, match_brace(body, brace)))
    return blocks


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def first_arg_matches(arguments: str, value: int) -> bool:
    """True if the first macro argument (before the first comma) is `value`."""
    first = strip_comments(arguments.split(",", 1)[0]).strip()
    if not first:
        return False
    if first in ("Zero",):
        return value == 0
    if first in ("One",):
        return value == 1
    if first in ("Ones",):
        return value == 0xFFFFFFFF
    try:
        return int(first, 0) == value
    except ValueError:
        return False


def has_i2c_address(body: str, address: int) -> bool:
    """True if body has an I2C serial-bus descriptor at `address`.

    iasl prints the macro as I2cSerialBusV2 or I2cSerialBus depending on the
    descriptor length, and the address as hex or decimal, so neither the name
    suffix nor the radix can be relied on.
    """
    for match in re.finditer(r"I2cSerialBus(?:V2)?\s*\(", body):
        window = body[match.end():match.end() + 120]
        if first_arg_matches(window, address):
            return True
    return False


def find_device(text: str, name: str = "TPD0") -> Block:
    return find_block(text, rf"\bDevice\s*\(\s*{re.escape(name)}\s*\)",
                      f"'Device ({name})'")


def find_method_in(device_body: str, name: str) -> Block:
    return find_block(device_body, rf"\bMethod\s*\(\s*{re.escape(name)}\s*,",
                      f"'Method ({name})' inside TPD0")


def braced_statements(body: str,
                      keywords: tuple[str, ...] = ("If", "ElseIf", "Case", "Switch")) -> list[tuple[int, int, str]]:
    """Spans of depth-0 braced statements (start, end, keyword) inside body."""
    spans: list[tuple[int, int, str]] = []
    depth = 0
    i = 0
    n = len(body)

    while i < n:
        ch = body[i]
        if ch == "{":
            depth += 1
            i += 1
            continue
        if ch == "}":
            depth -= 1
            i += 1
            continue

        if depth == 0:
            matched = False
            for keyword in keywords:
                if not body.startswith(keyword, i):
                    continue
                previous = body[i - 1] if i else " "
                following = body[i + len(keyword):i + len(keyword) + 1]
                if previous.isalnum() or previous == "_":
                    continue
                if following and (following.isalnum() or following == "_"):
                    continue
                brace = open_brace_after(body, i)
                end = match_brace(body, brace)
                spans.append((i, end + 1, keyword))
                i = end + 1
                matched = True
                break
            if matched:
                continue

        i += 1

    return spans


# --- the two patches --------------------------------------------------------

def render_crs(indent: str) -> str:
    return (
        "Name (SBFB, ResourceTemplate ()\n"
        f"{indent}{{\n"
        f"{indent}    I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,\n"
        f"{indent}        AddressingMode7Bit, {I2C_PATH},\n"
        f"{indent}        0x00, ResourceConsumer, , Exclusive,\n"
        f"{indent}        )\n"
        f"{indent}}})\n"
        f"{indent}Return (ConcatenateResTemplate (SBFB, SBFG))"
    )


def plan_crs(device_body: str) -> tuple[tuple[int, int, str] | None, list[str]]:
    """Return ((start, end, replacement) | None, notes) relative to device_body."""
    notes: list[str] = []

    count = device_body.count(EXACT_CRS_OLD)
    if count == 1:
        start = device_body.index(EXACT_CRS_OLD)
        notes.append("_CRS: EC-gated branches removed (exact match)")
        return (start, start + len(EXACT_CRS_OLD), EXACT_CRS_NEW), notes
    if count > 1:
        raise PatchError(
            f"TPD0._CRS: the known EC-gated block appears {count}x (expected 1) "
            "- different BIOS variant? Patch manually.")

    crs = find_method_in(device_body, "_CRS")
    body = device_body[crs.body_start + 1:crs.end - 1]

    spans = braced_statements(body, ("If", "ElseIf"))
    gated = [s for s in spans if "TPTY" in body[s[0]:s[1]]]

    if not gated:
        notes.append("_CRS: already EC-independent (left as-is)")
        return None, notes

    first, last = gated[0], gated[-1]
    for span in spans:
        if first[0] <= span[0] <= last[1] and span not in gated:
            raise PatchError(
                "TPD0._CRS: an unrelated statement sits between the EC-gated "
                f"branches (line {line_number(device_body, crs.body_start + span[0])})")

    if body[last[1]:].strip():
        raise PatchError(
            "TPD0._CRS: statements follow the EC-gated branches "
            f"(line {line_number(device_body, crs.body_start + last[1])}) "
            "- unsupported layout")

    if "SBFG" not in device_body:
        raise PatchError("TPD0: no SBFG (GPIO interrupt) resource found - "
                         "cannot rebuild _CRS")

    indent = line_indent(body, first[0]) or "    "
    start = crs.body_start + 1 + first[0]
    end = crs.body_start + 1 + last[1]
    notes.append("_CRS: EC-gated branches removed (structural match)")
    return (start, end, render_crs(indent)), notes


def plan_dsm(device_body: str) -> tuple[tuple[int, int, str] | None, list[str]]:
    notes: list[str] = []

    count = device_body.count(EXACT_DSM_OLD)
    if count == 1:
        start = device_body.index(EXACT_DSM_OLD)
        notes.append("_DSM: EC-gated Case (0x01) made unconditional (exact match)")
        return (start, start + len(EXACT_DSM_OLD), EXACT_DSM_NEW), notes
    if count > 1:
        raise PatchError(
            f"TPD0._DSM: the known EC-gated Case (0x01) appears {count}x "
            "(expected 1) - different BIOS variant? Patch manually.")

    dsm = find_method_in(device_body, "_DSM")
    body = device_body[dsm.body_start + 1:dsm.end - 1]

    blocks = case_blocks(body, 1)
    if not blocks:
        raise PatchError("TPD0._DSM: no Case (0x01) - unsupported layout")

    # Firmware often has more than one selector equal to 1 in _DSM (e.g. a
    # function-0 buffer response before the EC-gated one), so pick the case that
    # actually contains the EC dependency instead of the first match.
    for case_start, case_close in blocks:
        case_body = body[case_start:case_close]
        spans = braced_statements(case_body, ("If", "ElseIf"))
        gated = [s for s in spans if "TPTY" in case_body[s[0]:s[1]]]
        if not gated:
            continue

        first, last = gated[0], gated[-1]
        for span in spans:
            if first[0] <= span[0] <= last[1] and span not in gated:
                raise PatchError(
                    "TPD0._DSM Case (0x01): an unrelated statement sits between "
                    f"the EC-gated branches (line {line_number(device_body, dsm.body_start + case_start + span[0])})")

        start = dsm.body_start + 1 + case_start + first[0]
        end = dsm.body_start + 1 + case_start + last[1]
        notes.append("_DSM: EC-gated Case (0x01) made unconditional (structural match)")
        return (start, end, "Return (0x01)"), notes

    notes.append("_DSM: no EC-gated Case (0x01) (left as-is)")
    return None, notes


def bump_oem_revision(src: str) -> tuple[str, str]:
    match = DEFINITION_RE.search(src)
    if not match:
        raise PatchError("DefinitionBlock header not found - cannot bump OEM revision")
    old = int(match.group(2), 16)
    new = old + 0x1000
    if new > 0xFFFFFFFF:
        raise PatchError(f"OEM revision 0x{old:08X} is too large to bump")
    patched = src[:match.start(2)] + f"0x{new:08X}" + src[match.end(2):]
    return patched, f"OEM revision 0x{old:08X} -> 0x{new:08X}"


# --- verification -----------------------------------------------------------

def verify(src: str, *, strict: bool = True) -> tuple[list[str], list[str]]:
    """Check a TPD0 table.

    Returns (problems, warnings). `strict=True` is used on our own patched
    source, where the exact resource spelling is known. `strict=False` is used
    on a disassembly of the compiled AML, where iasl may render resource
    templates differently; there, resource-shape findings are warnings because
    the post-reboot check is the authoritative test.
    """
    problems: list[str] = []
    warnings: list[str] = []
    shape = problems if strict else warnings

    device = find_device(src, "TPD0")
    device_body = src[device.body_start:device.end]

    if "TPTY" in device_body:
        for match in re.finditer("TPTY", device_body):
            problems.append(
                f"TPD0 still references the EC register TPTY at line "
                f"{line_number(src, device.body_start + match.start())}")
        problems = problems[:5]

    try:
        crs = find_method_in(device_body, "_CRS")
    except PatchError as exc:
        problems.append(str(exc))
        crs = None

    if crs is not None:
        crs_body = device_body[crs.body_start + 1:crs.end - 1]
        if not strip_comments(crs_body).strip():
            problems.append("TPD0._CRS is empty")
        if not has_i2c_address(crs_body, 0x15):
            snippet = " ".join(strip_comments(crs_body).split())[:300]
            shape.append("TPD0._CRS has no recognisable I2cSerialBus descriptor "
                         f"at address 0x15 (it contains: {snippet!r})")
        if not re.search(r"ConcatenateResTemplate\s*\(\s*SBFB\s*,\s*SBFG\s*\)",
                         crs_body):
            shape.append("TPD0._CRS does not return "
                         "ConcatenateResTemplate (SBFB, SBFG)")

    try:
        dsm = find_method_in(device_body, "_DSM")
    except PatchError as exc:
        problems.append(str(exc))
        return problems, warnings

    dsm_body = device_body[dsm.body_start + 1:dsm.end - 1]
    blocks = case_blocks(dsm_body, 1)
    if not blocks:
        problems.append("TPD0._DSM has no Case (0x01) / Case (One)")
    else:
        if any("TPTY" in dsm_body[start:end] for start, end in blocks):
            problems.append("TPD0._DSM Case (0x01) still references TPTY")
        # At least one of the selector-1 cases must be the patched, unconditional
        # one. Other cases (e.g. a function-0 buffer response) are left alone.
        returns_one = re.compile(r"Return\s*\(\s*" + int_literal(1) + r"\s*\)")
        if not any(returns_one.search(dsm_body[start:end])
                   for start, end in blocks):
            snippets = "; ".join(
                repr(" ".join(dsm_body[start:end].split())[:80])
                for start, end in blocks)
            problems.append("TPD0._DSM has no Case (0x01) returning 0x01 "
                            f"(case bodies found: {snippets})")

    return problems, warnings


# --- driver -----------------------------------------------------------------

def patch_source(src: str, *, bump_revision: bool = True
                 ) -> tuple[str, list[str], bool]:
    """Patch src. Returns (new_src, notes, changed)."""
    device = find_device(src, "TPD0")
    device_body = src[device.body_start + 1:device.end - 1]

    notes: list[str] = []
    patches: list[tuple[int, int, str]] = []

    for planner in (plan_crs, plan_dsm):
        result, planner_notes = planner(device_body)
        notes.extend(planner_notes)
        if result is not None:
            rel_start, rel_end, text = result
            patches.append((device.body_start + 1 + rel_start,
                            device.body_start + 1 + rel_end,
                            text))

    if not patches:
        problems, _ = verify(src)
        if problems:
            raise PatchError("; ".join(problems))
        return src, notes, False

    patched = src
    for start, end, text in sorted(patches, key=lambda p: p[0], reverse=True):
        patched = patched[:start] + text + patched[end:]

    if bump_revision:
        patched, note = bump_oem_revision(patched)
        notes.append(note)

    problems, _ = verify(patched)
    if problems:
        raise PatchError("; ".join(problems))

    return patched, notes, True


def unified_diff(original: str, patched: str, path: Path) -> str:
    diff = difflib.unified_diff(
        original.splitlines(keepends=True),
        patched.splitlines(keepends=True),
        fromfile=f"{path} (firmware)",
        tofile=f"{path} (patched)",
    )
    return "".join(diff)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Patch the Flex 3 11ADA05 DSDT so TPD0 is EC-independent.",
        epilog="Exit codes: 0 ok, 1 I/O error, 2 usage, 3 unsupported table.",
    )
    parser.add_argument("file", type=Path, help="disassembled DSDT (dsdt.dsl)")
    parser.add_argument("--diff", action="store_true",
                        help="print a unified diff and do not write anything")
    parser.add_argument("--verify-only", action="store_true",
                        help="check that FILE is already correctly patched (strict)")
    parser.add_argument("--verify-aml", action="store_true",
                        help="check a disassembly of the compiled AML: hard checks "
                             "only, resource-shape differences are warnings")
    parser.add_argument("--quiet", action="store_true",
                        help="suppress the per-step notes")
    args = parser.parse_args(argv)

    try:
        src = args.file.read_text(encoding="utf-8", errors="surrogateescape")
    except OSError as exc:
        print(f"error: cannot read {args.file}: {exc}", file=sys.stderr)
        return EXIT_IO

    if args.verify_only or args.verify_aml:
        strict = not args.verify_aml
        try:
            problems, warnings = verify(src, strict=strict)
        except PatchError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return exc.code
        for warning in warnings:
            print(f"warn: {warning}", file=sys.stderr)
        if problems:
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            return EXIT_UNSUPPORTED
        if not args.quiet:
            print("    OK: TPD0 is EC-independent and returns the 0x15 I2C resource")
        return EXIT_OK

    try:
        patched, notes, changed = patch_source(src)
    except PatchError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return exc.code

    if args.diff:
        if not changed:
            print("    (nothing to change - already patched)", file=sys.stderr)
            return EXIT_OK
        sys.stdout.write(unified_diff(src, patched, args.file))
        return EXIT_OK

    if not args.quiet:
        for note in notes:
            print(f"    {note}")

    if changed:
        try:
            args.file.write_text(patched, encoding="utf-8",
                                 errors="surrogateescape")
        except OSError as exc:
            print(f"error: cannot write {args.file}: {exc}", file=sys.stderr)
            return EXIT_IO

    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
