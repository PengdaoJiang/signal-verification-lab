"""Synthetic receipt fixtures test the exporter, not model or RTL performance."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("evaluation_export", ROOT / "evaluation/export_results.py")
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)


class EvaluationExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        self.name = "tb_link_crc32c"
        self.log = self.output / self.name / "simulation.log"
        self.log.parent.mkdir()
        self.log.write_text("TB_LINK_CRC32C=PASS\n", encoding="utf-8")
        self.receipt = {
            "schema_version": 1, "evidence_class": "behavioral_simulation", "passed": True,
            "source_sha256": {rel: ev.digest(ROOT / rel) for rel in ev.expected_sources(self.name)},
            "cases": [{"name": self.name, "passed": True, "log_sha256": ev.digest(self.log)}],
        }

    def save(self):
        (self.output / "receipt.json").write_text(json.dumps(self.receipt), encoding="utf-8")

    def row(self):
        self.save()
        return ev.export_records(self.output, selected=[self.name])[0]

    def test_catalog_matches_real_runner_and_bench_checks(self):
        self.assertEqual(len(ev.load_catalog()["tasks"]), len(ev.CASES))

    def test_hard_outcome_is_separate_from_unavailable_labels(self):
        row = self.row()
        self.assertEqual(row["status"], "passed")
        self.assertEqual(row["outcome_reward"], 1.0)
        for key in ("physical_metrics", "process_reward", "tool_exit_codes"):
            self.assertIsNone(row[key])

    def test_missing_case_is_not_a_negative_training_label(self):
        self.receipt["cases"] = []
        row = self.row()
        self.assertIsNone(row["outcome_reward"])
        self.assertEqual(row["reason_codes"], ["case_receipt_missing"])

    def test_source_drift_and_missing_bindings_reject_a_pass(self):
        original = copy.deepcopy(self.receipt)
        for change in ("missing", "wrong_hash", "malformed_hash"):
            self.receipt = copy.deepcopy(original)
            key = "rtl/common/link_crc32c.sv"
            if change == "missing":
                del self.receipt["source_sha256"][key]
            else:
                self.receipt["source_sha256"][key] = "0" * 64 if change == "wrong_hash" else "not-a-hash"
            self.assertEqual(self.row()["status"], "unscorable")

    def test_missing_or_modified_raw_log_rejects_a_pass(self):
        self.log.write_text("modified\n", encoding="utf-8")
        self.assertEqual(self.row()["reason_codes"], ["log_hash_mismatch"])
        self.log.unlink()
        self.assertEqual(self.row()["reason_codes"], ["log_missing"])

    def test_duplicate_marker_wrong_case_and_error_cannot_pass(self):
        for text in ("", "TB_LINK_CRC32C=PASS\n" * 2, "TB_LINK_ENDPOINT=PASS\n",
                     "FATAL: fail\nTB_LINK_CRC32C=PASS\n", "ERROR: fail\nTB_LINK_CRC32C=PASS\n"):
            self.log.write_text(text, encoding="utf-8")
            self.receipt["cases"][0]["log_sha256"] = ev.digest(self.log)
            self.assertEqual(self.row()["reason_codes"], ["receipt_log_verdict_conflict"])

    def test_requested_denominator_keeps_missing_cases(self):
        self.save()
        rows = ev.export_records(self.output)
        self.assertEqual(len(rows), len(ev.CASES))
        self.assertEqual(sum(x["status"] == "passed" for x in rows), 1)

    def test_duplicate_case_and_wrong_evidence_class_rejected(self):
        original = copy.deepcopy(self.receipt)
        self.receipt["cases"] *= 2
        with self.assertRaises(ValueError):
            self.row()
        self.receipt = original
        self.receipt["evidence_class"] = "physical_signoff"
        with self.assertRaises(ValueError):
            self.row()

    def test_bool_like_verdict_is_not_true(self):
        self.receipt["cases"][0]["passed"] = 1
        self.assertEqual(self.row()["reason_codes"], ["unsupported_case_verdict"])

    def test_task_path_injection_and_duplicate_selection_rejected(self):
        self.save()
        for selected in (["../arbitrary"], [self.name, self.name], []):
            with self.assertRaises(ValueError):
                ev.export_records(self.output, selected=selected)

    def test_duplicate_json_keys_are_rejected(self):
        (self.output / "receipt.json").write_text('{"schema_version":1,"schema_version":1}', encoding="utf-8")
        with self.assertRaises(ValueError):
            ev.export_records(self.output)

    def test_candidate_cannot_replace_the_trusted_testbench(self):
        candidate = self.output / "candidate"
        for rel in ev.expected_sources(self.name):
            target = candidate / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, target)
        bench = candidate / "tb" / (self.name + ".sv")
        bench.write_text("modified evaluator", encoding="utf-8")
        self.receipt["source_sha256"][f"tb/{self.name}.sv"] = ev.digest(bench)
        self.save()
        row = ev.export_records(self.output, candidate, [self.name])[0]
        self.assertEqual(row["reason_codes"], ["trusted_evaluator_changed"])


if __name__ == "__main__":
    unittest.main()
