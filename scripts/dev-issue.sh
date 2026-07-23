#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

readonly _devissue_url="${1:?'Usage: dev-issue.sh <github-url>'}"

# Parse both issue and PR URLs
if [[ "$_devissue_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/(issues|pull)/([0-9]+) ]]; then
    readonly _devissue_org="${BASH_REMATCH[1]}"
    readonly _devissue_repo="${BASH_REMATCH[2]}"
    readonly _devissue_type="${BASH_REMATCH[3]}"
    readonly _devissue_number="${BASH_REMATCH[4]}"
else
    echo "Error: could not parse GitHub URL" >&2
    echo "Expected: https://github.com/{org}/{repo}/{issues|pull}/{number}" >&2
    exit 1
fi

if [[ "$_devissue_type" == "pull" ]]; then
    readonly _devissue_name="${_devissue_repo}-pr-${_devissue_number}"
else
    readonly _devissue_name="${_devissue_repo}-${_devissue_number}"
fi
readonly _devissue_template_key="${_devissue_org}/${_devissue_repo}"

echo "${_devissue_type^} #${_devissue_number} in ${_devissue_template_key}"
echo "Container: ${_devissue_name}"

echo "$_devissue_name" > "/run/user/$(id -u)/dev-last-container"

# Existing container — just re-enter
if _dev_container_exists "$_devissue_name"; then
    _dev_ensure_proxy
    echo "Starting existing container..."
    exec podman start -ai "$_devissue_name"
fi

# New container — pass PR/issue number via env, entrypoint handles checkout + details
if [[ "$_devissue_type" == "pull" ]]; then
    export DEV_PR_NUMBER="$_devissue_number"
else
    export DEV_ISSUE_NUMBER="$_devissue_number"
fi

_dev_create_container "$_devissue_name" "$_devissue_template_key"

echo "Entering container '${_devissue_name}'..."
exec podman start -ai "$_devissue_name"
