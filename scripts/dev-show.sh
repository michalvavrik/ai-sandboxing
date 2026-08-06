#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devshow_name=$(_dev_resolve_name "${1:-}")
readonly _devshow_name
readonly _devshow_remote="dev-automation"

if ! _dev_container_exists "$_devshow_name"; then
    echo "Error: container '${_devshow_name}' does not exist" >&2
    exit 1
fi

_devshow_template_key=$(podman inspect --format '{{index .Config.Labels "dev-template-key"}}' "$_devshow_name" 2>/dev/null) || true
if [[ -z "$_devshow_template_key" ]]; then
    echo "Error: could not determine template from container labels" >&2
    exit 1
fi

_devshow_repo="${_devshow_template_key#*/}"
_devshow_tmpl=$(_dev_lookup_template "$_devshow_template_key") || true
if [[ -z "$_devshow_tmpl" ]]; then
    echo "Error: no template found for '${_devshow_template_key}'" >&2
    exit 1
fi

_devshow_src_dir=$(echo "$_devshow_tmpl" | cut -d'|' -f1)
if [[ -n "$_devshow_src_dir" && "$_devshow_src_dir" != /* ]]; then
    _devshow_src_dir="${DEV_SOURCES_DIR}/${_devshow_src_dir}"
fi

if [[ -z "$_devshow_src_dir" || ! -d "$_devshow_src_dir/.git" ]]; then
    echo "Error: source directory '${_devshow_src_dir}' does not exist or is not a git repo" >&2
    exit 1
fi

readonly _devshow_branch="dev-auto/${_devshow_name}/main"
_devshow_current=$(git -C "$_devshow_src_dir" branch --show-current 2>/dev/null)

if [[ "$_devshow_current" != "$_devshow_branch" ]]; then
    echo "Error: not on the agent's branch" >&2
    echo "  Current branch: ${_devshow_current:-detached HEAD}" >&2
    echo "  Expected:       ${_devshow_branch}" >&2
    echo "Run 'dev see ${_devshow_name}' first to check out the agent's branch." >&2
    exit 1
fi

readonly _devshow_remote_url="git@github.com:${DEV_AUTOMATION_USER}/${_devshow_repo}.git"
readonly _devshow_git_ssh="ssh -i ${DEV_KEYS_DIR}/id_ed25519_dev_automation -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"

if ! git -C "$_devshow_src_dir" remote get-url "$_devshow_remote" &>/dev/null; then
    git -C "$_devshow_src_dir" remote add "$_devshow_remote" "$_devshow_remote_url"
elif [[ "$(git -C "$_devshow_src_dir" remote get-url "$_devshow_remote")" != "$_devshow_remote_url" ]]; then
    git -C "$_devshow_src_dir" remote set-url "$_devshow_remote" "$_devshow_remote_url"
fi

cd "$_devshow_src_dir"
git add -A
if ! git diff --cached --quiet; then
    git commit -m "sync from host"
    echo "Committed changes."
else
    echo "No new changes to commit."
fi

echo "Pushing to ${_devshow_branch}..."
GIT_SSH_COMMAND="$_devshow_git_ssh" \
    git push -f "$_devshow_remote" "HEAD:refs/heads/${_devshow_branch}"

_dev_ensure_proxy

_devshow_was_stopped=false
if ! _dev_container_running "$_devshow_name"; then
    _devshow_was_stopped=true
    podman start "$_devshow_name" >/dev/null
    sleep 3
fi

_dev_update_ssh_config "$_devshow_name"

_devshow_backup="dev-auto/${_devshow_name}/backup/show/$(date +%s)"
echo "Backing up container state to ${_devshow_backup}..."
_dev_ssh_cmd "$_devshow_name" \
    "cd /workspace && git add -A && git reset HEAD -- AGENTS.md CLAUDE.md GEMINI.md .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'backup'; git push origin HEAD:refs/heads/${_devshow_backup}" 2>/dev/null || true

echo "Pulling inside container..."
_dev_ssh_cmd "$_devshow_name" \
    "cd /workspace && git fetch origin ${_devshow_branch} && git checkout -B '${_devshow_branch}' FETCH_HEAD"

if [[ "$_devshow_was_stopped" == true ]]; then
    podman stop "$_devshow_name" >/dev/null
fi

echo "Done. Container '${_devshow_name}' updated with host changes."
