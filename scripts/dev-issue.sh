#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devissue_url="${1:?'Usage: dev-issue.sh <github-url>'}"

if [[ "$_devissue_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/issues/([0-9]+) ]]; then
    readonly _devissue_org="${BASH_REMATCH[1]}"
    readonly _devissue_repo="${BASH_REMATCH[2]}"
    readonly _devissue_number="${BASH_REMATCH[3]}"
else
    echo "Error: could not parse GitHub issue URL" >&2
    echo "Expected: https://github.com/{org}/{repo}/issues/{number}" >&2
    exit 1
fi

readonly _devissue_name="${_devissue_repo}-${_devissue_number}"
readonly _devissue_template_key="${_devissue_org}/${_devissue_repo}"

echo "Issue #${_devissue_number} in ${_devissue_template_key}"
echo "Container: ${_devissue_name}"

export DEV_LAST_CONTAINER="$_devissue_name"

if _dev_container_exists "$_devissue_name"; then
    _dev_ensure_proxy
    if _dev_container_running "$_devissue_name"; then
        _dev_ssh_cmd "$_devissue_name"
    else
        exec podman start -ai "$_devissue_name"
    fi
    exit 0
fi

# Fetch issue details before creating container
_devissue_content=""
_devissue_body=$(gh issue view "$_devissue_number" \
    --repo "${_devissue_template_key}" \
    --json title,body --jq '"Title: " + .title + "\n\n" + .body' 2>/dev/null) || true

if [[ -n "$_devissue_body" ]]; then
    _devissue_content=$(printf 'Issue: %s#%s\nURL: %s\n%s\n' \
        "$_devissue_template_key" "$_devissue_number" "$_devissue_url" \
        "$_devissue_body")
fi

# Create container
_dev_create_container "$_devissue_name" "$_devissue_template_key"

# Start container in background, inject issue via SSH, then attach
podman start "$_devissue_name"
sleep 3

if [[ -n "$_devissue_content" ]]; then
    echo "$_devissue_content" | _dev_ssh_cmd "$_devissue_name" 'cat > /workspace/.issue'
    echo "Issue details saved to /workspace/.issue"
fi

podman stop "$_devissue_name" 2>/dev/null || true
exec podman start -ai "$_devissue_name"
