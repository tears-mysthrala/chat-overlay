"""Exercise two real release processes with disposable synthetic credentials.

This checks the frontend boundary, not PostgreSQL or upstream OAuth. It creates
only uniquely named containers/network and removes those resources on exit.
"""
import argparse
import http.client
import json
import pathlib
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def docker(*args):
    result = subprocess.run(["docker", *args], capture_output=True)
    if result.returncode:
        raise RuntimeError("Isolation Docker command failed (output withheld)")
    return result.stdout.decode().strip()


def inspect(name):
    return json.loads(docker("inspect", name))[0]


def check(image, validation, output):
    image_id = inspect(image)["Id"]
    label = "custodian-check-" + secrets.token_hex(6)
    network, private, public = label, label + "-private", label + "-public"
    created = []
    with tempfile.TemporaryDirectory(prefix=label + "-") as temporary:
        root = pathlib.Path(temporary)
        profile = {"handle": "fixture", "sources": [
            {"platform": "twitch", "channel": "fixture", "mode": "demo"}]}
        (root / "profiles.json").write_text(json.dumps({"profiles": [profile]}))
        (root / "fixture.exs").write_text(
            '{:ok, _} = Application.ensure_all_started(:chat_overlay)\n'
            '{:ok, token} = ChatOverlay.Session.create_token(%{"handle" => "fixture"})\n'
            'File.write!("/tmp/session.txt", token)\n'
            'Process.sleep(:infinity)\n')
        certificate_script = """set -eu
cd /fixture
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config /dev/null -subj /CN=synthetic-ca -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign -keyout ca.key -out ca.crt
for name in server client; do
  usage=serverAuth; serial=2
  if [ "$name" = client ]; then usage=clientAuth; serial=3; fi
  openssl req -new -newkey rsa:2048 -nodes -config /dev/null -subj /CN=$name -keyout $name.key -out $name.csr
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=%s\nsubjectAltName=DNS:custodian.test\n' "$usage" > $name.ext
  openssl x509 -req -in $name.csr -CA ca.crt -CAkey ca.key -set_serial "$serial" -days 1 -extfile $name.ext -out $name.crt
done
chmod 755 /fixture
chmod 644 ca.crt server.crt client.crt profiles.json fixture.exs
chmod 600 ca.key server.key client.key
chown 65532:65532 server.key client.key
"""
        docker("run", "--rm", "--network", "none", "-v", f"{root}:/fixture",
               validation, "sh", "-c", certificate_script)
        try:
            docker("network", "create", network)
            created.append(("network", network))
            common = ["--detach", "--read-only", "--cap-drop", "ALL",
                      "--security-opt", "no-new-privileges", "--pids-limit", "128",
                      "--memory", "512m", "--cpus", "2", "--tmpfs", "/tmp",
                      "--network", network, "-e", "ERL_FLAGS=+S 2:2",
                      "-e", "CHAT_PUBLIC_ORIGIN=https://overlay.example.test",
                      "-e", "CHAT_CUSTODIAN_TLS_DIR=/tls"]
            mounts = []
            for name in ["ca.crt", "server.crt", "server.key"]:
                mounts += ["-v", f"{root / name}:/tls/{name}:ro"]
            docker("run", "--name", private, *common, *mounts,
                   "-v", f"{root}:/fixture:ro", "-e", "CHAT_ROLE=custodian",
                   "-e", "CHAT_STORAGE=json_demo", "-e", "CHAT_CONFIG=/fixture/profiles.json",
                   "-e", "CHAT_ENCRYPTION_KEY=" + secrets.token_hex(32), image_id,
                   "/app/bin/chat_overlay", "eval", 'Code.eval_file("/fixture/fixture.exs")')
            created.append(("container", private))
            address = inspect(private)["NetworkSettings"]["Networks"][network]["IPAddress"]
            mounts = []
            for name in ["ca.crt", "client.crt", "client.key"]:
                mounts += ["-v", f"{root / name}:/tls/{name}:ro"]
            docker("run", "--name", public, *common, *mounts, "--dns", "127.0.0.1",
                   "-p", "127.0.0.1::4100", "-e", "CHAT_ROLE=frontend",
                   "-e", "CHAT_CUSTODIAN_HOST=custodian.test",
                   "-e", "CHAT_CUSTODIAN_ADDRESS=" + address, image_id)
            created.append(("container", public))
            for _ in range(50):
                public_info = inspect(public)
                ports = public_info["NetworkSettings"]["Ports"].get("4100/tcp")
                if ports:
                    break
                if not public_info["State"]["Running"]:
                    raise RuntimeError("Frontend exited: " + docker("logs", public)[-2500:])
                time.sleep(0.1)
            else:
                raise RuntimeError("Frontend has no published port")
            port = ports[0]["HostPort"]
            base = "http://127.0.0.1:" + port
            for _ in range(60):
                try:
                    with urllib.request.urlopen(base + "/health/ready", timeout=2) as response:
                        if response.status == 200:
                            break
                except (urllib.error.URLError, TimeoutError, http.client.RemoteDisconnected):
                    time.sleep(0.2)
            else:
                raise RuntimeError("Separated release did not become ready")
            token = docker("exec", private, "cat", "/tmp/session.txt")
            request = urllib.request.Request(base + "/api/profiles", headers={
                "Cookie": "chat_overlay_session=" + token})
            with urllib.request.urlopen(request, timeout=5) as response:
                profiles = json.load(response)
            if "fixture" not in json.dumps(profiles):
                raise RuntimeError("Private profile was not returned through authenticated RPC")
            public_env = {item.split("=", 1)[0] for item in public_info["Config"]["Env"]}
            forbidden = {"CHAT_ENCRYPTION_KEY", "CHAT_CONFIG", "CHAT_DB_RUNTIME_PASSWORD",
                         "TWITCH_CLIENT_SECRET", "GOOGLE_CLIENT_SECRET", "MEDIA_COORDINATOR_TOKEN"}
            assert not public_env & forbidden
            assert {item["Destination"] for item in public_info["Mounts"]} == {
                "/tls/ca.crt", "/tls/client.crt", "/tls/client.key"}
            assert public_info["Config"]["User"] == "65532:65532"
            assert public_info["HostConfig"]["ReadonlyRootfs"]
            assert public_info["HostConfig"]["PidMode"] != "host"
            assert not any(inspect(private)["NetworkSettings"]["Ports"].values())
            assert docker("exec", public, "readlink", "/proc/1/ns/pid") != docker(
                "exec", private, "readlink", "/proc/1/ns/pid")
            docker("stop", "--timeout", "3", private)
            try:
                urllib.request.urlopen(request, timeout=8)
                raise AssertionError("Frontend fell back to local private state")
            except urllib.error.HTTPError as error:
                assert error.code == 503
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps({"image": image_id, "separate_pid_namespaces": True,
                "frontend_without_private_credentials_or_state": True,
                "authenticated_profile_rpc": True, "private_port_unpublished": True,
                "failure_without_local_fallback": True,
                "scope": "synthetic JSON release; guest firewall, upstream OAuth, PostgreSQL and media NOT TESTED"}, indent=2))
            print("Separated release isolation: PASS (synthetic fixtures)")
        finally:
            for kind, name in reversed(created):
                subprocess.run(["docker", kind, "rm", "-f", name] if kind == "container"
                               else ["docker", "network", "rm", name], capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--validation", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    check(args.image, args.validation, args.output)
