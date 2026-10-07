"""Negative controls for image-specific VEX authorization and integrity."""
import copy
import datetime
import json
import pathlib
import unittest
from decoder_vex import validate_binding


class BindingTest(unittest.TestCase):
    def test_approval_expiry_and_tampering(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        directory = root / 'docs/security'
        vex = json.loads((directory / 'vex-decoder.approved.json').read_text())
        evidence = json.loads((directory / 'decoder-evidence.approved.json').read_text())
        identity = {'Id': evidence['image'], 'Architecture': evidence['architecture']}
        runtime = evidence['runtime_sha256']
        today = datetime.date(2026, 10, 7)
        validate_binding(vex, evidence, identity, root, runtime, today)
        for kind in ('approval', 'image', 'architecture', 'runtime', 'source', 'expired'):
            with self.subTest(kind=kind):
                v, e, i, r = map(copy.deepcopy, (vex, evidence, identity, runtime))
                date = today
                if kind == 'approval': v['approval']['status'] = 'pending'
                if kind == 'image': i['Id'] = 'sha256:' + '0' * 64
                if kind == 'architecture': i['Architecture'] = 'arm64'
                if kind == 'runtime': r['/validator.py'] = '0' * 64
                if kind == 'source': e['repository_sha256']['scripts/media_sandbox.py'] = '0' * 64
                if kind == 'expired': date = datetime.date(2026, 10, 22)
                with self.assertRaises(ValueError):
                    validate_binding(v, e, i, root, r, date)


if __name__ == '__main__':
    unittest.main()
