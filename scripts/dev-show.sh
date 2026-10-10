#!/bin/bash
# dev show — push the host's current branch into a container. Uncommitted host
# changes are committed first ("sync from host"). The commits are copied to
# dev-auto/<name>/main on the automation fork with GitHub issue/PR references
# removed from their messages (see dev-git-sanitize.sh), then checked out in
# the container.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devshow_name="${1:-}"

# ── Resolve container name ────────────────────────────────────────────────────
if [[ -z "$_devshow_name" ]]; then
    _devshow_name=$(_dev_resolve_name "" 2>/dev/null) || true
fi

if [[ -z "$_devshow_name" ]] && git rev-parse --is-inside-work-tree &>/dev/null; then
    _devshow_tkey=$(_dev_detect_template_from_cwd 2>/dev/null) || true
    if [[ -n "$_devshow_tkey" ]]; then
        _devshow_cur=$(git branch --show-current 2>/dev/null) || true
        if [[ -n "$_devshow_cur" ]]; then
            _devshow_name=$(_dev_branch_to_container_name "$_devshow_cur" "${_devshow_tkey#*/}")
        fi
    fi
fi

if [[ -z "$_devshow_name" ]]; then
    echo "Error: no container specified and could not determine from branch." >&2
    echo "Use 'dev use <name>' first or provide a container name." >&2
    exit 1
fi

readonly _devshow_name

if ! _dev_container_exists "$_devshow_name"; then
    echo "Error: container '${_devshow_name}' does not exist" >&2
    exit 1
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

_dev_push_to_container_branch "$_devshow_src_dir" "$_devshow_name" HEAD "$_devshow_repo"

_dev_ensure_proxy

_dev_ensure_running "$_devshow_name"

_devshow_backup="dev-auto/${_devshow_name}/backup/show/$(date +%s)"
echo "Backing up container state to ${_devshow_backup}..."
_dev_ssh_cmd "$_devshow_name" \
    "cd /workspace && git add -A && git reset HEAD -- .pr .issue .pnpm-store 2>/dev/null; git diff --cached --quiet || git commit -m 'backup'; git push origin HEAD:refs/heads/${_devshow_backup}" 2>/dev/null || true

echo "Pulling inside container..."
_dev_ssh_cmd "$_devshow_name" \
    "cd /workspace && git fetch origin ${_devshow_branch} && git checkout -B '${_devshow_branch}' FETCH_HEAD"

_dev_stop_if_was_stopped "$_devshow_name"

echo "Done. Container '${_devshow_name}' updated with host changes."
