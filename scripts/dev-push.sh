#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devpush_usage() {
    echo "Usage: dev push [--local] [name]"
    echo ""
    echo "Squash agent's work into one commit and push."
    echo ""
    echo "Inside the container: commits all changes (including untracked),"
    echo "rebases onto latest upstream main, and pushes to the agent's fork."
    echo ""
    echo "On the host: fetches the rebased branch, creates a single signed"
    echo "commit, and pushes. wip/* branches are renamed to in-review/*."
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

# ── Determine push target branch ──────────────────────────────────────────────
_devpush_original_branch=$(podman inspect --format '{{index .Config.Labels "dev-original-branch"}}' "$_devpush_name" 2>/dev/null) || true
[[ "$_devpush_original_branch" == "<no value>" ]] && _devpush_original_branch=""

_devpush_push_branch="$_devpush_original_branch"
_devpush_wip_to_delete=""
if [[ "$_devpush_original_branch" == wip/* ]]; then
    _devpush_push_branch="in-review/${_devpush_original_branch#wip/}"
    _devpush_wip_to_delete="$_devpush_original_branch"
elif [[ "$_devpush_original_branch" == dev-auto/* || -z "$_devpush_original_branch" ]]; then
    _devpush_feature=$(_dev_container_name_to_feature "$_devpush_name" "$_devpush_repo")
    _devpush_push_branch="in-review/${_devpush_feature}"
elif [[ "$_devpush_original_branch" == in-review/* ]]; then
    _devpush_push_branch="$_devpush_original_branch"
fi

if [[ -z "$_devpush_push_branch" ]]; then
    echo "Error: could not determine push branch for container '${_devpush_name}'" >&2
    exit 1
fi

echo "Container:       ${_devpush_name}"
echo "Agent branch:    ${_devpush_branch}"
echo "Push branch:     ${_devpush_push_branch}"

# ── Step 1: Inside container — commit, rebase on upstream, push ─────────
_dev_ensure_running "$_devpush_name"

echo "Committing workspace..."
_dev_ssh_cmd "$_devpush_name" \
    "cd /workspace; git add -A; git reset HEAD -- AGENTS.md CLAUDE.md GEMINI.md .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'dev push sync'"

echo "Rebasing on upstream main..."
if ! _dev_ssh_cmd "$_devpush_name" \
    "cd /workspace && git fetch upstream main && git stash -u && git rebase upstream/main; _rc=\$?; git stash pop 2>/dev/null; exit \$_rc"; then
    _dev_ssh_cmd "$_devpush_name" "cd /workspace && git rebase --abort" 2>/dev/null || true
    echo "Rebase failed due to merge conflicts. Aborted." >&2
    _dev_stop_if_was_stopped "$_devpush_name"
    exit 1
fi

echo "Pushing to agent fork..."
_dev_ssh_cmd "$_devpush_name" \
    "cd /workspace && git push -f origin HEAD:refs/heads/${_devpush_branch}"

_devpush_parent=$(_dev_ssh_cmd "$_devpush_name" "git -C /workspace rev-parse upstream/main")

_dev_stop_if_was_stopped "$_devpush_name"

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

_devpush_commit_msg=""
if [[ -n "$_devpush_original_branch" ]] && \
    git -C "$_devpush_src_dir" rev-parse --verify "$_devpush_original_branch" &>/dev/null; then
    _devpush_commit_msg=$(git -C "$_devpush_src_dir" log -1 --format=%B "$_devpush_original_branch")
fi
if [[ -z "$_devpush_commit_msg" ]]; then
    _devpush_commit_msg="dev push: ${_devpush_push_branch}"
fi

_devpush_user_name=$(git -C "$_devpush_src_dir" config user.name 2>/dev/null) || true
_devpush_user_email=$(git -C "$_devpush_src_dir" config user.email 2>/dev/null) || true
if [[ -z "$_devpush_user_name" || -z "$_devpush_user_email" ]]; then
    echo "Error: git user.name or user.email not configured in ${_devpush_src_dir}" >&2
    exit 1
fi

_devpush_signoff="Signed-off-by: ${_devpush_user_name} <${_devpush_user_email}>"
if ! printf '%s\n' "$_devpush_commit_msg" | grep -qF "$_devpush_signoff"; then
    _devpush_commit_msg=$(printf '%s\n\n%s' "$_devpush_commit_msg" "$_devpush_signoff")
fi

echo "Creating commit on '${_devpush_push_branch}'..."
_devpush_new_commit=$(git -C "$_devpush_src_dir" commit-tree "$_devpush_agent_tree" \
    -p "$_devpush_parent" \
    -S -m "$_devpush_commit_msg")

git -C "$_devpush_src_dir" update-ref "refs/heads/${_devpush_push_branch}" "$_devpush_new_commit"

# ── Step 3: Clean up wip branch if translating to in-review ───────────────
if [[ -n "$_devpush_wip_to_delete" ]] && \
    git -C "$_devpush_src_dir" rev-parse --verify "$_devpush_wip_to_delete" &>/dev/null; then
    _dev_backup_and_delete_branch "$_devpush_src_dir" "$_devpush_wip_to_delete"
fi

if [[ "$_devpush_local" == true ]]; then
    echo "Done. Branch '${_devpush_push_branch}' updated locally (not pushed)."
else
    echo "Pushing to ${DEV_GHCR_USER}..."
    git -C "$_devpush_src_dir" push "$DEV_GHCR_USER" "$_devpush_push_branch" --force-with-lease
    echo "Done. Branch '${_devpush_push_branch}' pushed to ${DEV_GHCR_USER}."
fi

echo "Commit: $(git -C "$_devpush_src_dir" log -1 --oneline "$_devpush_push_branch")"
