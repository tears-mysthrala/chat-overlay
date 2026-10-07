"""Fail closed before applying the human-approved, image-specific decoder VEX."""
import datetime
import hashlib
import json
import subprocess


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_binding(vex, evidence, identity, root, runtime_hashes, today=None):
    today = today or datetime.datetime.now(datetime.timezone.utc).date()
    require(vex['approval']['status'] == 'approved', 'Decoder VEX not approved')
    require(evidence['status'] == 'approved', 'Decoder evidence not approved')
    require(identity['Id'] == evidence['image'] == vex['artifact_binding']['image'], 'Decoder image changed')
    require(identity['Architecture'] == evidence['architecture'], 'Decoder architecture changed')
    require(today <= datetime.date.fromisoformat(evidence['review_due']), 'Decoder evidence expired')
    require(vex['statements'], 'Empty decoder VEX')
    for statement in vex['statements']:
        require(today <= datetime.date.fromisoformat(statement['review_due']), 'Decoder VEX expired')
    for name, expected in evidence['repository_sha256'].items():
        require(hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, f'Decoder source changed: {name}')
    require(runtime_hashes == evidence['runtime_sha256'], 'Decoder runtime changed')


def verified_document(root, identity):
    directory = root / 'docs/security'
    vex = json.loads((directory / 'vex-decoder.approved.json').read_text())
    evidence = json.loads((directory / 'decoder-evidence.approved.json').read_text())
    # Read exact image files in an offline, unprivileged, readonly container.
    code = ('import hashlib,json,pathlib; paths=' + repr(list(evidence['runtime_sha256'])) +
            '; print(json.dumps({p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths}))')
    runtime = json.loads(subprocess.check_output([
        'docker', 'run', '--rm', '--network', 'none', '--read-only',
        '--user', '65532:65532', '--cap-drop', 'ALL', '--security-opt',
        'no-new-privileges', '--pids-limit', '32', '--memory', '256m',
        '--memory-swap', '256m', '--cpus', '1', '--entrypoint', 'python3',
        identity['Id'], '-I', '-c', code], text=True))
    validate_binding(vex, evidence, identity, root, runtime)
    return vex
