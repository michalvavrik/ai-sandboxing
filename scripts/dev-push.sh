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
    echo "The commit on the original branch uses the original commit message"
    echo "with your signoff and authorship. Does not affect the current"
    echo "working branch or checkout."
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
readonly _devpush_repo="${_devpush_template_key#*/}"
readonly _devpush_remote_url="git@github.com:${DEV_AUTOMATION_USER}/${_devpush_repo}.git"

# Sync latest container state (commit + push workspace, then fetch to host)
echo "Syncing agent branch from container..."
_devpush_was_stopped=false
if ! _dev_container_running "$_devpush_name"; then
    _devpush_was_stopped=true
    _dev_ensure_proxy
    podman start "$_devpush_name" >/dev/null
    sleep 3
fi
_dev_update_ssh_config "$_devpush_name"
_dev_ssh_cmd "$_devpush_name" \
    "cd /workspace; git add -A; git reset HEAD -- AGENTS.md CLAUDE.md GEMINI.md .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'WIP sync' && git push -f origin HEAD:refs/heads/${_devpush_branch}" 2>/dev/null || true
if [[ "$_devpush_was_stopped" == true ]]; then
    podman stop "$_devpush_name" >/dev/null
fi

_devpush_remote="dev-automation"
if ! git -C "$_devpush_src_dir" remote get-url "$_devpush_remote" &>/dev/null; then
    git -C "$_devpush_src_dir" remote add "$_devpush_remote" "$_devpush_remote_url"
elif [[ "$(git -C "$_devpush_src_dir" remote get-url "$_devpush_remote")" != "$_devpush_remote_url" ]]; then
    git -C "$_devpush_src_dir" remote set-url "$_devpush_remote" "$_devpush_remote_url"
fi

# Fetch agent branch (read tree from ref, no checkout)
git -C "$_devpush_src_dir" fetch "$_devpush_remote" "$_devpush_branch"
_devpush_agent_ref=$(git -C "$_devpush_src_dir" rev-parse FETCH_HEAD)
_devpush_agent_tree=$(git -C "$_devpush_src_dir" rev-parse "${_devpush_agent_ref}^{tree}")

# Fetch latest upstream main so the merge base is current
_devpush_main_remote=$(git -C "$_devpush_src_dir" config branch.main.remote 2>/dev/null || echo origin)
git -C "$_devpush_src_dir" fetch "$_devpush_main_remote" main 2>/dev/null || true

echo "Container:       ${_devpush_name}"
echo "Agent branch:    ${_devpush_branch}"
echo "Original branch: ${_devpush_original_branch}"

_devpush_original_msg=$(git -C "$_devpush_src_dir" log -1 --format=%B "$_devpush_original_branch")

_devpush_merge_base=$(git -C "$_devpush_src_dir" merge-base "${_devpush_main_remote}/main" "$_devpush_agent_ref" 2>/dev/null) || true
if [[ -z "$_devpush_merge_base" ]]; then
    echo "Error: could not find merge base between '${_devpush_main_remote}/main' and agent branch" >&2
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
