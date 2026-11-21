#!/bin/bash
# dev backport <PR-url> [-b <X.Y>] — create a container on a project's maintenance
# branch to backport a merged PR there. The target branch comes from -b, or from
# the backport labels (keycloak: the PR's closing issue, quarkus: the PR) per
# configs/backport.conf. Several matching labels with no -b is an error. The agent
# ports and analyses the change inside the container; `dev pr` opens the backport PR.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devbp_version=""
_devbp_url=""
while (( $# )); do
    case "$1" in
        -b) if [[ -z "${2:-}" ]]; then echo "dev backport: -b needs a version" >&2; exit 1; fi
            _devbp_version="$2"; shift 2 ;;
        -b*) _devbp_version="${1#-b}"; shift ;;
        --help|-h) echo "Usage: dev backport [-b <X.Y>] <PR-url>"; exit 0 ;;
        -*) echo "dev backport: unknown option '$1'" >&2; exit 1 ;;
        *) _devbp_url="$1"; shift ;;
    esac
done

if [[ -z "$_devbp_url" ]]; then
    echo "Usage: dev backport [-b <X.Y>] <PR-url>" >&2
    exit 1
fi

if ! _dev_parse_github_url "$_devbp_url" || [[ "$_DEV_URL_TYPE" != "pull" ]]; then
    echo "Error: expected a pull-request URL, e.g. https://github.com/keycloak/keycloak/pull/55217" >&2
    exit 1
fi
readonly _devbp_org="$_DEV_URL_ORG"
readonly _devbp_repo="$_DEV_URL_REPO"
readonly _devbp_pr="$_DEV_URL_NUMBER"
readonly _devbp_key="${_devbp_org}/${_devbp_repo}"

if ! _devbp_row=$(_dev_backport_row "$_devbp_key"); then
    echo "Error: ${_devbp_key} has no row in configs/backport.conf; add one to back-port it" >&2
    exit 1
fi
IFS='|' read -r _devbp_label_source _devbp_label_prefix _devbp_branch_tmpl _ <<< "$_devbp_row"

# The PR must be merged; its merge commit is what gets ported.
if ! _devbp_meta=$(gh pr view "$_devbp_pr" --repo "$_devbp_key" \
        --json state,title,mergeCommit,url,closingIssuesReferences 2>/dev/null); then
    echo "Error: could not read PR #${_devbp_pr} from ${_devbp_key} (gh pr view)" >&2
    exit 1
fi
_devbp_state=$(jq -r '.state' <<< "$_devbp_meta")
if [[ "$_devbp_state" != "MERGED" ]]; then
    echo "Error: PR #${_devbp_pr} is ${_devbp_state}; only merged PRs can be backported" >&2
    exit 1
fi
_devbp_merge_commit=$(jq -r '.mergeCommit.oid // ""' <<< "$_devbp_meta")
_devbp_title=$(jq -r '.title' <<< "$_devbp_meta")
_devbp_source_url=$(jq -r '.url' <<< "$_devbp_meta")
_devbp_issue_url=$(jq -r '.closingIssuesReferences[0].url // ""' <<< "$_devbp_meta")
_devbp_issue_number=$(jq -r '.closingIssuesReferences[0].number // ""' <<< "$_devbp_meta")
if [[ -z "$_devbp_merge_commit" ]]; then
    echo "Error: could not resolve the merge commit of PR #${_devbp_pr}" >&2
    exit 1
fi

