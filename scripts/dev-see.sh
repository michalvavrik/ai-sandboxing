#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devsee_squash=true
_devsee_name_arg=""
for _devsee_arg in "$@"; do
    case "$_devsee_arg" in
        --dont-squash) _devsee_squash=false ;;
        *) _devsee_name_arg="$_devsee_arg" ;;
    esac
done

_devsee_name=$(_dev_resolve_name "$_devsee_name_arg")
readonly _devsee_name
readonly _devsee_remote="dev-automation"

if ! _dev_container_exists "$_devsee_name"; then
    echo "Error: container '${_devsee_name}' does not exist" >&2
    exit 1
fi

_dev_ensure_running "$_devsee_name"

readonly _devsee_branch="dev-auto/${_devsee_name}/main"
echo "Pushing changes to ${_devsee_branch}..."
if [[ "$_devsee_squash" == true ]]; then
    _dev_sync_workspace "$_devsee_name" "$_devsee_branch"
else
    _dev_ssh_cmd "$_devsee_name" \
        "cd /workspace && git add -A; git reset HEAD -- AGENTS.md CLAUDE.md GEMINI.md .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'WIP sync'; git push -f origin HEAD:refs/heads/${_devsee_branch}"
fi
echo "Branch: ${_devsee_branch}"

_devsee_template_key=$(_dev_container_template_key "$_devsee_name")
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

if git rev-parse --verify "$_devsee_branch" &>/dev/null; then
    _devsee_backup="dev-auto/${_devsee_name}/backup/see/$(date +%s)"
    _devsee_git_ssh="ssh -i ${DEV_KEYS_DIR}/id_ed25519_dev_automation -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
    _devsee_had_wip=false
    if [[ "$(git branch --show-current 2>/dev/null)" == "$_devsee_branch" && -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git add -A
        git commit --quiet -m "WIP" --no-verify
        _devsee_had_wip=true
    fi
    echo "Backing up host state to ${_devsee_backup}..."
    GIT_SSH_COMMAND="$_devsee_git_ssh" \
        git push "$_devsee_remote_url" "refs/heads/${_devsee_branch}:refs/heads/${_devsee_backup}" 2>/dev/null || true
    if [[ "$_devsee_had_wip" == true ]]; then
        git reset --quiet HEAD~1
    fi
fi

git checkout -B "$_devsee_branch" "${_devsee_remote}/${_devsee_branch}"

_dev_stop_if_was_stopped "$_devsee_name"

echo "Done."
