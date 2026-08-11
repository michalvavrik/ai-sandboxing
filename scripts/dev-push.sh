#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devpush_usage() {
    echo "Usage: dev push [--local] [name]"
    echo ""
    echo "Squash agent's work into one commit on the original branch and push."
    echo ""
    echo "Inside the container: commits all changes (including untracked),"
    echo "rebases onto latest upstream main, and pushes to the agent's fork."
    echo ""
    echo "On the host: fetches the rebased branch, creates a single signed"
    echo "commit on the original branch with your identity, and pushes."
    echo "Does not affect the current working branch or checkout."
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

echo "Container:       ${_devpush_name}"
echo "Agent branch:    ${_devpush_branch}"
echo "Original branch: ${_devpush_original_branch}"

# ── Step 1: Inside container — commit, rebase on upstream, push ─────────
_devpush_was_stopped=false
if ! _dev_container_running "$_devpush_name"; then
    _devpush_was_stopped=true
    _dev_ensure_proxy
    podman start "$_devpush_name" >/dev/null
    sleep 3
fi
_dev_update_ssh_config "$_devpush_name"

echo "Committing workspace..."
_dev_ssh_cmd "$_devpush_name" \
    "cd /workspace; git add -A; git reset HEAD -- AGENTS.md CLAUDE.md GEMINI.md .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'dev push sync'"

echo "Rebasing on upstream main..."
if ! _dev_ssh_cmd "$_devpush_name" \
    "cd /workspace && git fetch upstream main && git rebase upstream/main"; then
    _dev_ssh_cmd "$_devpush_name" "cd /workspace && git rebase --abort" 2>/dev/null || true
    echo "Rebase failed due to merge conflicts. Aborted." >&2
    [[ "$_devpush_was_stopped" == true ]] && podman stop "$_devpush_name" >/dev/null
    exit 1
fi

echo "Pushing to agent fork..."
_dev_ssh_cmd "$_devpush_name" \
    "cd /workspace && git push -f origin HEAD:refs/heads/${_devpush_branch}"

if [[ "$_devpush_was_stopped" == true ]]; then
    podman stop "$_devpush_name" >/dev/null
fi

# ── Step 2: On host — fetch, squash to one commit, push ─────────────────
_devpush_remote="dev-automation"
if ! git -C "$_devpush_src_dir" remote get-url "$_devpush_remote" &>/dev/null; then
    git -C "$_devpush_src_dir" remote add "$_devpush_remote" "$_devpush_remote_url"
elif [[ "$(git -C "$_devpush_src_dir" remote get-url "$_devpush_remote")" != "$_devpush_remote_url" ]]; then
    git -C "$_devpush_src_dir" remote set-url "$_devpush_remote" "$_devpush_remote_url"
fi

git -C "$_devpush_src_dir" fetch "$_devpush_remote" "$_devpush_branch"
_devpush_agent_ref=$(git -C "$_devpush_src_dir" rev-parse FETCH_HEAD)
_devpush_agent_tree=$(git -C "$_devpush_src_dir" rev-parse "${_devpush_agent_ref}^{tree}")

_devpush_merge_base=$(git -C "$_devpush_src_dir" merge-base main "$_devpush_agent_ref" 2>/dev/null) || true
if [[ -z "$_devpush_merge_base" ]]; then
    echo "Error: could not find merge base between 'main' and agent branch" >&2
    exit 1
fi

_devpush_original_msg=$(git -C "$_devpush_src_dir" log -1 --format=%B "$_devpush_original_branch")

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
