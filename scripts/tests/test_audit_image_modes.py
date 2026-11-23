"""Run audit_image.py against a fake docker.

Candidate mode never applies VEX and fails on anything the approved decoder artifact does not already
accept (decision of 2026-11-07, #50). Accepted findings come from the approved documents themselves.
"""
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
    print(json.dumps([{"Id": os.environ.get("FAKE_IMAGE_ID", "sha256:" + "0" * 64), "Size": 1, "Architecture": "amd64", "Os": "linux"}]))
elif args[0] == "save":
    Path(args[args.index("-o") + 1]).touch()
elif args[0] == "run":
    mount = next((a for a in args if a.startswith("type=bind")), "")
    scan = Path(re.search(r"source=([^,]+)", mount).group(1)) if mount else None
    if any("syft" in a for a in args):
        if os.environ.get("FAKE_SYFT_ABSENT"):
            sys.exit(0)
        (scan / "syft.cdx.json").write_text(json.dumps({"specVersion": "1.7",
            "components": json.loads(os.environ.get("FAKE_COMPONENTS", "[]")),
            "dependencies": [], "metadata": {"component": {"bom-ref": "root"}}}))
    elif any("grype" in a for a in args):
        if os.environ.get("FAKE_GRYPE_FAILS"):
            sys.exit(2)
        report = os.environ.get("FAKE_VEX_REPORT", os.environ["FAKE_REPORT"]) if "--vex" in args else os.environ["FAKE_REPORT"]
        if report != "absent":
            (scan / "vulnerabilities.json").write_text(report)
    elif "--read-only" in args:
        print(json.dumps(json.loads(Path("docs/security/decoder-evidence.approved.json").read_text())["runtime_sha256"]))
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
APPROVED = json.loads((SCRIPT.parents[1] / "docs/security/vex-decoder.approved.json").read_text())
EVIDENCE = json.loads((SCRIPT.parents[1] / "docs/security/decoder-evidence.approved.json").read_text())


def purl_parts(purl):
    name, _, rest = purl.split("/")[-1].partition("@")
    return name, rest.split("?")[0]


ACCEPTED = sorted({(st["vulnerability"]["@id"], *purl_parts(p["@id"]))
                   for st in APPROVED["statements"] for p in st["products"]})
PACKAGES = sorted({(name, version) for _, name, version in ACCEPTED})


def match(vulnerability, name, version):
    return {"vulnerability": {"id": vulnerability, "severity": "Medium"},
            "artifact": {"name": name, "version": version}}


def components(packages=PACKAGES):
    return [{"name": n, "version": v, "purl": f"pkg:apk/alpine/{n}@{v}?arch=x86_64"} for n, v in packages]


ACCEPTED_ONLY = {"matches": [match(*row) for row in ACCEPTED]}


