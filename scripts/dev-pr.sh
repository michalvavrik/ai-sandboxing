#!/bin/bash
# dev pr [name] — open a pull request from a finished container. For now this
# handles backport containers (set up by dev backport): it brings the container's
# ported change to the host, builds one commit under your host git identity with no
# co-author, pushes it to your fork, and opens the backport PR against the
# maintenance branch with the project's title and body conventions. No agent runs
# on the host; this is all deterministic.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devpr_name_arg=""
for _devpr_arg in "$@"; do
    case "$_devpr_arg" in
        --help|-h) echo "Usage: dev pr [name]"; exit 0 ;;
        -*) echo "dev pr: unknown option '${_devpr_arg}'" >&2; exit 1 ;;
        *) _devpr_name_arg="$_devpr_arg" ;;
    esac
done

_devpr_name=$(_dev_resolve_project_container "$_devpr_name_arg") || exit 1
readonly _devpr_name

# Backport containers only for now (dev backport sets the dev-backport-pr label).
_devpr_pr=$(_dev_container_label "$_devpr_name" "dev-backport-pr")
if [[ -z "$_devpr_pr" ]]; then
    echo "Error: '${_devpr_name}' is not a backport container (dev pr currently handles backports only)" >&2
    exit 1
fi
_devpr_source_url=$(_dev_container_label "$_devpr_name" "dev-backport-source-url")
_devpr_branch=$(_dev_container_label "$_devpr_name" "dev-backport-branch")
_devpr_version=$(_dev_container_label "$_devpr_name" "dev-backport-target")
_devpr_issue=$(_dev_container_label "$_devpr_name" "dev-backport-issue")

_devpr_key=$(_dev_container_template_key "$_devpr_name")
if [[ -z "$_devpr_key" ]]; then
    echo "Error: could not determine the project of '${_devpr_name}'" >&2
    exit 1
fi
_devpr_repo="${_devpr_key#*/}"
_devpr_src=$(_dev_resolve_src_dir "$_devpr_key") || {
    echo "Error: source directory not found for '${_devpr_key}'" >&2
    exit 1
}
readonly _devpr_key _devpr_repo _devpr_src

# backport.conf decides whether the PR body gets a "closes" line.
_devpr_closes="no"
if _devpr_row=$(_dev_backport_row "$_devpr_key"); then
    IFS='|' read -r _ _ _ _devpr_closes <<< "$_devpr_row"
fi

if ! git -C "$_devpr_src" remote get-url "$DEV_GHCR_USER" &>/dev/null; then
    echo "Error: ${_devpr_src} has no git remote '${DEV_GHCR_USER}' (your fork) to push the PR branch to" >&2
    exit 1
fi

_dev_ensure_running "$_devpr_name"

# Bring the container's ported change to the host (container pushes to the
# automation fork, the host fetches it).
readonly _devpr_agent_branch="dev-auto/${_devpr_name}/main"
echo "Fetching the ported change from '${_devpr_name}'..."
if ! _dev_sync_workspace "$_devpr_name" "$_devpr_agent_branch"; then
    echo "Error: could not sync the container's workspace" >&2
    _dev_stop_if_was_stopped "$_devpr_name"
    exit 1
fi
_dev_ensure_automation_remote "$_devpr_src" "$_devpr_repo"
git -C "$_devpr_src" fetch "$DEV_AUTOMATION_REMOTE" "$_devpr_agent_branch"
_devpr_tree=$(git -C "$_devpr_src" rev-parse --verify 'FETCH_HEAD^{tree}')

# Parent = the maintenance-branch commit the agent worked from (.base), an ancestor
# of the fetched change, so the PR's diff is exactly the backport.
_devpr_base=$(_dev_ssh_cmd "$_devpr_name" "cat /workspace/.base 2>/dev/null" </dev/null 2>/dev/null | tr -d '[:space:]') || _devpr_base=""
_dev_stop_if_was_stopped "$_devpr_name"
if [[ ! "$_devpr_base" =~ ^[0-9a-f]{40}$ ]] || ! git -C "$_devpr_src" cat-file -e "${_devpr_base}^{commit}" 2>/dev/null; then
    echo "Error: could not determine the maintenance-branch base for the backport" >&2
    exit 1
fi

if [[ "$_devpr_tree" == "$(git -C "$_devpr_src" rev-parse --verify "${_devpr_base}^{tree}")" ]]; then
    echo "Nothing to backport: the change is empty against ${_devpr_branch}." >&2
    exit 1
fi

# Title and body from the original PR plus the project convention.
_devpr_title=$(gh pr view "$_devpr_pr" --repo "$_devpr_key" --json title --jq '.title' 2>/dev/null) || _devpr_title=""
if [[ -z "$_devpr_title" ]]; then
    echo "Error: could not read the title of PR #${_devpr_pr} from ${_devpr_key}" >&2
    exit 1
fi
_devpr_full_title="[${_devpr_version}] ${_devpr_title}"
_devpr_body="* backports: ${_devpr_source_url}"
if [[ "$_devpr_closes" == "yes" && -n "$_devpr_issue" ]]; then
    _devpr_body="${_devpr_body}
* closes: ${_devpr_issue}"
fi

# One commit under the host identity, no co-author, on the maintenance base.
_devpr_msgfile=$(mktemp)
trap 'rm -f "$_devpr_msgfile"' EXIT
printf '%s\n' "$_devpr_full_title" > "$_devpr_msgfile"
_devpr_commit=$(_dev_commit_as_host "$_devpr_src" "$_devpr_tree" "$_devpr_msgfile" "" "$_devpr_base") || exit 1

readonly _devpr_pr_branch="backport-${_devpr_pr}-${_devpr_version}"
echo "Pushing ${_devpr_pr_branch} to ${DEV_GHCR_USER}..."
if ! git -C "$_devpr_src" push --force "$DEV_GHCR_USER" "${_devpr_commit}:refs/heads/${_devpr_pr_branch}"; then
    echo "Error: could not push ${_devpr_pr_branch} to ${DEV_GHCR_USER}" >&2
    exit 1
fi

echo "Opening the backport PR against ${_devpr_branch}..."
if ! gh pr create --repo "$_devpr_key" --base "$_devpr_branch" \
        --head "${DEV_GHCR_USER}:${_devpr_pr_branch}" \
        --title "$_devpr_full_title" --body "$_devpr_body"; then
    echo "Error: gh pr create failed (does the PR already exist? the branch is pushed, so you can open it by hand)" >&2
    exit 1
fi
