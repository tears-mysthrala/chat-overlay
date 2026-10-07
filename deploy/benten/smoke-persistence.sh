#!/bin/sh
# New installation only; temporary synthetic profile, no upstream calls.
set -eu
cd /opt/chat-overlay
trap 'docker compose up -d overlay' EXIT
docker compose stop overlay
docker compose run --rm -T --no-deps overlay /app/bin/chat_overlay eval '
Application.put_env(:chat_overlay, :http, false)
{:ok, _} = Application.ensure_all_started(:chat_overlay)
nil = ChatOverlay.Config.profile("deployment-smoke")
{:ok, _} = ChatOverlay.Profiles.create_or_update(%{"handle" => "deployment-smoke", "sources" => [%{"platform" => "twitch", "channel" => "deployment-smoke", "mode" => "demo"}]})
IO.puts("Product durable mutation PASS")
'
docker compose up -d overlay
sleep 3
curl -fsS http://127.0.0.1:4100/reader/deployment-smoke >/dev/null
docker compose restart postgres
sleep 5
docker compose restart overlay
sleep 3
curl -fsS http://127.0.0.1:4100/reader/deployment-smoke >/dev/null
docker compose stop overlay
docker compose run --rm -T --no-deps overlay /app/bin/chat_overlay eval '
Application.put_env(:chat_overlay, :http, false)
{:ok, _} = Application.ensure_all_started(:chat_overlay)
%{"handle" => "deployment-smoke"} = ChatOverlay.Config.profile("deployment-smoke")
:ok = ChatOverlay.Profiles.delete("deployment-smoke")
IO.puts("Product persistence after DB/product restart and cleanup PASS")
'
docker compose up -d overlay
