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

# Ensure running for copy-out
if ! _dev_container_running "$_devrc_name"; then
    _dev_ensure_proxy
    podman start "$_devrc_name" >/dev/null
    sleep 3
fi

# Copy out workspace and Claude session
readonly _devrc_staging="/tmp/dev-recreate-${_devrc_name}"
rm -rf "$_devrc_staging"
mkdir -p "$_devrc_staging"
echo "Saving workspace..."
DEV_LAST_CONTAINER="$_devrc_name" "${DEV_SCRIPTS_DIR}/dev-cpout.sh" --to "$_devrc_staging" /workspace
if _dev_ssh_cmd "$_devrc_name" "test -d /home/dev/.claude/projects" 2>/dev/null; then
    echo "Saving Claude session..."
    DEV_LAST_CONTAINER="$_devrc_name" "${DEV_SCRIPTS_DIR}/dev-cpout.sh" --to "$_devrc_staging" /home/dev/.claude/projects
fi

# Delete old container (disks, branches, OAuth — all cleaned up)
"${DEV_SCRIPTS_DIR}/dev-delete.sh" "$_devrc_name"

# Create fresh container with same metadata
_dev_create_container "$_devrc_name" "$_devrc_template_key"

# Start and wait for SSH
podman start "$_devrc_name" >/dev/null
_dev_update_ssh_config "$_devrc_name"
echo "Waiting for SSH..."
_devrc_wait=0
while ! ssh -q -o ConnectTimeout=1 -o BatchMode=yes "$_devrc_name" true &>/dev/null && (( _devrc_wait < 60 )); do
    sleep 2; _devrc_wait=$((_devrc_wait + 2))
done

# Restore workspace and Claude session
echo "Restoring workspace..."
DEV_LAST_CONTAINER="$_devrc_name" "${DEV_SCRIPTS_DIR}/dev-cp.sh" --to / "$_devrc_staging/workspace"
if [[ -d "$_devrc_staging/projects" ]]; then
    echo "Restoring Claude session..."
    DEV_LAST_CONTAINER="$_devrc_name" "${DEV_SCRIPTS_DIR}/dev-cp.sh" --to /home/dev/.claude "$_devrc_staging/projects"
fi

# Clean up staging
rm -rf "$_devrc_staging"

echo "Entering container '${_devrc_name}'..."
_dev_ssh_cmd "$_devrc_name"