# Resolve the target version from -b, or from the backport labels.
if [[ -n "$_devbp_version" ]]; then
    _devbp_version="${_devbp_version#release/}"
    if [[ ! "$_devbp_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "Error: -b expects a MAJOR.MINOR version like 26.8" >&2
        exit 1
    fi
else
    _devbp_labels=()
    case "$_devbp_label_source" in
        issue)
            if [[ -z "$_devbp_issue_number" ]]; then
                echo "Error: PR #${_devbp_pr} closes no issue, so it has no backport labels; pass -b <X.Y>" >&2
                exit 1
            fi
            mapfile -t _devbp_labels < <(gh issue view "$_devbp_issue_number" --repo "$_devbp_key" \
                --json labels --jq '.labels[].name' 2>/dev/null) || _devbp_labels=()
            ;;
        pr)
            mapfile -t _devbp_labels < <(gh pr view "$_devbp_pr" --repo "$_devbp_key" \
                --json labels --jq '.labels[].name' 2>/dev/null) || _devbp_labels=()
            ;;
        *)
            echo "Error: configs/backport.conf has an invalid label_source '${_devbp_label_source}' for ${_devbp_key}" >&2
            exit 1
            ;;
    esac
    mapfile -t _devbp_versions < <(_dev_backport_versions_from_labels "$_devbp_label_prefix" \
        ${_devbp_labels[@]+"${_devbp_labels[@]}"})
    if (( ${#_devbp_versions[@]} == 0 )); then
        echo "Error: no ${_devbp_label_prefix}<X.Y> backport label on PR #${_devbp_pr}; pass -b <X.Y>" >&2
        exit 1
    elif (( ${#_devbp_versions[@]} > 1 )); then
        echo "PR #${_devbp_pr} targets several branches; rerun with -b <version> for one of:" >&2
        printf '  %s\n' "${_devbp_versions[@]}" >&2
        exit 1
    fi
    _devbp_version="${_devbp_versions[0]}"
fi
readonly _devbp_version

_devbp_branch=$(_dev_backport_branch "$_devbp_branch_tmpl" "$_devbp_version")
readonly _devbp_branch
readonly _devbp_name="${_devbp_repo}-pr-${_devbp_pr}-${_devbp_version}"

echo "Backport PR #${_devbp_pr} (${_devbp_title}) to ${_devbp_branch}"
echo "Container: ${_devbp_name}"
_dev_remember_container "$_devbp_name"
_dev_lock_shared

# Existing container — ensure it is up and enter it.
if _dev_container_exists "$_devbp_name"; then
    _dev_ensure_proxy
    _dev_ensure_running "$_devbp_name"
    _dev_lock_release
    [[ "${DEV_SKIP_ENTER:-}" == "1" ]] || _dev_ssh_cmd "$_devbp_name"
    exit 0
fi

# New container — the entrypoint checks out the maintenance branch and writes the
# backport context (.backport, .pr, refs/backport/source) from these.
export DEV_BACKPORT_PR="$_devbp_pr"
export DEV_BACKPORT_SOURCE_URL="$_devbp_source_url"
export DEV_BACKPORT_MERGE_COMMIT="$_devbp_merge_commit"
export DEV_BACKPORT_BRANCH="$_devbp_branch"
export DEV_BACKPORT_TARGET="$_devbp_version"
export DEV_BACKPORT_ISSUE="$_devbp_issue_url"

_dev_create_container "$_devbp_name" "$_devbp_key"

echo "Starting container '${_devbp_name}'..."
podman start "$_devbp_name" >/dev/null
_dev_update_ssh_config "$_devbp_name"
if ! _dev_wait_ssh "$_devbp_name"; then
    echo "Error: container '${_devbp_name}' did not become reachable via SSH in time" >&2
    exit 1
fi
_dev_lock_release

# Programmatic callers just want the container prepared.
if [[ "${DEV_SKIP_ENTER:-}" == "1" ]]; then
    exit 0
fi

# Run the backport agent headless; its result stays in the container for review.
_devbp_report="/workspace/.reviews/backport/$(date +%Y%m%d-%H%M%S).md"
_devbp_session="/run/user/$(id -u)/dev-review-session-${_devbp_name}-claude"
_devbp_prompt="$(cat "${DEV_CONFIGS_DIR}/review-prompts/backport.txt")

Write your report to ${_devbp_report} (this exact path)."

echo "Running backport agent in '${_devbp_name}'..."
_dev_run_agent "$_devbp_name" claude "" "" "$_devbp_report" "$_devbp_session" "$_devbp_prompt" "backport" || true

echo ""
echo "Then:"
echo "  dev enter ${_devbp_name}    continue in the container"
echo "  dev review \"...\"            ask the agent a follow-up"
echo "  dev see ${_devbp_name}      fetch the result to the host"
echo "  dev pr                      open the backport PR"
