"""Public provenance and checksums for locally built decoder components."""
import hashlib
import json
from pathlib import Path
import subprocess

revision = "e5a08f7c0e45e6d278a394ef19c97f0b8ad3ed45"
version = subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0].split()[2]
ref = f"pkg:generic/ffmpeg@{version}%2B{revision}"
component = {"type": "application", "name": "ffmpeg", "version": version + "+" + revision,
             "bom-ref": ref, "purl": ref,
             "externalReferences": [{"type": "vcs", "url": "https://github.com/FFmpeg/FFmpeg/commit/" + revision}],
             "hashes": [{"alg": "SHA-256", "content": hashlib.sha256(Path("/usr/local/bin/ffmpeg").read_bytes()).hexdigest()}]}
files = {name: hashlib.sha256(Path("/usr/lib/python3.14", name + ".py").read_bytes()).hexdigest()
         for name in ("poplib", "tarfile", "tempfile", "shutil")}
Path("/usr/share/media-components.json").write_text(json.dumps({"components": [component], "python_patched_files": files}))
