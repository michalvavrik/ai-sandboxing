#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devissue_url="${1:?'Usage: dev-issue.sh <github-url>'}"

# Parse both issue and PR URLs
if [[ "$_devissue_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/(issues|pull)/([0-9]+) ]]; then
    readonly _devissue_org="${BASH_REMATCH[1]}"
    readonly _devissue_repo="${BASH_REMATCH[2]}"
    readonly _devissue_type="${BASH_REMATCH[3]}"
    readonly _devissue_number="${BASH_REMATCH[4]}"
else
    echo "Error: could not parse GitHub URL" >&2
    echo "Expected: https://github.com/{org}/{repo}/issues/{number}" >&2
    echo "      or: https://github.com/{org}/{repo}/pull/{number}" >&2
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

export DEV_LAST_CONTAINER="$_devissue_name"

# ── Existing container ──────────────────────────────────────────────────────
if _dev_container_exists "$_devissue_name"; then
    _dev_ensure_proxy

    if ! _dev_container_running "$_devissue_name"; then
        podman start "$_devissue_name"
        sleep 3
    fi

    # For PRs: re-checkout to pick up new commits
    if [[ "$_devissue_type" == "pull" ]]; then
        echo "Updating PR checkout..."
        _dev_ssh_cmd "$_devissue_name" \
            "cd /workspace && gh pr checkout -f ${_devissue_number} --repo ${_devissue_template_key}" || true
    fi

    _dev_ssh_cmd "$_devissue_name"
    exit 0
fi

# ── New container ────────────────────────────────────────────────────────────

# Fetch details before creating container (using host's gh CLI)
_devissue_content=""
if [[ "$_devissue_type" == "pull" ]]; then
    _devissue_body=$(gh pr view "$_devissue_number" \
        --repo "${_devissue_template_key}" \
        --json title,body,headRefName,changedFiles,additions,deletions \
        --jq '"Title: " + .title + "\nBranch: " + .headRefName + "\nChanged files: " + (.changedFiles|tostring) + " (+" + (.additions|tostring) + " -" + (.deletions|tostring) + ")\n\n" + .body' \
        2>/dev/null) || true
else
    _devissue_body=$(gh issue view "$_devissue_number" \
        --repo "${_devissue_template_key}" \
        --json title,body --jq '"Title: " + .title + "\n\n" + .body' \
        2>/dev/null) || true
fi

if [[ -n "$_devissue_body" ]]; then
    _devissue_content=$(printf '%s: %s#%s\nURL: %s\n%s\n' \
        "${_devissue_type^}" "$_devissue_template_key" "$_devissue_number" \
        "$_devissue_url" "$_devissue_body")
fi

_dev_create_container "$_devissue_name" "$_devissue_template_key"

# Start in background to inject content and checkout PR via SSH
podman start "$_devissue_name"
sleep 3

# Save issue/PR details
if [[ -n "$_devissue_content" ]]; then
    if [[ "$_devissue_type" == "pull" ]]; then
        echo "$_devissue_content" | _dev_ssh_cmd "$_devissue_name" 'cat > /workspace/.pr'
        echo "PR details saved to /workspace/.pr"
    else
        echo "$_devissue_content" | _dev_ssh_cmd "$_devissue_name" 'cat > /workspace/.issue'
        echo "Issue details saved to /workspace/.issue"
    fi
fi

# For PRs: checkout the PR branch
if [[ "$_devissue_type" == "pull" ]]; then
    echo "Checking out PR #${_devissue_number}..."
    _dev_ssh_cmd "$_devissue_name" \
        "cd /workspace && gh pr checkout -f ${_devissue_number} --repo ${_devissue_template_key}"
fi

# Stop and reattach as primary shell
podman stop "$_devissue_name" 2>/dev/null || true
exec podman start -ai "$_devissue_name"
