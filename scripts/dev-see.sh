#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

readonly _devsee_name="${1:?'Usage: dev-see.sh <name>'}"
readonly _devsee_remote="dev-automation"

if ! _dev_container_exists "$_devsee_name"; then
    echo "Error: container '${_devsee_name}' does not exist" >&2
    exit 1
fi

if ! _dev_container_running "$_devsee_name"; then
    echo "Error: container '${_devsee_name}' is not running" >&2
    exit 1
fi

# Ensure SSH config is current
_dev_update_ssh_config "$_devsee_name"

# Push from container to a container-specific branch
readonly _devsee_branch="dev-auto/${_devsee_name}"
echo "Pushing changes to ${_devsee_branch}..."
_dev_ssh_cmd "$_devsee_name" \
    "cd /workspace && git add -A && git reset HEAD -- CLAUDE.md 2>/dev/null; git diff --cached --quiet || git commit -m 'WIP sync' && git push -f origin HEAD:refs/heads/${_devsee_branch}"
echo "Branch: ${_devsee_branch}"

# Get the remote URL from container labels
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

echo ""
git diff HEAD~1 | less
