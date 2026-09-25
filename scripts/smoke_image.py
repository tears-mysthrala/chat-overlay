"""Exercise the real release under production resource restrictions, on loopback only."""
import json
import pathlib
import subprocess
import sys
import time
import urllib.request

def capture(*args): return subprocess.check_output(args, text=True).strip()
container = capture("docker", "run", "-d", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges:true",
    "--pids-limit=128", "--memory=1g", "--cpus=2", "--init", "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m,mode=1777",
    "-p", "127.0.0.1::4100", "-e", "CHAT_CONFIG=/config/profiles.json", "-e", "ERL_FLAGS=+S 2:2 +P 32768 +Q 8192",
    "--mount", f"type=bind,source={pathlib.Path('config/demo.json').resolve()},target=/config/profiles.json,readonly", sys.argv[1])
try:
    info = json.loads(capture("docker", "inspect", container))[0]
    assert info["Config"]["User"] == "65532:65532"
    assert info["HostConfig"]["ReadonlyRootfs"] and info["HostConfig"]["CapDrop"] == ["ALL"]
    assert info["HostConfig"]["Memory"] == 1073741824 and info["HostConfig"]["PidsLimit"] == 128
    port = info["NetworkSettings"]["Ports"]["4100/tcp"][0]["HostPort"]
    base = f"http://127.0.0.1:{port}"
    for attempt in range(40):
        try:
            with urllib.request.urlopen(base + "/health/ready", timeout=2) as response:
                assert response.read() == b"ready"
            break
        except (OSError, AssertionError):
            if attempt == 39: raise
            time.sleep(0.25)
    with urllib.request.urlopen(base + "/reader/demo", timeout=3) as response:
        assert b'data-demo="true"' in response.read()
        assert "default-src 'none'" in response.headers["Content-Security-Policy"]
    with urllib.request.urlopen(base + "/events/demo", timeout=5) as response:
        lines = [response.readline() for _ in range(5)]
        assert any(b"event: batch" in line for line in lines)
    assert capture("docker", "exec", container, "id", "-u") == "65532"
    print("Release smoke PASS: readiness, demo, SSE, CSP, non-root, read-only, caps and resource limits")
finally:
    subprocess.run(["docker", "stop", "--timeout", "10", container], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["docker", "rm", container], check=True, stdout=subprocess.DEVNULL)
