"""Execute the actual final CI gate for success, skipped and failed dependencies."""
import os
from pathlib import Path
import subprocess
import unittest


class QualityGateTests(unittest.TestCase):
    def test_dependency_results_fail_closed(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        gate = workflow.split("  quality-gate:\n", 1)[1]
        commands = gate.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in commands.splitlines() if line.strip())
        names = ("SOURCE_RESULT", "IMAGE_RESULT", "POSTGRES_RESULT", "DECODER_RESULT")
        baseline = {**os.environ, **dict.fromkeys(names, "success")}
        self.assertEqual(subprocess.run(["sh", "-e", "-c", script], env=baseline).returncode, 0)
        for name in names:
            for value in ("failure", "cancelled", "skipped", ""):
                with self.subTest(dependency=name, result=value):
                    result = subprocess.run(["sh", "-e", "-c", script], env={**baseline, name: value})
                    self.assertNotEqual(result.returncode, 0)
