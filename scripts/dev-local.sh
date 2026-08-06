#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository" >&2
    exit 1
fi

_devlocal_template_key=$(_dev_detect_template_from_cwd) || true
if [[ -z "$_devlocal_template_key" ]]; then
    echo "Error: no project template matches the current directory" >&2
    echo "Add a template to configs/project-templates.conf or use 'dev new <name>' instead." >&2
    exit 1
fi

_devlocal_repo="${_devlocal_template_key#*/}"

_devlocal_branch=$(git branch --show-current 2>/dev/null)
if [[ -z "$_devlocal_branch" ]]; then
    echo "Error: detached HEAD — check out a branch first" >&2
    exit 1
fi

if [[ "$_devlocal_branch" =~ ^dev-auto/([^/]+) ]]; then
    _devlocal_name="${BASH_REMATCH[1]}"
else
    _devlocal_sanitized="${_devlocal_branch//\//-}"
    _devlocal_sanitized="${_devlocal_sanitized#-}"
    if [[ "$_devlocal_sanitized" == "${_devlocal_repo}" || "$_devlocal_sanitized" == "${_devlocal_repo}-"* ]]; then
        _devlocal_name="$_devlocal_sanitized"
    else
        _devlocal_name="${_devlocal_repo}-${_devlocal_sanitized}"
    fi
fi

if (( ${#_devlocal_name} > 40 )); then
    _devlocal_name="${_devlocal_name:0:40}"
    _devlocal_name="${_devlocal_name%-}"
fi

readonly _devlocal_name
readonly _devlocal_push_branch="dev-auto/${_devlocal_name}/main"
readonly _devlocal_git_ssh="ssh -i ${DEV_KEYS_DIR}/id_ed25519_dev_automation -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"

echo "Project: ${_devlocal_template_key}"
echo "Branch: ${_devlocal_branch}"
echo "Container: ${_devlocal_name}"
echo "$_devlocal_name" > "/run/user/$(id -u)/dev-last-container"

_devlocal_had_wip=false
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "Including uncommitted changes..."
    git add -A
    git commit --quiet -m "WIP" --no-verify
    _devlocal_had_wip=true
fi

echo "Pushing to ${DEV_AUTOMATION_USER}/${_devlocal_repo} branch ${_devlocal_push_branch}..."
GIT_SSH_COMMAND="$_devlocal_git_ssh" \
    git push -f \
    "git@github.com:${DEV_AUTOMATION_USER}/${_devlocal_repo}.git" \
    "HEAD:refs/heads/${_devlocal_push_branch}" || {
        if [[ "$_devlocal_had_wip" == true ]]; then
            git reset --quiet HEAD~1
        fi
        exit 1
    }

if [[ "$_devlocal_had_wip" == true ]]; then
    git reset --quiet HEAD~1
fi

# Existing container — refresh and re-enter
if _dev_container_exists "$_devlocal_name"; then
    _dev_ensure_proxy

    if ! _dev_container_running "$_devlocal_name"; then
        podman start "$_devlocal_name"
        sleep 3
    fi

    _dev_update_ssh_config "$_devlocal_name"

    echo "Refreshing container..."
    _dev_ssh_cmd "$_devlocal_name" \
        "cd /workspace && git fetch origin ${_devlocal_push_branch} && git checkout -B '${_devlocal_push_branch}' FETCH_HEAD"

    _dev_ssh_cmd "$_devlocal_name"
    exit 0
fi

# New container
export DEV_FORK_ORG="$DEV_AUTOMATION_USER"
export DEV_BRANCH_NAME="$_devlocal_push_branch"

_dev_create_container "$_devlocal_name" "$_devlocal_template_key"

echo "Entering container '${_devlocal_name}'..."
exec podman start -ai "$_devlocal_name"
