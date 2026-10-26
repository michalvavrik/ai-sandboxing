#!/bin/bash
# dev show — push the host's current branch into a container. Uncommitted host
# changes are committed first ("sync from host"). The commits are copied to
# dev-auto/<name>/main on the automation fork with GitHub issue/PR references
# removed from their messages (see dev-git-sanitize.sh), then checked out in
# the container.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

# ── Resolve container name ────────────────────────────────────────────────────
# Only inside the project's source directory, only its containers. Without a
# name: the remembered container, else the one the current branch maps to
# (wip/<f> -> <repo>-<f>), else the project's only container.
_devshow_hint=""
if [[ -z "${1:-}" ]]; then
    _devshow_tkey=$(_dev_detect_template_from_cwd 2>/dev/null) || _devshow_tkey=""
    _devshow_cur=$(git branch --show-current 2>/dev/null) || _devshow_cur=""
    if [[ -n "$_devshow_tkey" && -n "$_devshow_cur" ]]; then
        _devshow_hint=$(_dev_branch_to_container_name "$_devshow_cur" "${_devshow_tkey#*/}")
    fi
fi
_devshow_name=$(_dev_resolve_project_container "${1:-}" "$_devshow_hint")
readonly _devshow_name

if _dev_container_is_study "$_devshow_name"; then
    echo "Nothing to show: ${_devshow_name} reads $(_dev_container_label "$_devshow_name" "dev-source-dir") live —"
    echo "what you add or change there is already in its /workspace (read-only)."
    exit 0
fi

_devshow_template_key=$(_dev_container_template_key "$_devshow_name")
if [[ -z "$_devshow_template_key" ]]; then
    echo "Error: could not determine template from container labels" >&2
    exit 1
fi

_devshow_repo="${_devshow_template_key#*/}"
_devshow_src_dir=$(_dev_resolve_src_dir "$_devshow_template_key") || {
    echo "Error: source directory for '${_devshow_template_key}' does not exist or is not a git repo" >&2
    exit 1
}

readonly _devshow_branch="dev-auto/${_devshow_name}/main"
_devshow_current=$(git -C "$_devshow_src_dir" branch --show-current 2>/dev/null)

# ── Verify current branch belongs to the container ───────────────────────────
# Accepted: the container's dev-auto branch, the branch dev merge/squash
# target (which is the branch a `dev .` container was created from), wip/<f>
# for an in-review/<f> target, and any branch that maps to the container by
# name.
_devshow_target=$(_dev_container_target_branch "$_devshow_name" "$_devshow_repo")
_devshow_accepted=("$_devshow_branch" "$_devshow_target")
[[ "$_devshow_target" == in-review/* ]] && _devshow_accepted+=("wip/${_devshow_target#in-review/}")
_devshow_ok=false
if [[ -n "$_devshow_current" ]]; then
    for _devshow_b in "${_devshow_accepted[@]}"; do
        [[ "$_devshow_current" == "$_devshow_b" ]] && _devshow_ok=true
    done
    [[ "$(_dev_branch_to_container_name "$_devshow_current" "$_devshow_repo")" == "$_devshow_name" ]] && _devshow_ok=true
fi

if [[ "$_devshow_ok" != true ]]; then
    echo "Error: current branch does not match container" >&2
    echo "  Current branch: ${_devshow_current:-detached HEAD}" >&2
    echo "  Container:      ${_devshow_name}" >&2
    echo "  Expected one of: $(IFS=', '; echo "${_devshow_accepted[*]}")" >&2
    echo "Run 'dev see ${_devshow_name}' or check out one of these branches first." >&2
    exit 1
fi

cd "$_devshow_src_dir"
git add -A
if ! git diff --cached --quiet; then
    git commit -m "sync from host"
    echo "Committed changes."
else
    echo "No new changes to commit."
fi
_devshow_tree=$(git rev-parse 'HEAD^{tree}')

_dev_push_to_container_branch "$_devshow_src_dir" "$_devshow_name" HEAD "$_devshow_repo"

_dev_ensure_proxy

_dev_ensure_running "$_devshow_name"
_dev_warn_if_backup_stale "$_devshow_name"

# Everything in the container's workspace is committed (the same sync as dev
# see, including its repair of a workspace damaged by an unclean stop) and
# pushed to the backup branch, so the checkout below replaces it completely.
# Not backup/show/: it would clash with the container's auto-backup branch
# dev-auto/<name>/backup (see the dev see backup).
_devshow_backup="dev-auto/${_devshow_name}/backup-show/$(date +%s)"
echo "Backing up container state to ${_devshow_backup}..."
_dev_sync_workspace "$_devshow_name" "$_devshow_backup" \
    || echo "WARNING: could not back up the container's workspace to ${_devshow_backup}" >&2

echo "Pulling inside container..."
_dev_ssh_cmd "$_devshow_name" \
    "cd /workspace && git fetch origin ${_devshow_branch} && git checkout -B '${_devshow_branch}' FETCH_HEAD"

# The container must now have exactly the host's content.
_devshow_state=$(_dev_ssh_cmd "$_devshow_name" \
    "cd /workspace && git rev-parse 'HEAD^{tree}' && git status --porcelain | head -n 5")
_devshow_ctree="${_devshow_state%%$'\n'*}"
_devshow_dirty="${_devshow_state#"$_devshow_ctree"}"
if [[ "$_devshow_ctree" != "$_devshow_tree" ]]; then
    _dev_stop_if_was_stopped "$_devshow_name"
    echo "Error: the container checked out tree ${_devshow_ctree}, the host has ${_devshow_tree}" >&2
    exit 1
fi
if [[ -n "${_devshow_dirty//[[:space:]]/}" ]]; then
    echo "WARNING: the container's workspace still has local changes:" >&2
    printf '%s\n' "${_devshow_dirty#$'\n'}" >&2
fi

_dev_stop_if_was_stopped "$_devshow_name"

echo "Done. Container '${_devshow_name}' has the content of host HEAD ($(git log -1 --format='%h %s' HEAD))."
