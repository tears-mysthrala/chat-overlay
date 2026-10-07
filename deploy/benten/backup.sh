#!/bin/sh
# Operator-only, VM9502. The recipient certificate is public; no private key here.
set -eu
umask 077
recipient=${1:?public recipient certificate required}
test -f "$recipient"
root=/var/backups/chat-overlay
install -d -m 700 "$root"
run=$(mktemp -d "$root/external-XXXXXXXX")
backup_ready=0
test "$(docker inspect chat-overlay-overlay-1 --format '{{.State.Running}}')" = true
systemctl is-active --quiet chat-overlay-media.service
resume() {
  status=$?
  rm -f "$run/overlay.dump" "$run/roles.sql" "$run/image-id.txt" "$run/counts.txt" "$run/state.tar" "$run/SHA256SUMS" "$run/bundle.tar" || status=1
  if [ "$backup_ready" -ne 1 ]; then
    rm -f "$run/backup.cms" || status=1
  fi
  systemctl start chat-overlay-media.service || status=1
  (cd /opt/chat-overlay && docker compose start overlay </dev/null) >&2 || status=1
  exit "$status"
}
trap resume EXIT
trap 'exit 1' HUP INT TERM
cd /opt/chat-overlay
docker compose stop overlay </dev/null >&2
systemctl stop chat-overlay-media.service
docker exec -u postgres chat-overlay-postgres-1 pg_dump -U postgres -d overlay -Fc </dev/null > "$run/overlay.dump"
docker exec -u postgres chat-overlay-postgres-1 pg_dumpall -U postgres --roles-only </dev/null > "$run/roles.sql"
docker inspect chat-overlay-overlay-1 --format '{{.Image}}' > "$run/image-id.txt"
docker exec -u postgres chat-overlay-postgres-1 psql -U postgres -d overlay -Atc 'SELECT (SELECT count(*) FROM overlay.profiles), (SELECT count(*) FROM overlay.accounts), (SELECT count(*) FROM overlay.objects)' </dev/null > "$run/counts.txt"
tar -C / -cf "$run/state.tar" etc/chat-overlay opt/chat-overlay/compose.yaml opt/chat-overlay/media-62 var/lib/chat-overlay/media-local etc/systemd/system/chat-overlay-media.service
(cd "$run" && sha256sum overlay.dump roles.sql image-id.txt counts.txt state.tar > SHA256SUMS)
tar -C "$run" -cf "$run/bundle.tar" overlay.dump roles.sql image-id.txt counts.txt state.tar SHA256SUMS
openssl cms -encrypt -binary -aes-256-gcm -outform DER -recip "$recipient" -in "$run/bundle.tar" -out "$run/backup.cms"
test -s "$run/backup.cms"
chmod 600 "$run/backup.cms"
backup_ready=1
# Only the encrypted file and its checksum leave this private directory.
sha256sum "$run/backup.cms"
printf '%s\n' "$run/backup.cms"
