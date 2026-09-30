"""Exercise CI evidence rejection using synthetic reports, never source-text assertions."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

MODULE = pathlib.Path(__file__).parents[1] / "check_test_report.py"

class ReportGateTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("report_gate", MODULE)
        self.gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.gate)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = pathlib.Path(self.tmp.name) / "summary.json"

    def check(self, **changes):
        summary = {"total": 12, "failures": 0, "skipped": 0, "excluded": 0}
        summary.update(changes)
        self.path.write_text(json.dumps(summary))
        return self.gate.validate(self.path)

    def test_accepts_complete_success(self):
        self.assertEqual(self.check(), 12)

    def test_rejects_empty_failed_skipped_or_excluded_suite(self):
        for changes in ({"total": 0}, {"failures": 1}, {"skipped": 1}, {"excluded": 1}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.check(**changes)

    def test_rejects_missing_fields_and_wrong_types(self):
        for summary in ({"total": 12}, {"total": True, "failures": 0, "skipped": 0, "excluded": 0}):
            self.path.write_text(json.dumps(summary))
            with self.assertRaises(ValueError):
                self.gate.validate(self.path)

    def test_missing_evidence_fails(self):
        with self.assertRaises(FileNotFoundError):
            self.gate.validate(self.path)

    def test_rejects_different_discovery_between_runs(self):
        other = self.path.with_name("other.json")
        self.check()
        other.write_text(json.dumps({"total": 11, "failures": 0, "skipped": 0, "excluded": 0}))
        with self.assertRaises(ValueError):
            self.gate.validate_runs([self.path, other])

if __name__ == "__main__":
    unittest.main()
