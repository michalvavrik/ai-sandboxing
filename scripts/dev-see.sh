#!/bin/bash
# dev see — commit whatever the container's workspace has, push it to
# dev-auto/<name>/main on the automation fork, fetch it and check it out on the
# host. Commits are kept as they are (no squash, no rebase); `dev merge` /
# `dev squash` later turn them into your own commit on in-review/<feature>.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devsee_name_arg=""
for _devsee_arg in "$@"; do
    case "$_devsee_arg" in
        --help|-h) echo "Usage: dev see [name]"; exit 0 ;;
        -*) echo "dev see: unknown option '${_devsee_arg}'" >&2; exit 1 ;;
        *) _devsee_name_arg="$_devsee_arg" ;;
    esac
done

_devsee_name=$(_dev_resolve_name "$_devsee_name_arg")
readonly _devsee_name

if ! _dev_container_exists "$_devsee_name"; then
    echo "Error: container '${_devsee_name}' does not exist" >&2
    exit 1
fi

_devsee_template_key=$(_dev_container_template_key "$_devsee_name")
_devsee_repo="${_devsee_template_key#*/}"
if [[ -z "$_devsee_repo" ]]; then
    echo "Error: could not determine project from container labels" >&2
    exit 1
fi
# The template's source checkout; the current directory for templates without one.
_devsee_src=$(_dev_resolve_src_dir "$_devsee_template_key" 2>/dev/null) || _devsee_src="$(pwd -P)"
if ! git -C "$_devsee_src" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: ${_devsee_src} is not a git repository" >&2
    exit 1
fi

_dev_ensure_running "$_devsee_name"

readonly _devsee_branch="dev-auto/${_devsee_name}/main"
echo "Pushing changes to ${_devsee_branch}..."
_dev_sync_workspace "$_devsee_name" "$_devsee_branch"
echo "Branch: ${_devsee_branch}"

_dev_ensure_automation_remote "$_devsee_src" "$_devsee_repo"

echo "Fetching from ${DEV_AUTOMATION_REMOTE}..."
git -C "$_devsee_src" fetch "$DEV_AUTOMATION_REMOTE" "$_devsee_branch"

if git -C "$_devsee_src" rev-parse -q --verify "refs/heads/${_devsee_branch}" >/dev/null; then
    _devsee_backup="dev-auto/${_devsee_name}/backup/see/$(date +%s)"
    _devsee_had_wip=false
    if [[ "$(git -C "$_devsee_src" branch --show-current 2>/dev/null)" == "$_devsee_branch" && -n "$(git -C "$_devsee_src" status --porcelain 2>/dev/null)" ]]; then
        git -C "$_devsee_src" add -A
        git -C "$_devsee_src" commit --quiet -m "WIP" --no-verify
        _devsee_had_wip=true
    fi
    echo "Backing up host state to ${_devsee_backup}..."
    GIT_SSH_COMMAND="$(_dev_git_ssh)" \
        git -C "$_devsee_src" push "$(_dev_automation_remote_url "$_devsee_repo")" \
        "refs/heads/${_devsee_branch}:refs/heads/${_devsee_backup}" 2>/dev/null || true
    if [[ "$_devsee_had_wip" == true ]]; then
        git -C "$_devsee_src" reset --quiet HEAD~1
    fi
fi

git -C "$_devsee_src" checkout -B "$_devsee_branch" FETCH_HEAD

_dev_stop_if_was_stopped "$_devsee_name"

echo "Done."
