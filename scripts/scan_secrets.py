"""Scan exactly repository source, not ignored builds, secrets or generated reports."""
import pathlib
import shutil
import subprocess

root = pathlib.Path.cwd()
output = root / "output/secrets"
source = output / "source"
source.mkdir(parents=True, exist_ok=True)
files = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).decode().split("\0")
for name in files:
    path = root / name
    if name and path.is_file() and not path.is_symlink():
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
image = "zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
subprocess.run(["docker", "run", "--rm", "--network", "none", "--mount", f"type=bind,source={source},target=/repo,readonly",
    "--mount", f"type=bind,source={output},target=/out", image, "dir", "/repo", "--no-banner", "--redact", "--report-format", "json", "--report-path", "/out/gitleaks.json"], check=True)
