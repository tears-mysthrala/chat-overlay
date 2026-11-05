"""Run audit_image.py against a fake docker: candidate mode never applies VEX and fails on any finding."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "audit_image.py"
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
args = sys.argv[1:]
Path(os.environ["DOCKER_CALLS"]).open("a").write(" ".join(args) + "\n")
if args[:2] == ["image", "inspect"]:
    print(json.dumps([{"Id": "sha256:" + "0" * 64, "Size": 1, "Architecture": "amd64", "Os": "linux"}]))
elif args[0] == "save":
    Path(args[args.index("-o") + 1]).touch()
elif args[0] == "run":
    mount = next((a for a in args if a.startswith("type=bind")), "")
    scan = Path(re.search(r"source=([^,]+)", mount).group(1)) if mount else None
    if any("syft" in a for a in args):
        (scan / "syft.cdx.json").write_text(json.dumps({"specVersion": "1.7", "components": [],
            "dependencies": [], "metadata": {"component": {"bom-ref": "root"}}}))
    elif any("grype" in a for a in args):
        (scan / "vulnerabilities.json").write_text(os.environ["FAKE_REPORT"])
    else:
        print(json.dumps({"components": [], "dependencies": []}))
'''
# The scan needs jsonschema and the published schemas; neither is the behaviour under test.
RUNNER = r'''
import io, runpy, sys, types, urllib.request
jsonschema = types.ModuleType("jsonschema")
jsonschema.Draft7Validator = lambda *a, **k: types.SimpleNamespace(validate=lambda bom: None)
referencing = types.ModuleType("referencing")
class Registry:
    def with_resource(self, *a): return self
referencing.Registry = Registry
referencing.Resource = types.SimpleNamespace(from_contents=lambda c: c)
sys.modules.update(jsonschema=jsonschema, referencing=referencing)
class Response(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False
urllib.request.urlopen = lambda *a, **k: Response(b'{"$id": "schema"}')
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
'''
LOW = {"matches": [{"vulnerability": {"id": "CVE-0000-0001", "severity": "Low"},
                    "artifact": {"name": "pkg", "version": "1"}}]}


class AuditModes(unittest.TestCase):
    def run_audit(self, report, *flags):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        tmp = Path(self.tmp.name)
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text(FAKE_DOCKER)
        docker.chmod(0o755)
        self.calls = tmp / "calls"
        self.calls.touch()
        # Malformed on purpose: a repository VEX file must not even be read by a decoder scan.
        (tmp / "vex.openvex.json").write_text("not json")
        security = tmp / "docs/security"
        security.mkdir(parents=True)
        for name in ("vex-decoder.approved.json", "decoder-evidence.approved.json"):
            shutil.copy(SCRIPT.parents[1] / "docs/security" / name, security)
        env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
               "DOCKER_CALLS": str(self.calls), "FAKE_REPORT": json.dumps(report)}
        return subprocess.run([sys.executable, "-c", RUNNER, str(SCRIPT), "image", *flags],
                              cwd=tmp, env=env, capture_output=True, text=True, timeout=60)

    def test_candidate_passes_only_with_no_findings_and_no_vex(self):
        result = self.run_audit({"matches": []}, "--decoder-candidate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--vex", self.calls.read_text())
        self.assertTrue((Path(self.tmp.name) / "output/audit/decoder-candidate/vulnerabilities.json").is_file())

    def test_candidate_fails_on_a_low_finding(self):
        result = self.run_audit(LOW, "--decoder-candidate")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("--vex", self.calls.read_text())

    def test_unknown_mode_is_rejected_before_any_docker_call(self):
        for flags in (["--decoder-candidat"], ["--decoder", "--decoder-candidate"]):
            with self.subTest(flags=flags):
                result = self.run_audit({"matches": []}, *flags)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls.read_text(), "")

    def test_approved_mode_still_rejects_an_unapproved_image(self):
        result = self.run_audit({"matches": []}, "--decoder")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Decoder image changed", result.stderr)
        self.assertNotIn("--vex", self.calls.read_text())
        self.assertTrue((Path(self.tmp.name) / "output/audit/decoder/vulnerabilities.raw.json").is_file())


if __name__ == "__main__":
    unittest.main()
