#!/bin/bash
# dev rebase — rebase the container's workspace on the latest upstream default
# branch (main/master of the project the container was created for) and push
# the result to dev-auto/<name>/main on the automation fork. The workspace is
# committed and pushed there first, so until the rebase succeeds the fork and
# the container's reflog keep the state before it. On conflicts the rebase is
# aborted and the workspace is left as it was.
#
# The host is not touched: run `dev see` afterwards. `dev merge` / `dev squash`
# expect their target branch (in-review/*, wip/*) to be the base the container
# works on, so rebase that branch on the same upstream before using them.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devrebase_name_arg=""
for _devrebase_arg in "$@"; do
    case "$_devrebase_arg" in
        --help|-h) echo "Usage: dev rebase [name]"; exit 0 ;;
        -*) echo "dev rebase: unknown option '${_devrebase_arg}'" >&2; exit 1 ;;
        *) _devrebase_name_arg="$_devrebase_arg" ;;
    esac
done

_devrebase_name=$(_dev_resolve_name "$_devrebase_name_arg")
readonly _devrebase_name

if ! _dev_container_exists "$_devrebase_name"; then
    echo "Error: container '${_devrebase_name}' does not exist" >&2
    exit 1
fi

if [[ -z "$(_dev_container_template_key "$_devrebase_name")" ]]; then
    echo "Error: container '${_devrebase_name}' has no project (no upstream remote to rebase on)" >&2
    exit 1
fi

_dev_ensure_running "$_devrebase_name"

readonly _devrebase_branch="dev-auto/${_devrebase_name}/main"

_devrebase_fail() {
    echo "$1" >&2
    _dev_stop_if_was_stopped "$_devrebase_name"
    exit 1
}

# A rebase or merge the agent left unfinished must be neither committed nor
# aborted here.
if _dev_ssh_cmd "$_devrebase_name" \
    'cd /workspace && { [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ] || [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; }' 2>/dev/null; then
    _devrebase_fail "Error: a rebase or merge is in progress in the container's workspace — finish or abort it there first"
fi

echo "Saving workspace to ${_devrebase_branch}..."
_dev_sync_workspace "$_devrebase_name" "$_devrebase_branch" \
    || _devrebase_fail "Error: could not save the container's workspace to ${_devrebase_branch}; not rebasing"

# The upstream repo's default branch (what its HEAD points to); main if unknown.
_devrebase_default=$(_dev_ssh_cmd "$_devrebase_name" \
    "cd /workspace && git ls-remote --symref upstream HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\(.*\)[[:space:]]HEAD\$|\1|p'") \
    || _devrebase_default=""
_devrebase_default="${_devrebase_default:-main}"

echo "Fetching upstream ${_devrebase_default}..."
_dev_ssh_cmd "$_devrebase_name" "cd /workspace && git fetch upstream ${_devrebase_default}" \
    || _devrebase_fail "Error: could not fetch upstream ${_devrebase_default}"

echo "Rebasing on upstream/${_devrebase_default}..."
if ! _dev_ssh_cmd "$_devrebase_name" "cd /workspace && git rebase upstream/${_devrebase_default}"; then
    echo "Conflicts in:" >&2
    _dev_ssh_cmd "$_devrebase_name" "cd /workspace && git diff --name-only --diff-filter=U | sed 's/^/  /'" >&2 || true
    _dev_ssh_cmd "$_devrebase_name" "cd /workspace && git rebase --abort" 2>/dev/null || true
    _devrebase_fail "Rebase aborted; the workspace is as it was (saved on ${_devrebase_branch})."
fi

_dev_ssh_cmd "$_devrebase_name" "cd /workspace && git push -f origin HEAD:refs/heads/${_devrebase_branch}" \
    || _devrebase_fail "Error: rebased, but could not push the result to ${_devrebase_branch} (the container has it; retry with 'dev see')"

echo "Rebased on upstream/${_devrebase_default}: $(_dev_ssh_cmd "$_devrebase_name" "cd /workspace && git log -1 --format='%h %s'")"
echo "Run 'dev see ${_devrebase_name}' to get it on the host."

_dev_stop_if_was_stopped "$_devrebase_name"
