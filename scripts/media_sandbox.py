"""Operator-owned launcher. Never mount Docker or credentials into the decoder."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid

from media_validator import LIMITS, regular_bytes, validate_output


def normalize_isolated(data, category, image):
    if category not in LIMITS or not isinstance(data, bytes) or not 0 < len(data) <= LIMITS[category]:
        raise ValueError("invalid_input")
    # A mutable tag is insufficient to identify the decoder being run.
    if re.fullmatch(r"sha256:[0-9a-f]{64}", image) is None:
        raise ValueError("validator_requires_image_id")
    input_hash = hashlib.sha256(data).hexdigest()
    name = "chat-media-" + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="chat-media-") as directory:
        staging = Path(directory).resolve()
        source = staging / "blob"
        source.write_bytes(data)
        source.chmod(0o444)
        if "," in str(source):
            raise ValueError("unsupported_mount_path")
        deadline = time.monotonic() + 10

        def docker(*args, maximum=65536):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("validator_timeout")
            result = subprocess.run(["docker", *args], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=remaining, check=False)
            if result.returncode:
                raise ValueError("sandbox_command_failed: " + result.stderr[:512].decode("utf-8", "replace"))
            if len(result.stdout) > maximum or len(result.stderr) > 65536:
                raise ValueError("sandbox_command_failed")
            return result.stdout

        try:
            docker("run", "--detach", "--name", name, "--network", "none", "--read-only",
                "--user", "65532:65532", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                "--pids-limit", "32", "--memory", "256m", "--memory-swap", "256m", "--cpus", "1",
                "--log-driver", "json-file", "--log-opt", "max-size=64k", "--log-opt", "max-file=1",
                "--tmpfs", "/output:rw,noexec,nosuid,size=3m,uid=65532,gid=65532,mode=0700",
                "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m,uid=65532,gid=65532,mode=0700",
                "--mount", f"type=bind,source={source},target=/input/blob,readonly",
                image, category, input_hash, "--hold")
            while True:
                output = docker("logs", name)
                if output:
                    report = json.loads(output)
                    if report.get("ok") is False:
                        raise ValueError("decoder_rejected: " + str(report.get("error")))
                    break
                if docker("inspect", "--format", "{{.State.Running}}", name).strip() != b"true":
                    raise ValueError("validator_exited")
                time.sleep(0.05)
            result = docker("exec", name, "python3", "-I", "/validator.py", "--read-output", category,
                            maximum=LIMITS[category])
            metadata = validate_output(result, category)
            expected = {"input_sha256": input_hash, "output_sha256": hashlib.sha256(result).hexdigest(),
                        "size": len(result), "category": category, **metadata}
            if report != expected:
                raise ValueError("validator_report_mismatch")
            return result, expected
        finally:
            # The generated name addresses only this job; remove even on timeout or parser failure.
            removed = subprocess.run(["docker", "rm", "--force", name], stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=False)
            if removed.returncode != 0:
                raise ValueError("sandbox_cleanup_unconfirmed")
