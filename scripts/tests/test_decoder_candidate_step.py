"""Run the real workflow lines that record the candidate image ID, under the runner's shell."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml"
FAKE_DOCKER = """#!/bin/sh
case "$1 $FAKE_INSPECT" in
  "image fail") exit 1 ;;
  "image empty") exit 0 ;;
  "image ok") echo sha256:abc ;;
esac
"""


class CandidateImageId(unittest.TestCase):
    def run_step(self, inspect):
        text = WORKFLOW.read_text()
        start = text.index("docker build -f Dockerfile.media-validator.candidate")
        end = text.index("python3 scripts/test_media_sandbox.py", start)
        script = "".join(line.strip() + "\n" for line in text[start:end].splitlines())
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            docker = tmp / "docker"
            docker.write_text(FAKE_DOCKER)
            docker.chmod(0o755)
            github_env = tmp / "env"
            github_env.touch()
            env = {**os.environ, "PATH": f"{tmp}{os.pathsep}{os.environ['PATH']}",
                   "FAKE_INSPECT": inspect, "GITHUB_ENV": str(github_env)}
            # GitHub runs a run: block with no shell key as `bash -e {0}`.
            result = subprocess.run(["bash", "-e", "-c", script + 'printenv MEDIA_VALIDATOR_IMAGE\n'],
                                    env=env, capture_output=True, text=True)
            return result, github_env.read_text()

    def test_failed_or_empty_inspection_stops_before_recording_an_id(self):
        for inspect in ("fail", "empty"):
            with self.subTest(inspect=inspect):
                result, recorded = self.run_step(inspect)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(recorded, "")

    def test_verified_id_is_exported_and_recorded(self):
        result, recorded = self.run_step("ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "sha256:abc")
        self.assertEqual(recorded, "CANDIDATE_IMAGE=sha256:abc\n")


if __name__ == "__main__":
    unittest.main()
