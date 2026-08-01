#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devsee_name=$(_dev_resolve_name "${1:-}")
readonly _devsee_name
readonly _devsee_remote="dev-automation"

if ! _dev_container_exists "$_devsee_name"; then
    echo "Error: container '${_devsee_name}' does not exist" >&2
    exit 1
fi

_devsee_was_stopped=false
if ! _dev_container_running "$_devsee_name"; then
    _devsee_was_stopped=true
    _dev_ensure_proxy
    podman start "$_devsee_name" >/dev/null
    sleep 3
fi

_dev_update_ssh_config "$_devsee_name"

readonly _devsee_branch="dev-auto/${_devsee_name}/main"
echo "Pushing changes to ${_devsee_branch}..."
_dev_ssh_cmd "$_devsee_name" \
    "cd /workspace && git add -A && git reset HEAD -- CLAUDE.md .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'WIP sync' && git push -f origin HEAD:refs/heads/${_devsee_branch}"
echo "Branch: ${_devsee_branch}"

_devsee_template_key=$(podman inspect --format '{{index .Config.Labels "dev-template-key"}}' "$_devsee_name" 2>/dev/null) || true
_devsee_repo="${_devsee_template_key#*/}"

if [[ -z "$_devsee_repo" ]]; then
    echo "Error: could not determine project from container labels" >&2
    exit 1
fi

readonly _devsee_remote_url="git@github.com:${DEV_AUTOMATION_USER}/${_devsee_repo}.git"

if ! git remote get-url "$_devsee_remote" &>/dev/null; then
    echo "Adding remote '${_devsee_remote}' -> ${_devsee_remote_url}"
    git remote add "$_devsee_remote" "$_devsee_remote_url"
elif [[ "$(git remote get-url "$_devsee_remote")" != "$_devsee_remote_url" ]]; then
    git remote set-url "$_devsee_remote" "$_devsee_remote_url"
fi

echo "Fetching from ${_devsee_remote}..."
git fetch "$_devsee_remote"

git checkout -B "$_devsee_branch" "${_devsee_remote}/${_devsee_branch}"

if [[ "$_devsee_was_stopped" == true ]]; then
    podman stop "$_devsee_name" >/dev/null
fi

echo ""
git diff HEAD~1 | less
