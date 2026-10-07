"""Operator-only offline compaction. No object bytes or live ledger entries deleted.

Requires stopped app/coordinator and a PostgreSQL ledger exported after stopping.
Reject ambiguous/in-progress work. Never expose this operation through HTTP.
"""
import argparse
import hashlib
import json
import os
import sqlite3
import stat

from local_media_store import Disk


def compact(root, ledger, writers_stopped=False):
    if not writers_stopped:
        raise ValueError('writers_must_be_stopped')
    if not isinstance(ledger, list):
        raise ValueError('invalid_ledger')
    active = {}
    for item in ledger:
        if item.get('backend') != 'local':
            continue
        if item.get('state') != 'active' or item.get('bucket') != 'public':
            raise ValueError('ledger_not_settled')
        if item['key'] in active:
            raise ValueError('duplicate_ledger_key')
        active[item['key']] = item
    disk = Disk(root)
    try:
        path = os.path.join(root, 'jobs.sqlite')
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('unsafe_journal')
        disk.db.execute('ATTACH DATABASE ? AS jobs', (path,))
        for name in ('main', 'jobs'):
            if disk.db.execute(f'PRAGMA {name}.journal_mode').fetchone()[0] != 'delete':
                raise ValueError('unsupported_journal_mode')
        disk.db.execute('BEGIN IMMEDIATE')
        if disk.db.execute('SELECT count(*) FROM jobs.uncertain').fetchone()[0]:
            raise ValueError('uncertain_jobs')
        if disk.db.execute('SELECT count(*) FROM jobs.cancelled').fetchone()[0]:
            raise ValueError('cancelled_jobs_need_reconciliation')
        rows = disk.db.execute('SELECT bucket,key,size,deleted FROM objects').fetchall()
        live = {key for bucket, key, size, deleted in rows if not deleted}
        if live != set(active):
            raise ValueError('live_inventory_mismatch')
        for key, item in active.items():
            status, data = disk.request('public', 'GET', key)
            if status != 200 or len(data) != item['size'] or hashlib.sha256(data).hexdigest() != key.rsplit('/', 1)[1].split('.')[0]:
                raise ValueError('active_object_changed')
        for bucket, key, size, deleted in rows:
            if deleted:
                name = hashlib.sha256(key.encode()).hexdigest()
                try:
                    os.stat(name, dir_fd=disk.directories[bucket], follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise ValueError('deleted_bytes_still_present')
        jobs = disk.db.execute('SELECT id,request,result FROM jobs.jobs').fetchall()
        for job_id, request, result in jobs:
            if result is None:
                raise ValueError('unfinished_job')
            job, output = json.loads(request), json.loads(result)
            if disk.request('quarantine', 'GET', job['key'])[0] != 404:
                raise ValueError('quarantine_not_drained')
            if output['key'] not in active or output['key'].split('/')[-2] != job_id or job['job'] != job_id:
                raise ValueError('job_not_in_settled_ledger')
        # A single SQLite transaction spans both attached DELETE-mode databases.
        disk.db.execute('DELETE FROM objects WHERE deleted=1')
        if disk.db.execute("SELECT 1 FROM jobs.sqlite_master WHERE name='artifacts'").fetchone():
            disk.db.execute('DELETE FROM jobs.artifacts WHERE id IN (SELECT id FROM jobs.jobs)')
        disk.db.execute('DELETE FROM jobs.jobs')
        disk.db.commit()
        return {'removed_jobs': len(jobs), 'removed_tombstones': sum(row[3] for row in rows), 'retained_live_objects': len(active)}
    except Exception:
        disk.db.rollback()
        raise
    finally:
        disk.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root')
    parser.add_argument('settled_ledger')
    parser.add_argument('--writers-stopped', action='store_true')
    args = parser.parse_args()
    with open(args.settled_ledger) as stream:
        ledger = json.load(stream)
    print(json.dumps(compact(args.root, ledger, args.writers_stopped)))
