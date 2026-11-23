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


def purl_package(purl):
    """(name, version) of an apk purl such as pkg:apk/alpine/busybox@1.37.0-r31?arch=x86_64."""
    require(isinstance(purl, str) and purl.startswith('pkg:apk/'), f'Not an apk package: {purl}')
    name, _, rest = purl.split('/')[-1].partition('@')
    version = rest.split('?')[0]
    require(name and version, f'Malformed package reference: {purl}')
    return name, version


def accepted_findings(root, today=None):
    """Findings the human approval of the decoder artifact accepts, read from the approved files.

    Each is (vulnerability, package, installed version). They expire with the approval; any
    unreadable, unapproved or inconsistent document raises instead of accepting anything.
    """
    today = today or datetime.datetime.now(datetime.timezone.utc).date()
    directory = root / 'docs/security'
    vex = json.loads((directory / 'vex-decoder.approved.json').read_text())
    evidence = json.loads((directory / 'decoder-evidence.approved.json').read_text())
    require(vex['approval']['status'] == 'approved', 'Decoder VEX not approved')
    require(evidence['status'] == 'approved', 'Decoder evidence not approved')
    require(vex['artifact_binding']['image'] == evidence['image'], 'Decoder approval documents disagree')
    require(today <= datetime.date.fromisoformat(evidence['review_due']), 'Decoder evidence expired')
    accepted = set()
    for statement in vex['statements']:
        require(today <= datetime.date.fromisoformat(statement['review_due']), 'Decoder VEX expired')
        for product in statement['products']:
            accepted.add((statement['vulnerability']['@id'], *purl_package(product['@id'])))
    require(accepted, 'Approved decoder documents accept nothing')
    return accepted


def classify_candidate(report, components, accepted):
    """Split a candidate scan into accepted and new findings, and approved packages that changed.

    A missing or empty scanner result is an error: the approved packages must still be found.
    """
    matches = report.get('matches') if isinstance(report, dict) else None
    require(isinstance(matches, list), 'Scanner result missing or invalid')
    require(matches, 'Scanner returned no findings although approved packages should match')
    found = set()
    for match in matches:
        found.add((match['vulnerability']['id'], match['artifact']['name'], match['artifact']['version']))
    versions = {}
    for component in components:
        purl = component.get('purl') or ''
        if purl.startswith('pkg:apk/'):
            name, version = purl_package(purl)
            versions.setdefault(name, set()).add(version)
    changed = sorted({(name, version, ','.join(sorted(versions.get(name, ()))) or 'absent')
                      for _, name, version in accepted if versions.get(name) != {version}})
    return {'accepted': sorted(found & accepted), 'new': sorted(found - accepted), 'changed': changed}
