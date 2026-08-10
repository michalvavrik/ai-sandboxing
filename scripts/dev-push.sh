#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devpush_usage() {
    echo "Usage: dev push [--local] [name]"
    echo ""
    echo "Squash agent's work into one commit on the original branch and push."
    echo "The original branch is recorded when the container is created via"
    echo "'dev .' or 'dev <pr-url>'."
    echo ""
    echo "If the agent branch has uncommitted changes or multiple commits,"
    echo "they are squashed into one commit first (git-s). The commit on the"
    echo "original branch uses its tip commit message with your signoff and"
    echo "authorship."
    echo ""
    echo "Options:"
    echo "  --local    Update the local branch without pushing to remote"
}

_devpush_local=false
_devpush_name_arg=""
for _devpush_arg in "$@"; do
    case "$_devpush_arg" in
        --local) _devpush_local=true ;;
        --help|-h) _devpush_usage; exit 0 ;;
        *) _devpush_name_arg="$_devpush_arg" ;;
    esac
done

_devpush_name=$(_dev_resolve_name "$_devpush_name_arg")
readonly _devpush_name

if ! _dev_container_exists "$_devpush_name"; then
    echo "Error: container '${_devpush_name}' does not exist" >&2
    exit 1
fi

_devpush_original_branch=$(podman inspect --format '{{index .Config.Labels "dev-original-branch"}}' "$_devpush_name" 2>/dev/null) || true
if [[ -z "$_devpush_original_branch" || "$_devpush_original_branch" == "<no value>" ]]; then
    echo "Error: container '${_devpush_name}' has no linked original branch" >&2
    echo "Only containers created via 'dev .' or 'dev <pr-url>' support 'dev push'." >&2
    exit 1
fi
readonly _devpush_original_branch

_devpush_template_key=$(_dev_container_template_key "$_devpush_name")
if [[ -z "$_devpush_template_key" ]]; then
    echo "Error: could not determine template from container labels" >&2
    exit 1
fi

_devpush_tmpl=$(_dev_lookup_template "$_devpush_template_key") || true
if [[ -z "$_devpush_tmpl" ]]; then
    echo "Error: no template found for '${_devpush_template_key}'" >&2
    exit 1
fi

_devpush_src_dir=$(echo "$_devpush_tmpl" | cut -d'|' -f1)
if [[ -n "$_devpush_src_dir" && "$_devpush_src_dir" != /* ]]; then
    _devpush_src_dir="${DEV_SOURCES_DIR}/${_devpush_src_dir}"
fi

if [[ -z "$_devpush_src_dir" || ! -d "$_devpush_src_dir/.git" ]]; then
    echo "Error: source directory '${_devpush_src_dir}' does not exist or is not a git repo" >&2
    exit 1
fi

readonly _devpush_src_dir
readonly _devpush_branch="dev-auto/${_devpush_name}/main"

if ! git -C "$_devpush_src_dir" rev-parse --verify "$_devpush_branch" &>/dev/null; then
    echo "Error: branch '${_devpush_branch}' not found locally" >&2
    echo "Run 'dev see ${_devpush_name}' first to sync agent changes to host." >&2
    exit 1
fi

if ! git -C "$_devpush_src_dir" rev-parse --verify "$_devpush_original_branch" &>/dev/null; then
    echo "Error: original branch '${_devpush_original_branch}' not found locally" >&2
    exit 1
fi

echo "Container:       ${_devpush_name}"
echo "Agent branch:    ${_devpush_branch}"
echo "Original branch: ${_devpush_original_branch}"

# If currently on the agent branch, normalize to one clean commit (git-s)
if [[ "$(git -C "$_devpush_src_dir" branch --show-current 2>/dev/null)" == "$_devpush_branch" ]]; then
    _devpush_behind=$(git -C "$_devpush_src_dir" rev-list --count main.."$_devpush_branch")
    _devpush_dirty=false
    [[ -n "$(git -C "$_devpush_src_dir" status --porcelain)" ]] && _devpush_dirty=true

    if [[ "$_devpush_dirty" == true || "$_devpush_behind" -gt 1 ]]; then
        echo "Squashing agent branch to one commit..."
        git -C "$_devpush_src_dir" add -A
        if (( _devpush_behind > 0 )); then
            git -C "$_devpush_src_dir" reset --soft "HEAD~${_devpush_behind}"
        fi
        git -C "$_devpush_src_dir" commit --signoff -am "wip"
    fi
fi

_devpush_agent_tree=$(git -C "$_devpush_src_dir" rev-parse "${_devpush_branch}^{tree}")

_devpush_original_msg=$(git -C "$_devpush_src_dir" log -1 --format=%B "$_devpush_original_branch")

_devpush_merge_base=$(git -C "$_devpush_src_dir" merge-base main "$_devpush_original_branch" 2>/dev/null) || true
if [[ -z "$_devpush_merge_base" ]]; then
    echo "Error: could not find merge base between 'main' and '${_devpush_original_branch}'" >&2
    exit 1
fi

_devpush_user_name=$(git -C "$_devpush_src_dir" config user.name 2>/dev/null) || true
_devpush_user_email=$(git -C "$_devpush_src_dir" config user.email 2>/dev/null) || true
if [[ -z "$_devpush_user_name" || -z "$_devpush_user_email" ]]; then
    echo "Error: git user.name or user.email not configured in ${_devpush_src_dir}" >&2
    exit 1
fi

_devpush_signoff="Signed-off-by: ${_devpush_user_name} <${_devpush_user_email}>"
if ! printf '%s\n' "$_devpush_original_msg" | grep -qF "$_devpush_signoff"; then
    _devpush_original_msg=$(printf '%s\n\n%s' "$_devpush_original_msg" "$_devpush_signoff")
fi

echo "Creating commit on '${_devpush_original_branch}'..."
_devpush_new_commit=$(git -C "$_devpush_src_dir" commit-tree "$_devpush_agent_tree" \
    -p "$_devpush_merge_base" \
    -S -m "$_devpush_original_msg")

git -C "$_devpush_src_dir" update-ref "refs/heads/${_devpush_original_branch}" "$_devpush_new_commit"

if [[ "$_devpush_local" == true ]]; then
    echo "Done. Branch '${_devpush_original_branch}' updated locally (not pushed)."
else
    echo "Pushing to ${DEV_GHCR_USER}..."
    git -C "$_devpush_src_dir" push "$DEV_GHCR_USER" "$_devpush_original_branch" --force-with-lease
    echo "Done. Branch '${_devpush_original_branch}' pushed to ${DEV_GHCR_USER}."
fi

echo "Commit: $(git -C "$_devpush_src_dir" log -1 --oneline "$_devpush_original_branch")"
