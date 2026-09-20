"""Inspect the exact local image; preserve all findings and fail closed. No Docker socket in scanners."""
import json
import pathlib
import subprocess
import sys
import urllib.request
from jsonschema import Draft7Validator
from referencing import Registry, Resource

SYFT = "anchore/syft:v1.52.0@sha256:500e2d872ac019436926e8322b4fc1f39441d94d21f6f4046c6ff29b30e8cb02"
GRYPE = "anchore/grype:v0.119.0@sha256:8c2c9234a345577a6d321a4753aa3ee1276d8975c8452d2344a56b57733ecad3"
SCHEMA_REV = "4b3f59453366e27c8073fd24e98bf21ef8892c8e"
image = sys.argv[1]
out = pathlib.Path("output/audit").resolve()
out.mkdir(parents=True, exist_ok=True)
mount = f"type=bind,source={out},target=/scan"
def run(*args):
    subprocess.run(args, check=True)
def capture(*args):
    return subprocess.check_output(args, text=True)

identity = json.loads(capture("docker", "image", "inspect", image))[0]
(out / "image-identity.json").write_text(json.dumps({k: identity[k] for k in ("Id", "Size", "Architecture", "Os")}, indent=2))
run("docker", "save", image, "-o", str(out / "image.tar"))
# Read only generated public build metadata; never environment/configuration.
hex_inventory = json.loads(capture("docker", "run", "--rm", "--network", "none", image, "cat", "/app/share/hex-components.json"))
run("docker", "run", "--rm", "--network", "none", "-e", "SYFT_CHECK_FOR_APP_UPDATE=false", "--mount", mount, SYFT,
    "docker-archive:/scan/image.tar", "-o", "cyclonedx-json=/scan/syft.cdx.json")
bom = json.loads((out / "syft.cdx.json").read_text())
assert bom["specVersion"] == "1.7"
bom["components"].extend(hex_inventory["components"])
bom.setdefault("dependencies", []).extend(hex_inventory["dependencies"])
app_ref = "pkg:generic/chat-overlay@0.1.0"
bom["components"].append({"type": "application", "name": "chat-overlay", "version": "0.1.0", "bom-ref": app_ref, "purl": app_ref})
refs = [c["bom-ref"] for c in bom["components"] if c["name"] in ("bandit", "mint", "mint_web_socket", "elixir", "erlang")]
bom["dependencies"].append({"ref": app_ref, "dependsOn": refs})
root = bom["metadata"]["component"]["bom-ref"]
root_dep = next((d for d in bom["dependencies"] if d["ref"] == root), None)
if root_dep is None:
    bom["dependencies"].append({"ref": root, "dependsOn": [app_ref]})
else:
    root_dep.setdefault("dependsOn", []).append(app_ref)
# Versioned upstream schemas; no arbitrary schema locations from the SBOM are fetched.
registry = Registry()
for name in ("bom-1.7.schema.json", "spdx.schema.json", "jsf-0.82.schema.json", "cryptography-defs.schema.json"):
    url = f"https://raw.githubusercontent.com/CycloneDX/specification/{SCHEMA_REV}/schema/{name}"
    with urllib.request.urlopen(url, timeout=30) as response:
        raw = response.read(4_000_000)
    (out / name).write_bytes(raw)
    schema = json.loads(raw)
    registry = registry.with_resource(schema.get("$id", "http://cyclonedx.org/schema/" + name), Resource.from_contents(schema))
    registry = registry.with_resource("http://cyclonedx.org/schema/" + name, Resource.from_contents(schema))
    if name == "bom-1.7.schema.json": main_schema = schema
Draft7Validator(main_schema, registry=registry).validate(bom)
(out / "image.cdx.json").write_text(json.dumps(bom, indent=2))
print(f"CycloneDX 1.7 schema valid: {len(bom['components'])} components; image {identity['Id']}", flush=True)
run("docker", "run", "--rm", "-e", "GRYPE_CHECK_FOR_APP_UPDATE=false", "--mount", mount, GRYPE,
    "sbom:/scan/image.cdx.json", "-o", "json", "--file", "/scan/vulnerabilities.json")
report = json.loads((out / "vulnerabilities.json").read_text())
for match in report["matches"]:
    print(match["vulnerability"]["id"], match["vulnerability"]["severity"], match["artifact"]["name"], match["artifact"]["version"])
print(f"Image findings: {len(report['matches'])}; no suppressions")
raise SystemExit(bool(report["matches"]))
