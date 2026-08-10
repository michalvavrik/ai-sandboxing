#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devrebase_name=$(_dev_resolve_name "${1:-}")
readonly _devrebase_name

if ! _dev_container_exists "$_devrebase_name"; then
    echo "Error: container '${_devrebase_name}' does not exist" >&2
    exit 1
fi

_devrebase_was_stopped=false
if ! _dev_container_running "$_devrebase_name"; then
    _devrebase_was_stopped=true
    _dev_ensure_proxy
    podman start "$_devrebase_name" >/dev/null
    sleep 3
fi

_dev_update_ssh_config "$_devrebase_name"

readonly _devrebase_branch="dev-auto/${_devrebase_name}/main"

echo "Saving workspace..."
_dev_ssh_cmd "$_devrebase_name" \
    "cd /workspace; git add -A; git reset HEAD -- AGENTS.md CLAUDE.md GEMINI.md .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'pre-rebase save'; git push -f origin HEAD:refs/heads/${_devrebase_branch}" 2>/dev/null || true

echo "Fetching upstream main..."
if ! _dev_ssh_cmd "$_devrebase_name" "cd /workspace && git fetch upstream main"; then
    echo "Error: could not fetch upstream main" >&2
    [[ "$_devrebase_was_stopped" == true ]] && podman stop "$_devrebase_name" >/dev/null
    exit 1
fi

echo "Rebasing on upstream/main..."
if _dev_ssh_cmd "$_devrebase_name" "cd /workspace && git rebase upstream/main"; then
    _dev_ssh_cmd "$_devrebase_name" \
        "cd /workspace && git push -f origin HEAD:refs/heads/${_devrebase_branch}" 2>/dev/null || true
    echo "Rebase successful."
else
    _dev_ssh_cmd "$_devrebase_name" "cd /workspace && git rebase --abort" 2>/dev/null || true
    echo "Rebase aborted due to merge conflicts."
    echo "Your changes are safe on branch ${_devrebase_branch}."
fi

if [[ "$_devrebase_was_stopped" == true ]]; then
    podman stop "$_devrebase_name" >/dev/null
fi
