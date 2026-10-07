"""Restore an already-authenticated bundle in a networkless throwaway database.

The operator must put work under a private directory. No credentials are logged.
Never point this checker at a production container or database.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sqlite3
import subprocess
import tarfile
import time
import uuid

IMAGE = 'postgres:18.6-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873'
FILES = {'overlay.dump', 'roles.sql', 'image-id.txt', 'counts.txt', 'state.tar', 'SHA256SUMS'}
PRIVATE_LOG = None

def run(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        if PRIVATE_LOG is not None:
            PRIVATE_LOG.write_bytes(result.stderr + result.stdout)
        raise RuntimeError('Restore command failed; private diagnostics retained by operator')
    return result.stdout

def check(bundle, work):
    global PRIVATE_LOG
    work.mkdir(mode=0o700, parents=False, exist_ok=False)
    PRIVATE_LOG = work/'restore-error.log'
    with tarfile.open(bundle) as archive:
        members = archive.getmembers()
        if {m.name for m in members} != FILES or len(members) != len(FILES):
            raise ValueError('Invalid bundle members')
        for member in members:
            if not member.isfile() or not 0 < member.size <= 1073741824:
                raise ValueError('Invalid bundle member')
            with archive.extractfile(member) as source:
                (work / member.name).write_bytes(source.read())
    entries = (work / 'SHA256SUMS').read_text().splitlines()
    if len(entries) != 5:
        raise ValueError('Incomplete manifest')
    checked = set()
    for line in entries:
        digest, name = line.split('  ', 1)
        if name in checked or name not in FILES - {'SHA256SUMS'} or hashlib.sha256((work/name).read_bytes()).hexdigest() != digest:
            raise ValueError('Backup checksum mismatch')
        checked.add(name)
    media_count = 0
    with tarfile.open(work/'state.tar') as state:
        index = state.extractfile('var/lib/chat-overlay/media-local/objects.sqlite').read()
        (work/'objects.sqlite').write_bytes(index)
        db = sqlite3.connect(work/'objects.sqlite')
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Invalid media SQLite')
        for bucket, key, size in db.execute('SELECT bucket,key,size FROM objects WHERE deleted=0'):
            if bucket not in ('public', 'quarantine'):
                raise ValueError('Invalid media bucket')
            name = hashlib.sha256(key.encode()).hexdigest()
            data = state.extractfile(f'var/lib/chat-overlay/media-local/{bucket}/{name}').read()
            if len(data) != size or bucket == 'public' and hashlib.sha256(data).hexdigest() != key.rsplit('/', 1)[1].split('.')[0]:
                raise ValueError('Invalid restored media')
            media_count += 1
        db.close()
        for name in ('etc/chat-overlay/runtime.env', 'etc/chat-overlay/media-coordinator.env', 'etc/chat-overlay/tls/server.key'):
            if not state.getmember(name).isfile():
                raise ValueError('Missing recovery configuration')
        (work/'runtime.env').write_bytes(state.extractfile('etc/chat-overlay/runtime.env').read())
    # PostgreSQL already has its bootstrap role. Preserve all remaining statements.
    roles = (work/'roles.sql').read_text()
    (work/'roles.restore.sql').write_text(roles.replace('CREATE ROLE postgres;\n', ''))
    container = 'overlay-restore-' + uuid.uuid4().hex[:12]
    try:
        run('docker', 'run', '-d', '--name', container, '--network', 'none', '--memory', '512m', '--cpus', '1', '--pids-limit', '128', '--security-opt', 'no-new-privileges:true', '--tmpfs', '/var/lib/postgresql:rw,nosuid,size=256m', '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', IMAGE)
        for _ in range(40):
            ready = subprocess.run(['docker', 'exec', container, 'pg_isready', '-U', 'postgres'], capture_output=True)
            if ready.returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError('Isolated PostgreSQL did not start')
        for name in ('roles.restore.sql', 'overlay.dump'):
            run('docker', 'cp', str(work/name), f'{container}:/tmp/{name}')
        run('docker', 'exec', container, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-f', '/tmp/roles.restore.sql')
        run('docker', 'exec', container, 'createdb', '-U', 'postgres', 'overlay')
        run('docker', 'exec', container, 'pg_restore', '-U', 'postgres', '--exit-on-error', '-d', 'overlay', '/tmp/overlay.dump')
        counts = run('docker', 'exec', container, 'psql', '-U', 'postgres', '-d', 'overlay', '-Atc', 'SELECT (SELECT count(*) FROM overlay.profiles), (SELECT count(*) FROM overlay.accounts), (SELECT count(*) FROM overlay.objects)').decode().strip()
        if counts != (work/'counts.txt').read_text().strip():
            raise ValueError('Restored counts mismatch')
        rls = run('docker', 'exec', container, 'psql', '-U', 'postgres', '-d', 'overlay', '-Atc', "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='overlay' AND c.relname IN ('profiles','accounts','objects') AND c.relrowsecurity AND c.relforcerowsecurity").decode().strip()
        if rls != '3':
            raise ValueError('Restored RLS missing')
        accounts = run('docker', 'exec', container, 'psql', '-U', 'postgres', '-d', 'overlay', '-Atc', "SELECT coalesce(json_agg(json_build_object('handle',handle,'provider',provider,'body',body::json)), '[]'::json) FROM overlay.accounts")
        (work/'accounts.json').write_bytes(accounts)
        evaluation = '''
        accounts = case ChatOverlay.JSON.decode(File.read!("/restore/accounts.json")) do
          {:ok, values} when is_list(values) -> values
          _ -> raise "Restored account document invalid"
        end
        Enum.each(accounts, fn account ->
          aad = "token:" <> account["handle"] <> ":" <> account["provider"]
          case ChatOverlay.Crypto.decrypt_aead(account["body"]["encrypted_tokens"], ChatOverlay.OAuth.encryption_key(), aad) do
            {:ok, plaintext} ->
              case ChatOverlay.JSON.decode(plaintext) do
                {:ok, tokens} when is_map(tokens) -> :ok
                _ -> raise "Restored token format invalid"
              end
            _ -> raise "Restored account authentication failed"
          end
        end)
        IO.puts("Restored account decryption PASS")
        '''
        app_image = (work/'image-id.txt').read_text().strip()
        if not re.fullmatch(r'sha256:[a-f0-9]{64}', app_image):
            raise ValueError('Invalid pinned application image')
        run('docker', 'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true', '--memory', '512m', '--pids-limit', '128', '--env-file', str(work/'runtime.env'), '-e', 'CHAT_STORAGE=json_demo', '--mount', f'type=bind,source={work.resolve()},target=/restore,readonly', app_image, '/app/bin/chat_overlay', 'eval', evaluation)
        result = {'database_restore': 'PASS', 'counts': counts, 'rls_tables': 3, 'media_objects_verified': media_count, 'account_decryption': 'PASS', 'network': 'none', 'product_upstream': 'NOT TESTED'}
        (work/'result.json').write_text(json.dumps(result))
        print(json.dumps(result))
    finally:
        subprocess.run(['docker', 'rm', '-f', container], capture_output=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('authenticated_bundle', type=pathlib.Path)
    parser.add_argument('private_work_directory', type=pathlib.Path)
    args = parser.parse_args()
    check(args.authenticated_bundle, args.private_work_directory)
