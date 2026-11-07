"""The per-image release check (#50 decision) must fail on each condition it guards."""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_release_processes as check

CLEAN = {"beams": 1123, "calls": [list(c) for c in sorted(check.KNOWN_SPAWNERS)], "beams_with_wget": []}


def output(report, scripts=(), present=()):
    return "\n".join([json.dumps(report), "--scripts", *scripts, "--present", *present]) + "\n"


class ReleaseProcessCheck(unittest.TestCase):
    def problems(self, report=CLEAN, scripts=(), present=()):
        return check.evaluate(*check.parse(output(report, scripts, present)))

    def test_clean_image_passes(self):
        self.assertEqual(self.problems(), [])

    def test_new_spawning_call_fails(self):
        report = dict(CLEAN, calls=CLEAN["calls"] + [["Elixir.ChatOverlay.Web", "os:cmd/1"]])
        self.assertEqual(self.problems(report), ["new process-spawning call: Elixir.ChatOverlay.Web imports os:cmd/1"])

    def test_known_module_with_new_call_fails(self):
        report = dict(CLEAN, calls=CLEAN["calls"] + [["heart", "os:cmd/1"]])
        self.assertEqual(len(self.problems(report)), 1)

    def test_beam_naming_wget_fails(self):
        self.assertEqual(len(self.problems(dict(CLEAN, beams_with_wget=["Elixir.X.beam"]))), 1)

    def test_script_naming_wget_fails(self):
        self.assertEqual(len(self.problems(scripts=["/app/bin/chat_overlay"])), 1)

    def test_removed_files_back_fail(self):
        for path in check.REMOVED:
            with self.subTest(path=path):
                self.assertEqual(self.problems(present=[path]), [f"removed file is back: {path}"])

    def test_empty_scan_fails(self):
        self.assertEqual(self.problems(dict(CLEAN, beams=0, calls=[])), ["no beams scanned"])

    def test_malformed_scan_output_raises(self):
        with self.assertRaises((ValueError, json.JSONDecodeError)):
            check.parse("not json\n--present\n")


if __name__ == "__main__":
    unittest.main()
