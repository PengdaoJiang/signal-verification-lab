from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import run_rtl


class RtlRunnerTests(unittest.TestCase):
    def test_every_declared_source_is_present(self):
        for name, sources in run_rtl.CASES.items():
            for relative in sources + [f"tb/{name}.sv"]:
                self.assertTrue((ROOT / relative).is_file(), relative)

    def test_pass_requires_one_exact_marker_and_no_error(self):
        name = "tb_link_crc32c"
        marker = "TB_LINK_CRC32C=PASS\n"
        self.assertTrue(run_rtl.valid_result(marker, name))
        for log in ["", marker * 2, "x" + marker, "ERROR: failed\n" + marker,
                    "Fatal: mismatch\n" + marker, "TB_FINITE_FAIL=bad\n" + marker]:
            self.assertFalse(run_rtl.valid_result(log, name), log)
