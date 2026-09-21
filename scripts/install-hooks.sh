#!/usr/bin/env bash
# Instala el hook pre-push versionado en este clon. Idempotente.
set -euo pipefail
hook_dir="$(git rev-parse --git-dir)/hooks"
mkdir -p "$hook_dir"
ln -sf ../../scripts/pre-push "$hook_dir/pre-push"
chmod +x scripts/pre-push
echo "hook pre-push instalado en $hook_dir/pre-push"
