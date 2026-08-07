#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

readonly _devissue_url="${1:?'Usage: dev-issue.sh <github-url>'}"

if [[ "$_devissue_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/(issues|pull)/([0-9]+) ]]; then
    readonly _devissue_org="${BASH_REMATCH[1]}"
    readonly _devissue_repo="${BASH_REMATCH[2]}"
    readonly _devissue_type="${BASH_REMATCH[3]}"
    readonly _devissue_number="${BASH_REMATCH[4]}"
    readonly _devissue_branch=""
elif [[ "$_devissue_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/(tree|pull/new)/(.+)$ ]]; then
    readonly _devissue_org="${BASH_REMATCH[1]}"
    readonly _devissue_repo="${BASH_REMATCH[2]}"
    readonly _devissue_type="tree"
    readonly _devissue_number=""
    readonly _devissue_branch="${BASH_REMATCH[4]}"
elif [[ "$_devissue_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/compare/.*\.\.\.([^:]+):([^:]+):(.+) ]]; then
    readonly _devissue_org="${BASH_REMATCH[3]}"
    readonly _devissue_repo="${BASH_REMATCH[4]}"
    readonly _devissue_type="tree"
    readonly _devissue_number=""
    readonly _devissue_branch="${BASH_REMATCH[5]%%\?*}"
else
    echo "Error: could not parse GitHub URL" >&2
    echo "Expected: https://github.com/{org}/{repo}/{issues|pull}/{number}" >&2
    echo "      or: https://github.com/{org}/{repo}/tree/{branch}" >&2
    exit 1
fi

# Resolve template key — for known user accounts, match by repo name
if [[ "$_devissue_type" == "tree" ]]; then
    _devissue_template_key=""
    if [[ "$_devissue_org" == "$DEV_AUTOMATION_USER" || "$_devissue_org" == "$DEV_GHCR_USER" ]]; then
        _devissue_template_key=$(_dev_find_template_key_by_repo "$_devissue_repo") || true
    fi
    readonly _devissue_template_key="${_devissue_template_key:-${_devissue_org}/${_devissue_repo}}"
    if [[ "$_devissue_branch" =~ ^dev-auto/([^/]+) ]]; then
        readonly _devissue_name="${BASH_REMATCH[1]}"
    else
        readonly _devissue_name="${_devissue_repo}-${_devissue_branch//\//-}"
    fi
    echo "Branch ${_devissue_branch} in ${_devissue_org}/${_devissue_repo} (template: ${_devissue_template_key})"
else
    readonly _devissue_template_key="${_devissue_org}/${_devissue_repo}"
    if [[ "$_devissue_type" == "pull" ]]; then
        readonly _devissue_name="${_devissue_repo}-pr-${_devissue_number}"
    else
        readonly _devissue_name="${_devissue_repo}-${_devissue_number}"
    fi
    echo "${_devissue_type^} #${_devissue_number} in ${_devissue_template_key}"
fi

echo "Container: ${_devissue_name}"
echo "$_devissue_name" > "/run/user/$(id -u)/dev-last-container"

# Existing container — refresh and re-enter
if _dev_container_exists "$_devissue_name"; then
    _dev_ensure_proxy

    if ! _dev_container_running "$_devissue_name"; then
        podman start "$_devissue_name"
        sleep 3
    fi

    _dev_update_ssh_config "$_devissue_name"

    if [[ "$_devissue_type" == "pull" ]]; then
        echo "Refreshing PR #${_devissue_number}..."
        _dev_ssh_cmd "$_devissue_name" \
            "cd /workspace && gh pr checkout -f ${_devissue_number} --repo ${_devissue_template_key} && _pr=\$(git branch --show-current) && git checkout -B 'dev-auto/${_devissue_name}' && [ \"\$_pr\" != 'dev-auto/${_devissue_name}' ] && git branch -D \"\$_pr\" 2>/dev/null; true"
    elif [[ "$_devissue_type" == "tree" ]]; then
        echo "Refreshing branch ${_devissue_branch}..."
        _dev_ssh_cmd "$_devissue_name" \
            "cd /workspace && git fetch https://github.com/${_devissue_org}/${_devissue_repo}.git ${_devissue_branch} && git checkout -B 'dev-auto/${_devissue_name}' FETCH_HEAD"
    fi

    _dev_ssh_cmd "$_devissue_name"
    exit 0
fi

# New container — pass context via env, entrypoint handles checkout
if [[ "$_devissue_type" == "pull" ]]; then
    export DEV_PR_NUMBER="$_devissue_number"
    _devissue_head_ref=$(gh pr view "$_devissue_number" --repo "$_devissue_template_key" --json headRefName --jq '.headRefName' 2>/dev/null) || true
    if [[ -n "$_devissue_head_ref" ]]; then
        export DEV_ORIGINAL_BRANCH="$_devissue_head_ref"
    fi
elif [[ "$_devissue_type" == "tree" ]]; then
    export DEV_FORK_ORG="$_devissue_org"
    export DEV_BRANCH_NAME="$_devissue_branch"
else
    export DEV_ISSUE_NUMBER="$_devissue_number"
fi

_dev_create_container "$_devissue_name" "$_devissue_template_key"

echo "Entering container '${_devissue_name}'..."
exec podman start -ai "$_devissue_name"
