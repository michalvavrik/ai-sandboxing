#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devmerge_name=$(_dev_resolve_name "${1:-}")
readonly _devmerge_name

if ! _dev_container_exists "$_devmerge_name"; then
    echo "Error: container '${_devmerge_name}' does not exist" >&2
    exit 1
fi

_devmerge_tracked=$(podman inspect --format '{{index .Config.Labels "dev-original-branch"}}' "$_devmerge_name" 2>/dev/null) || true
[[ "$_devmerge_tracked" == "<no value>" ]] && _devmerge_tracked=""

if [[ -z "$_devmerge_tracked" ]]; then
    echo "No tracked branch — skipping merge."
    exit 0
fi

_devmerge_template_key=$(_dev_container_template_key "$_devmerge_name")
if [[ -z "$_devmerge_template_key" ]]; then
    echo "Error: could not determine template from container labels" >&2
    exit 1
fi

_devmerge_repo="${_devmerge_template_key#*/}"
_devmerge_src_dir=$(_dev_resolve_src_dir "$_devmerge_template_key") || true
if [[ -z "$_devmerge_src_dir" ]]; then
    echo "Error: source directory not found for '${_devmerge_template_key}'" >&2
    exit 1
fi

readonly _devmerge_branch="dev-auto/${_devmerge_name}/main"
readonly _devmerge_remote_url="git@github.com:${DEV_AUTOMATION_USER}/${_devmerge_repo}.git"

echo "Container:      ${_devmerge_name}"
echo "Tracked branch: ${_devmerge_tracked}"

# ── Step 1: Container — commit all changes, push to dev-auto branch ──────────
_dev_ensure_running "$_devmerge_name"

echo "Syncing container workspace..."
_dev_sync_workspace "$_devmerge_name" "$_devmerge_branch"

_dev_stop_if_was_stopped "$_devmerge_name"

# ── Step 2: Host — fetch agent's branch from automation fork ──────────────────
_devmerge_remote="dev-automation"
if ! git -C "$_devmerge_src_dir" remote get-url "$_devmerge_remote" &>/dev/null; then
    git -C "$_devmerge_src_dir" remote add "$_devmerge_remote" "$_devmerge_remote_url"
elif [[ "$(git -C "$_devmerge_src_dir" remote get-url "$_devmerge_remote")" != "$_devmerge_remote_url" ]]; then
    git -C "$_devmerge_src_dir" remote set-url "$_devmerge_remote" "$_devmerge_remote_url"
fi

echo "Fetching ${_devmerge_branch}..."
git -C "$_devmerge_src_dir" fetch "$_devmerge_remote" "$_devmerge_branch"

# ── Step 3: Back up tracked branch if it exists locally ───────────────────────
if git -C "$_devmerge_src_dir" rev-parse --verify "$_devmerge_tracked" &>/dev/null; then
    _dev_backup_and_delete_branch "$_devmerge_src_dir" "$_devmerge_tracked"
fi

# ── Step 4: Recreate tracked branch from fetched content ──────────────────────
git -C "$_devmerge_src_dir" branch "$_devmerge_tracked" FETCH_HEAD
echo "Updated '${_devmerge_tracked}' from container '${_devmerge_name}'."
