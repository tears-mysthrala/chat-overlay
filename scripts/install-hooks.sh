#!/usr/bin/env bash
# Instala el hook pre-push versionado en este clon. Idempotente.
set -euo pipefail
repo_root="$(git rev-parse --show-toplevel)"
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
hook_dir="$common_dir/hooks"
mkdir -p "$hook_dir"
git config --local core.hooksPath "$hook_dir"
ln -sf "$repo_root/scripts/pre-push" "$hook_dir/pre-push"
chmod +x "$repo_root/scripts/pre-push"
echo "hook pre-push instalado en $hook_dir/pre-push"
