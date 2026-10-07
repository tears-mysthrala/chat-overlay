"""Linux shell regression; all service/encryption commands use synthetic stubs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BackupCleanupTests(unittest.TestCase):
    def exercise(self, failure):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'bin').mkdir()
            (root/'app').mkdir()
            (root/'recipient.pem').write_text('public fixture')
            script = (Path(__file__).parents[2]/'deploy/benten/backup.sh').read_text()
            script = script.replace('/var/backups/chat-overlay', str(root/'backups')).replace('/opt/chat-overlay', str(root/'app'))
            (root/'backup.sh').write_text(script)
            stubs = {
                'docker': 'echo docker "$@" >> "$CALL_LOG"; case "$1" in inspect) echo true;; exec) echo synthetic;; esac',
                'systemctl': 'echo systemctl "$@" >> "$CALL_LOG"',
                'tar': 'while [ "$#" -gt 0 ]; do if [ "$1" = -cf ]; then shift; echo synthetic > "$1"; exit; fi; shift; done',
                'openssl': 'while [ "$#" -gt 0 ]; do if [ "$1" = -out ]; then shift; echo ciphertext > "$1"; break; fi; shift; done; exit "$ENCRYPT_EXIT"',
            }
            for name, body in stubs.items():
                path = root/'bin'/name
                path.write_text('#!/bin/sh\n'+body+'\n')
                path.chmod(0o700)
            env = dict(os.environ, PATH=str(root/'bin')+os.pathsep+os.environ['PATH'], CALL_LOG=str(root/'calls'), ENCRYPT_EXIT='1' if failure else '0')
            result = subprocess.run(['sh', str(root/'backup.sh'), str(root/'recipient.pem')], env=env, capture_output=True)
            self.assertEqual(result.returncode != 0, failure)
            directories = list((root/'backups').glob('external-*'))
            self.assertEqual(len(directories), 1)
            self.assertEqual({p.name for p in directories[0].iterdir()}, set() if failure else {'backup.cms'})
            calls = (root/'calls').read_text()
            self.assertIn('systemctl start chat-overlay-media.service', calls)
            self.assertIn('compose start overlay', calls)

    def test_success_keeps_only_complete_ciphertext(self):
        self.exercise(False)

    def test_encryption_failure_removes_partial_ciphertext_and_plaintext(self):
        self.exercise(True)


if __name__ == '__main__':
    unittest.main()
