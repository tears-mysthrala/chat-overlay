#!/usr/bin/env bash
set -euo pipefail
# No platform connectivity or mounted operator configuration; disposable state only.
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'CI-only browser fixture'; exit 2; }
fixture="overlay-browser-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
network="${fixture}-internal"
proxy_pid=""
cleanup() {
  if [[ -n "$proxy_pid" ]]; then kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; fi
  docker rm -f "$fixture" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create --internal "$network" >/dev/null
docker run -d --name "$fixture" --network "$network" \
  --read-only --tmpfs /tmp:rw,nosuid,noexec,size=64m \
  --cpus 2 --memory 1g --pids-limit 128 --cap-drop ALL \
  --security-opt no-new-privileges -e ERL_FLAGS='+S 2:2' \
  -e BROWSER_FIXTURE_CONTAINER=1 -e ERL_CRASH_DUMP=/dev/null \
  chat-overlay:validation mix run --no-compile --no-deps-check --no-start --no-halt \
  scripts/browser_fixture.exs /tmp/browser-fixture >/dev/null

fixture_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$fixture")"
node scripts/browser_fixture_proxy.js "$fixture_ip" &
proxy_pid=$!

ready=false
for attempt in {1..60}; do
  if curl --noproxy '*' --silent --fail --max-time 1 http://127.0.0.1:4143/ >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || { echo 'Synthetic browser fixture did not become ready'; exit 1; }
npm run test:browser:ci