class AuditModes(unittest.TestCase):
    def run_audit(self, report, *flags, packages=PACKAGES, env_extra=None, edit_evidence=None):
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
        if flags == ("--decoder",):
            for name in EVIDENCE["repository_sha256"]:
                target = tmp / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(SCRIPT.parents[1] / name, target)
        if edit_evidence:
            edit_evidence(security)
        env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
               "DOCKER_CALLS": str(self.calls),
               "FAKE_REPORT": report if isinstance(report, str) else json.dumps(report),
               "FAKE_COMPONENTS": json.dumps(components(packages)), **(env_extra or {})}
        return subprocess.run([sys.executable, "-c", RUNNER, str(SCRIPT), "image", *flags],
                              cwd=tmp, env=env, capture_output=True, text=True, timeout=60)

    def test_accepted_findings_come_from_the_approved_documents(self):
        self.assertEqual(len(ACCEPTED), 17)

    def test_candidate_with_only_accepted_findings_passes_without_vex(self):
        result = self.run_audit(ACCEPTED_ONLY, "--decoder-candidate")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("--vex", self.calls.read_text())
        self.assertEqual(result.stdout.count("Accepted (approved for the decoder artifact):"), 17)
        self.assertIn("17 accepted, 0 new; 0 approved packages changed", result.stdout)
        self.assertTrue((Path(self.tmp.name) / "output/audit/decoder-candidate/vulnerabilities.json").is_file())

    def test_one_new_finding_fails_and_is_listed_apart(self):
        report = {"matches": ACCEPTED_ONLY["matches"] + LOW["matches"]}
        result = self.run_audit(report, "--decoder-candidate")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("NEW: CVE-0000-0001 pkg 1", result.stdout)
        self.assertIn("17 accepted, 1 new", result.stdout)

    def test_unrelated_finding_alone_fails(self):
        self.assertEqual(self.run_audit(LOW, "--decoder-candidate").returncode, 1)

    def test_accepted_finding_at_another_version_fails(self):
        vulnerability, name, version = ACCEPTED[0]
        rows = [match(*row) for row in ACCEPTED[1:]] + [match(vulnerability, name, version + "-x")]
        packages = [(n, v + "-x" if n == name else v) for n, v in PACKAGES]
        result = self.run_audit({"matches": rows}, "--decoder-candidate", packages=packages)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"NEW: {vulnerability} {name} {version}-x", result.stdout)
        self.assertIn(f"Approved package changed (name, approved version, found): {name} {version}", result.stdout)

    def test_accepted_package_changed_without_a_finding_fails(self):
        name = PACKAGES[0][0]
        rows = [match(*row) for row in ACCEPTED if row[1] != name]
        packages = [(n, v) for n, v in PACKAGES if n != name]
        result = self.run_audit({"matches": rows}, "--decoder-candidate", packages=packages)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"{name} ", result.stdout.split("Approved package changed")[1])

    def test_expired_approval_fails(self):
        def expire(security):
            path = security / "decoder-evidence.approved.json"
            evidence = json.loads(path.read_text())
            evidence["review_due"] = "2026-01-01"
            path.write_text(json.dumps(evidence))
        result = self.run_audit(ACCEPTED_ONLY, "--decoder-candidate", edit_evidence=expire)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Decoder evidence expired", result.stderr)

    def test_unapproved_or_expired_statement_fails(self):
        def edit(change):
            def apply(security):
                path = security / "vex-decoder.approved.json"
                vex = json.loads(path.read_text())
                change(vex)
                path.write_text(json.dumps(vex))
            return apply
        cases = {"approval pending": lambda v: v["approval"].update(status="pending"),
                 "statement expired": lambda v: v["statements"][0].update(review_due="2026-01-01"),
                 "binding disagrees": lambda v: v["artifact_binding"].update(image="sha256:" + "0" * 64)}
        for name, change in cases.items():
            with self.subTest(case=name):
                result = self.run_audit(ACCEPTED_ONLY, "--decoder-candidate", edit_evidence=edit(change))
                self.assertNotEqual(result.returncode, 0)

    def test_missing_or_unreadable_approval_fails(self):
        def pending(path):
            evidence = json.loads(path.read_text())
            evidence["status"] = "pending"
            path.write_text(json.dumps(evidence))
        for name, target, action in (("missing", "vex-decoder.approved.json", lambda p: p.unlink()),
                                     ("malformed", "vex-decoder.approved.json", lambda p: p.write_text("{")),
                                     ("evidence pending", "decoder-evidence.approved.json", pending)):
            with self.subTest(name=name):
                result = self.run_audit(ACCEPTED_ONLY, "--decoder-candidate",
                                        edit_evidence=lambda s, t=target, a=action: a(s / t))
                self.assertNotEqual(result.returncode, 0)

    def test_empty_absent_invalid_or_failed_scan_fails(self):
        cases = {"empty": ({"matches": []}, {}), "absent": ("absent", {}), "invalid": ("not json", {}),
                 "no matches key": ({"descriptor": {}}, {}), "scanner error": (ACCEPTED_ONLY, {"FAKE_GRYPE_FAILS": "1"})}
        for name, (report, extra) in cases.items():
            with self.subTest(case=name):
                result = self.run_audit(report, "--decoder-candidate", env_extra=extra)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("0 new; 0 approved packages changed", result.stdout)

    def test_stale_grype_report_cannot_replace_missing_output(self):
        for flags, directory, report in (((), "audit", {"matches": []}),
                                         (("--decoder",), "audit/decoder", {"matches": []}),
                                         (("--decoder-candidate",), "audit/decoder-candidate", ACCEPTED_ONLY)):
            with self.subTest(flags=flags):
                def seed(security):
                    (security.parents[1] / "vex.openvex.json").unlink()
                    out = security.parents[1] / "output" / directory
                    out.mkdir(parents=True)
                    (out / "vulnerabilities.json").write_text(json.dumps(report))
                result = self.run_audit("absent", *flags, edit_evidence=seed,
                                        env_extra={"FAKE_IMAGE_ID": EVIDENCE["image"]})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("FileNotFoundError", result.stderr)
                self.assertIn("vulnerabilities.json", result.stderr)
                self.assertFalse((Path(self.tmp.name) / "output" / directory / "vulnerabilities.json").exists())

    def test_stale_syft_report_cannot_replace_missing_output(self):
        def seed(security):
            out = security.parents[1] / "output/audit/decoder-candidate"
            out.mkdir(parents=True)
            (out / "syft.cdx.json").write_text(json.dumps({"specVersion": "1.7",
                "components": components(), "dependencies": [], "metadata": {"component": {"bom-ref": "root"}}}))
        result = self.run_audit(ACCEPTED_ONLY, "--decoder-candidate", edit_evidence=seed,
                                env_extra={"FAKE_SYFT_ABSENT": "1"})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("FileNotFoundError", result.stderr)
        self.assertIn("syft.cdx.json", result.stderr)
        self.assertNotIn("grype", self.calls.read_text())

    def test_approved_vex_pass_requires_its_own_grype_output(self):
        for raw in ({"matches": []}, ACCEPTED_ONLY):
            with self.subTest(raw=raw):
                result = self.run_audit(raw, "--decoder", env_extra={
                    "FAKE_IMAGE_ID": EVIDENCE["image"], "FAKE_VEX_REPORT": "absent"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("FileNotFoundError", result.stderr)
                self.assertIn("vulnerabilities.json", result.stderr)
                self.assertIn("--vex", self.calls.read_text())
                out = Path(self.tmp.name) / "output/audit/decoder"
                self.assertEqual(json.loads((out / "vulnerabilities.raw.json").read_text()), raw)

    def test_approved_vex_pass_preserves_raw_and_fresh_filtered_reports(self):
        filtered = {"matches": [], "ignoredMatches": ACCEPTED_ONLY["matches"]}
        result = self.run_audit(ACCEPTED_ONLY, "--decoder", env_extra={
            "FAKE_IMAGE_ID": EVIDENCE["image"], "FAKE_VEX_REPORT": json.dumps(filtered)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = Path(self.tmp.name) / "output/audit/decoder"
        self.assertEqual(json.loads((out / "vulnerabilities.raw.json").read_text()), ACCEPTED_ONLY)
        self.assertEqual(json.loads((out / "vulnerabilities.json").read_text()), filtered)

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
