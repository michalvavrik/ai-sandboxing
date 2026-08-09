#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devrc_name=$(_dev_resolve_name "${1:-}")
readonly _devrc_name

if ! _dev_container_exists "$_devrc_name"; then
    echo "Error: container '${_devrc_name}' does not exist" >&2
    exit 1
fi

# Read metadata from old container
readonly _devrc_template_key=$(_dev_container_template_key "$_devrc_name")
readonly _devrc_envs=$(podman inspect --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$_devrc_name" 2>/dev/null)
_devrc_env() { echo "$_devrc_envs" | sed -n "s/^${1}=//p"; }

export DEV_ORIGINAL_BRANCH
DEV_ORIGINAL_BRANCH=$(podman inspect --format '{{index .Config.Labels "dev-original-branch"}}' "$_devrc_name" 2>/dev/null) || true
[[ "$DEV_ORIGINAL_BRANCH" == "<no value>" ]] && DEV_ORIGINAL_BRANCH=""
export DEV_PR_NUMBER=$(_devrc_env DEV_PR_NUMBER)
export DEV_ISSUE_NUMBER=$(_devrc_env DEV_ISSUE_NUMBER)
export DEV_FORK_ORG=$(_devrc_env DEV_FORK_ORG)
export DEV_BRANCH_NAME=$(_devrc_env DEV_BRANCH_NAME)

echo "Recreating container '${_devrc_name}' (template: ${_devrc_template_key})"

# Ensure running for SSH access
if ! _dev_container_running "$_devrc_name"; then
    _dev_ensure_proxy
    podman start "$_devrc_name" >/dev/null
    sleep 3
fi
_dev_update_ssh_config "$_devrc_name"

# Push workspace via git (same as dev see squash logic)
readonly _devrc_branch="dev-auto/${_devrc_name}/main"
echo "Pushing workspace to ${_devrc_branch}..."
_dev_ssh_cmd "$_devrc_name" \
    "cd /workspace && git add -A; _b=\$(git merge-base origin/main HEAD 2>/dev/null || head -1 .git/shallow 2>/dev/null); [ -n \"\$_b\" ] && [ \"\$_b\" != \"\$(git rev-parse HEAD)\" ] && git reset --soft \$_b; git reset HEAD -- AGENTS.md CLAUDE.md GEMINI.md .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'WIP sync' && git push -f origin HEAD:refs/heads/${_devrc_branch}"

# Save Claude session (small — scp is fine)
readonly _devrc_staging="/tmp/dev-recreate-${_devrc_name}"
rm -rf "$_devrc_staging"
if _dev_ssh_cmd "$_devrc_name" "test -d /home/dev/.claude/projects" 2>/dev/null; then
    echo "Saving Claude session..."
    mkdir -p "$_devrc_staging"
    DEV_LAST_CONTAINER="$_devrc_name" "${DEV_SCRIPTS_DIR}/dev-cpout.sh" --to "$_devrc_staging" /home/dev/.claude/projects
fi

# Move branch out of dev-auto/name/* before delete cleans it up
readonly _devrc_repo="${_devrc_template_key#*/}"
readonly _devrc_remote="git@github.com:${DEV_AUTOMATION_USER}/${_devrc_repo}.git"
readonly _devrc_git_ssh="ssh -i ${DEV_KEYS_DIR}/id_ed25519_dev_automation -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
readonly _devrc_tmp_branch="dev-recreate/${_devrc_name}"
GIT_SSH_COMMAND="$_devrc_git_ssh" \
    git push "$_devrc_remote" "refs/heads/${_devrc_branch}:refs/heads/${_devrc_tmp_branch}" 2>/dev/null

# Delete old container (cleans up dev-auto/name/* branches, revokes OAuth, removes disks)
"${DEV_SCRIPTS_DIR}/dev-delete.sh" "$_devrc_name"

# Restore branch and clean up temp
GIT_SSH_COMMAND="$_devrc_git_ssh" \
    git push "$_devrc_remote" "refs/heads/${_devrc_tmp_branch}:refs/heads/${_devrc_branch}" 2>/dev/null
GIT_SSH_COMMAND="$_devrc_git_ssh" \
    git push "$_devrc_remote" --delete "refs/heads/${_devrc_tmp_branch}" 2>/dev/null || true

# Create fresh container with same metadata and enter
export DEV_FORK_ORG="$DEV_AUTOMATION_USER"
export DEV_BRANCH_NAME="$_devrc_branch"
_dev_create_container "$_devrc_name" "$_devrc_template_key"

# Restore Claude session if saved
if [[ -d "$_devrc_staging/projects" ]]; then
    podman start "$_devrc_name" >/dev/null
    _dev_update_ssh_config "$_devrc_name"
    echo "Waiting for SSH..."
    _devrc_wait=0
    while ! ssh -q -o ConnectTimeout=1 -o BatchMode=yes "$_devrc_name" true &>/dev/null && (( _devrc_wait < 60 )); do
        sleep 2; _devrc_wait=$((_devrc_wait + 2))
    done
    echo "Restoring Claude session..."
    DEV_LAST_CONTAINER="$_devrc_name" "${DEV_SCRIPTS_DIR}/dev-cp.sh" --to /home/dev/.claude "$_devrc_staging/projects"
    rm -rf "$_devrc_staging"
    echo "Entering container '${_devrc_name}'..."
    _dev_ssh_cmd "$_devrc_name"
else
    rm -rf "$_devrc_staging"
    echo "Entering container '${_devrc_name}'..."
    exec podman start -ai "$_devrc_name"
fi
