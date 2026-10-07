"""First installation only: generate private credentials on the dedicated guest."""
import os
import pathlib
import secrets
import subprocess

os.umask(0o077)
root = pathlib.Path('/etc/chat-overlay')
root.mkdir(mode=0o700, exist_ok=True)
if (root / 'runtime.env').exists():
    raise SystemExit('Already provisioned: preserve keys and data; do not overwrite')
runtime, bootstrap, migrator, admin = [secrets.token_hex(32) for _ in range(4)]
(root / 'runtime.env').write_text(
    f'CHAT_ENCRYPTION_KEY={secrets.token_hex(32)}\n'
    f'CHAT_DB_RUNTIME_PASSWORD={runtime}\nCHAT_DB_BOOTSTRAP_PASSWORD={bootstrap}\n')
(root / 'postgres-admin').write_text(admin)
sql = ''
for role, password in [('overlay_migrator', migrator), ('overlay_runtime', runtime), ('overlay_bootstrap', bootstrap)]:
    sql += f"CREATE ROLE {role} LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '{password}';\n"
sql += 'ALTER DATABASE overlay OWNER TO overlay_migrator;\nSET ROLE overlay_migrator;\n'
sql += pathlib.Path('/opt/chat-overlay/priv/postgres/001_rls.sql').read_text()
(root / 'init.sql').write_text(sql)
for name in ('postgres-admin', 'init.sql'):
    os.chown(root / name, 70, 70)
(root / 'migrator-password').write_text(migrator)
tls = root / 'tls'
tls.mkdir(mode=0o700, exist_ok=True)
def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
run('openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '365',
    '-subj', '/CN=chat-overlay-private-ca', '-keyout', str(tls/'ca.key'), '-out', str(tls/'ca.crt'))
run('openssl', 'req', '-newkey', 'rsa:3072', '-nodes', '-subj', '/CN=postgres',
    '-keyout', str(tls/'server.key'), '-out', str(tls/'server.csr'))
(tls/'server.ext').write_text('subjectAltName=DNS:postgres\nextendedKeyUsage=serverAuth\n')
run('openssl', 'x509', '-req', '-in', str(tls/'server.csr'), '-CA', str(tls/'ca.crt'),
    '-CAkey', str(tls/'ca.key'), '-CAcreateserial', '-days', '90',
    '-extfile', str(tls/'server.ext'), '-out', str(tls/'server.crt'))
(tls/'ca-bundle.crt').write_bytes(pathlib.Path('/etc/ssl/certs/ca-certificates.crt').read_bytes() + (tls/'ca.crt').read_bytes())
for name in ('server.crt','ca-bundle.crt'):
    os.chmod(tls/name, 0o644)
os.chown(tls/'server.key', 70, 70)
os.chmod(tls/'server.key', 0o600)
print('Private credentials and PostgreSQL TLS provisioned; no secrets emitted.')
