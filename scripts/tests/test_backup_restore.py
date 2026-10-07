import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('backup_checker', Path(__file__).parents[1]/'check_backup_restore.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class BackupAdmissionTests(unittest.TestCase):
    def bundle(self, directory, entries):
        path = directory/'input.tar'
        with tarfile.open(path, 'w') as archive:
            for name, value in entries:
                member = tarfile.TarInfo(name)
                if value is None:
                    member.type, member.linkname = tarfile.SYMTYPE, '/etc/passwd'
                    archive.addfile(member)
                else:
                    member.size = len(value)
                    archive.addfile(member, io.BytesIO(value))
        return path

    def test_path_escape_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = self.bundle(root, [('../outside', b'not trusted')])
            with self.assertRaisesRegex(ValueError, 'Invalid bundle members'):
                checker.check(bundle, root/'work')
            self.assertFalse((root/'outside').exists())

    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entries = [(name, None if name == 'roles.sql' else b'fixture') for name in checker.FILES]
            with self.assertRaisesRegex(ValueError, 'Invalid bundle member'):
                checker.check(self.bundle(root, entries), root/'work')

    def test_manifest_cannot_repeat_one_hash_and_omit_other_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = b'fixture'
            digest = hashlib.sha256(payload).hexdigest()
            manifest = ((digest + '  overlay.dump\n') * 5).encode()
            entries = [(name, manifest if name == 'SHA256SUMS' else payload) for name in checker.FILES]
            with self.assertRaisesRegex(ValueError, 'Backup checksum mismatch'):
                checker.check(self.bundle(root, entries), root/'work')


if __name__ == '__main__':
    unittest.main()
