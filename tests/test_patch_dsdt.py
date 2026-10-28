#!/usr/bin/env python3
"""Offline tests for scripts/patch-dsdt.py.

No hardware and no firmware dump involved: everything runs against the
synthetic table in tests/fixtures/dsdt-ec-gated.dsl.

    python3 -m unittest discover -s tests -v      (or: make test)
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
ROOT = TESTS_DIR.parent
PATCHER = ROOT / "scripts" / "patch-dsdt.py"
FIXTURE = TESTS_DIR / "fixtures" / "dsdt-ec-gated.dsl"

EXIT_OK = 0
EXIT_UNSUPPORTED = 3


def load_module():
    spec = importlib.util.spec_from_file_location("patch_dsdt", PATCHER)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses need this during exec
    spec.loader.exec_module(module)
    return module


patch_dsdt = load_module()


def tpd0_body(text: str) -> str:
    device = patch_dsdt.find_device(text, "TPD0")
    return text[device.body_start:device.end]


def reindent(text: str, level: int = 4, target: int = 2) -> str:
    """Rewrite indentation (4 -> 2 spaces per level) to defeat exact matching."""
    out = []
    for line in text.splitlines(keepends=True):
        stripped = line.lstrip(" ")
        depth = len(line) - len(stripped)
        out.append(" " * (depth // level * target) + stripped)
    return "".join(out)


def with_unrelated_tpty_method(text: str) -> str:
    """Add an _STA method that references TPTY outside _CRS/_DSM."""
    method = (
        "            Method (_STA, 0, NotSerialized)\n"
        "            {\n"
        "                If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))\n"
        "                {\n"
        "                    Return (0x0F)\n"
        "                }\n"
        "\n"
        "                Return (Zero)\n"
        "            }\n"
        "\n"
    )
    anchor = "            Method (_CRS, 0, NotSerialized)"
    assert anchor in text
    return text.replace(anchor, method + anchor, 1)


def to_iasl_style(text: str) -> str:
    """Render constants the way iasl's disassembler does on a recompile.

    iasl prints small integer constants as keywords (`One`, `Zero`, `Ones`) and
    may print resource addresses in decimal. A patched table that has been
    compiled and disassembled comes back in this form, so verification must not
    depend on our own source spelling.
    """
    return (
        text
        .replace("Return (0x01)", "Return (One)")
        .replace("Case (0x01)", "Case (One)")
        .replace("I2cSerialBusV2 (0x0015,", "I2cSerialBusV2 (21,")
    )


class PatcherTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workdir = Path(tempfile.mkdtemp(prefix="flex3-dsdt-test-"))
        self.addCleanup(shutil.rmtree, self.workdir, True)
        self.original = FIXTURE.read_text(encoding="utf-8")

    # -- helpers ---------------------------------------------------------
    def write(self, text: str, name: str = "dsdt.dsl") -> Path:
        path = self.workdir / name
        path.write_text(text, encoding="utf-8")
        return path

    def run_patcher(self, path: Path, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(PATCHER), *extra, str(path)],
            capture_output=True,
            text=True,
            check=False,
        )

    # -- tests -----------------------------------------------------------
    def test_patches_the_ec_gated_table(self) -> None:
        path = self.write(self.original)
        result = self.run_patcher(path)
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)

        patched = path.read_text(encoding="utf-8")
        body = tpd0_body(patched)

        self.assertNotIn("TPTY", body)
        self.assertIn("I2cSerialBusV2 (0x0015", body)
        self.assertIn("ConcatenateResTemplate (SBFB, SBFG)", body)
        self.assertIn("Return (0x01)", body)
        # _CRS now exposes exactly one (unconditional) I2C resource, and the
        # touchscreen-ish 0x2C branch is gone.
        self.assertEqual(body.count("I2cSerialBusV2"), 1)
        self.assertNotIn("0x002C", patched)
        # OEM revision bumped by 0x1000 so the kernel accepts the override.
        self.assertIn('"CB-01   ", 0x00001002)', patched)
        # verification mode agrees
        self.assertEqual(self.run_patcher(path, "--verify-only").returncode, EXIT_OK)

    def test_is_idempotent(self) -> None:
        path = self.write(self.original)
        self.assertEqual(self.run_patcher(path).returncode, EXIT_OK)
        once = path.read_bytes()

        second = self.run_patcher(path)
        self.assertEqual(second.returncode, EXIT_OK, second.stderr)
        self.assertEqual(path.read_bytes(), once)
        self.assertIn("already", second.stdout)
        self.assertIn("0x00001002", path.read_text(encoding="utf-8"))

    def test_structural_fallback_on_reformatted_table(self) -> None:
        reformatted = reindent(self.original)
        self.assertNotIn(patch_dsdt.EXACT_CRS_OLD, reformatted)
        path = self.write(reformatted)

        result = self.run_patcher(path)
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        self.assertIn("structural match", result.stdout)

        patched = path.read_text(encoding="utf-8")
        self.assertNotIn("TPTY", tpd0_body(patched))
        self.assertEqual(self.run_patcher(path, "--verify-only").returncode, EXIT_OK)

    def test_refuses_table_without_tpd0(self) -> None:
        path = self.write(self.original.replace("Device (TPD0)", "Device (WEBC)"))
        result = self.run_patcher(path)
        self.assertEqual(result.returncode, EXIT_UNSUPPORTED)
        self.assertIn("TPD0", result.stderr)
        self.assertEqual(path.read_text(encoding="utf-8"),
                         self.original.replace("Device (TPD0)", "Device (WEBC)"))

    def test_refuses_table_with_tpty_outside_the_patched_methods(self) -> None:
        broken = with_unrelated_tpty_method(self.original)
        path = self.write(broken)
        result = self.run_patcher(path)
        self.assertEqual(result.returncode, EXIT_UNSUPPORTED)
        self.assertIn("TPTY", result.stderr)
        self.assertIn("line", result.stderr)
        # a refused patch must not touch the file
        self.assertEqual(path.read_text(encoding="utf-8"), broken)

    def test_diff_mode_writes_nothing(self) -> None:
        path = self.write(self.original)
        result = self.run_patcher(path, "--diff")
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        self.assertIn("---", result.stdout)
        self.assertIn("+++", result.stdout)
        self.assertIn("+", result.stdout)
        self.assertEqual(path.read_text(encoding="utf-8"), self.original)

    def test_verify_only_rejects_unpatched_table(self) -> None:
        path = self.write(self.original)
        result = self.run_patcher(path, "--verify-only")
        self.assertEqual(result.returncode, EXIT_UNSUPPORTED)
        self.assertIn("TPTY", result.stderr)

    def test_verify_accepts_iasl_keyword_constants(self) -> None:
        """Regression: iasl rewrites 0x01 as One on disassembly."""
        path = self.write(self.original)
        self.assertEqual(self.run_patcher(path).returncode, EXIT_OK)
        path.write_text(to_iasl_style(path.read_text(encoding="utf-8")),
                        encoding="utf-8")

        result = self.run_patcher(path, "--verify-only")
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)

    def test_second_run_on_iasl_style_table_changes_nothing(self) -> None:
        """Booting the override and rebuilding must not re-patch or re-bump."""
        path = self.write(self.original)
        self.assertEqual(self.run_patcher(path).returncode, EXIT_OK)
        styled = to_iasl_style(path.read_text(encoding="utf-8"))
        path.write_text(styled, encoding="utf-8")

        result = self.run_patcher(path)
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        self.assertEqual(path.read_text(encoding="utf-8"), styled)
        self.assertIn("already", result.stdout)

    @unittest.skipUnless(shutil.which("iasl"), "iasl (acpica-tools) not installed")
    def test_patched_table_compiles(self) -> None:
        path = self.write(self.original)
        self.assertEqual(self.run_patcher(path).returncode, EXIT_OK)
        compile_result = subprocess.run(
            ["iasl", "-tc", str(path)],
            cwd=self.workdir,
            capture_output=True,
            text=True,
            check=False,
        )
        output = compile_result.stdout + compile_result.stderr
        self.assertEqual(compile_result.returncode, 0, output)
        self.assertIn("0 Errors", output)


if __name__ == "__main__":
    unittest.main()
