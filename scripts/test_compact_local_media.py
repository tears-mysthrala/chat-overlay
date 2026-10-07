import hashlib
import json
import os
import sqlite3
import tempfile
import unittest

from compact_local_media import compact
from local_media_store import Disk


class MaintenanceTests(unittest.TestCase):
    def fixture(self, root):
        data = b'normalized synthetic image'
        job = 'a'*32
        key = 'alice/validated/'+job+'/'+hashlib.sha256(data).hexdigest()+'.png'
        original = 'alice/image/'+'b'*32+'_input.png'
        disk = Disk(root, free_reserve=0)
        disk.request('public', 'PUT', key, data, 'image/png')
        disk.request('quarantine', 'DELETE', original)
        disk.close()
        path = os.path.join(root, 'jobs.sqlite')
        db = sqlite3.connect(path)
        os.chmod(path, 0o600)
        db.executescript('CREATE TABLE jobs(id TEXT PRIMARY KEY,request TEXT,result TEXT); CREATE TABLE uncertain(id TEXT); CREATE TABLE cancelled(id TEXT); CREATE TABLE artifacts(id TEXT,result TEXT);')
        request = json.dumps({'job':job,'key':original})
        result = json.dumps({'key':key})
        db.execute('INSERT INTO jobs VALUES (?,?,?)', (job,request,result))
        db.execute('INSERT INTO artifacts VALUES (?,?)', (job,result))
        db.commit()
        db.close()
        return [{'backend':'local','bucket':'public','state':'active','key':key,'size':len(data)}]

    def test_compaction_preserves_live_bytes_and_removes_only_settled_records(self):
        with tempfile.TemporaryDirectory() as root:
            ledger = self.fixture(root)
            result = compact(root, ledger, True)
            self.assertEqual(result, {'removed_jobs':1,'removed_tombstones':1,'retained_live_objects':1})
            disk = Disk(root)
            self.assertEqual(disk.request('public','GET',ledger[0]['key'])[0],200)
            disk.close()
            db = sqlite3.connect(os.path.join(root,'jobs.sqlite'))
            self.assertEqual(db.execute('SELECT count(*) FROM artifacts').fetchone()[0],0)
            db.close()

    def test_ambiguous_work_rolls_back_everything(self):
        with tempfile.TemporaryDirectory() as root:
            ledger = self.fixture(root)
            db = sqlite3.connect(os.path.join(root,'jobs.sqlite'))
            db.execute('INSERT INTO uncertain VALUES (?)', ('a'*32,))
            db.commit()
            db.close()
            with self.assertRaisesRegex(ValueError,'uncertain_jobs'):
                compact(root,ledger,True)
            db = sqlite3.connect(os.path.join(root,'objects.sqlite'))
            self.assertEqual(db.execute('SELECT count(*) FROM objects WHERE deleted=1').fetchone()[0],1)
            db.close()

    def test_no_implicit_writer_stop_and_no_pending_ledger(self):
        with tempfile.TemporaryDirectory() as root:
            ledger = self.fixture(root)
            with self.assertRaisesRegex(ValueError,'writers_must_be_stopped'):
                compact(root,ledger)
            ledger[0]['state']='pending'
            with self.assertRaisesRegex(ValueError,'ledger_not_settled'):
                compact(root,ledger,True)


if __name__ == '__main__':
    unittest.main()
