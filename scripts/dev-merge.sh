#!/bin/bash
# dev merge / dev squash — put the agent's work on in-review/<feature> as your
# own commit. Both work on what `dev see` fetched (the host branch
# dev-auto/<container>/main), never on the container directly, never rebase and
# never push. See _devmerge_usage.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devmerge_usage() {
    cat <<'USAGE'
Usage: dev merge [-m <message>] [name]
       dev squash [name]

Takes the agent's changes as fetched by the last `dev see` (host branch
dev-auto/<container>/main) and records them on in-review/<feature> as a commit
of your host git identity. Nothing is pushed; in-review/<feature> is checked
out when done.

  dev merge   One new commit (message from -m or your editor, Signed-off-by
              added). in-review/<feature> is created when it does not exist
              yet; then the commit starts where the container's work started.
  dev squash  The changes are folded into the current HEAD commit of
              in-review/<feature> (message and author date kept — like
              git commit --amend). The branch must exist.

The target branch is the base the container's commits are added to; it is
expected not to change behind the container's back. If it did (no commit in
the container has its current content), both abort without changing anything
and tell you how to continue by hand.

The target branch is the branch the container was created from with `dev .`
(main -> main, feature-x -> feature-x; wip/x -> in-review/x). Containers
created from an issue, a PR or by `dev new` use in-review/<feature>
(keycloak-53157 -> in-review/53157, keycloak-pr-51877 -> in-review/pr-51877;
a PR container of your own PR targets the PR's in-review/* branch).
USAGE
}

_devmerge_mode="merge"
_devmerge_message=""
_devmerge_name_arg=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --squash) _devmerge_mode="squash"; shift ;;
        -m) _devmerge_message="${2:?'-m requires a message'}"; shift 2 ;;
        -m*) _devmerge_message="${1#-m}"; shift ;;
        --help|-h) _devmerge_usage; exit 0 ;;
        -*) echo "dev ${_devmerge_mode}: unknown option '$1'" >&2; _devmerge_usage >&2; exit 1 ;;
        *) _devmerge_name_arg="$1"; shift ;;
    esac
done
if [[ "$_devmerge_mode" == "squash" && -n "$_devmerge_message" ]]; then
    echo "dev squash: -m is not supported (the message of the amended commit is kept)" >&2
    exit 1
fi

_devmerge_name=$(_dev_resolve_name "$_devmerge_name_arg")
readonly _devmerge_name

if ! _dev_container_exists "$_devmerge_name"; then
    echo "Error: container '${_devmerge_name}' does not exist" >&2
    exit 1
fi

_devmerge_template_key=$(_dev_container_template_key "$_devmerge_name")
if [[ -z "$_devmerge_template_key" ]]; then
    echo "Error: could not determine template from container labels" >&2
    exit 1
fi
_devmerge_repo="${_devmerge_template_key#*/}"
_devmerge_src=$(_dev_resolve_src_dir "$_devmerge_template_key") || {
    echo "Error: source directory not found for '${_devmerge_template_key}'" >&2
    exit 1
}
readonly _devmerge_src _devmerge_repo

_devmerge_target=$(_dev_container_target_branch "$_devmerge_name" "$_devmerge_repo")
readonly _devmerge_target
readonly _devmerge_agent="dev-auto/${_devmerge_name}/main"
_devmerge_label=$(_dev_container_label "$_devmerge_name" "dev-original-branch")

_dg() { git -C "$_devmerge_src" "$@"; }

if ! _dg rev-parse -q --verify "refs/heads/${_devmerge_agent}" >/dev/null; then
    echo "Error: host branch ${_devmerge_agent} not found — run 'dev see ${_devmerge_name}' first" >&2
    exit 1
fi
_devmerge_agent_sha=$(_dg rev-parse "refs/heads/${_devmerge_agent}")
_devmerge_agent_tree=$(_dg rev-parse "${_devmerge_agent_sha}^{tree}")

_devmerge_user_name=$(_dg config user.name 2>/dev/null) || true
_devmerge_user_email=$(_dg config user.email 2>/dev/null) || true
if [[ -z "$_devmerge_user_name" || -z "$_devmerge_user_email" ]]; then
    echo "Error: git user.name or user.email not configured in ${_devmerge_src}" >&2
    exit 1
fi

echo "Container:  ${_devmerge_name}"
echo "Source:     ${_devmerge_agent} ($(_dg log -1 --format='%h %s' "$_devmerge_agent_sha"))"
echo "Target:     ${_devmerge_target}"

# ── Warn when the container has moved on since the last dev see ──────────────
if _dev_container_running "$_devmerge_name" && _dev_update_ssh_config "$_devmerge_name" 2>/dev/null; then
    _devmerge_state=$(ssh -q -o ConnectTimeout=3 -o BatchMode=yes "$_devmerge_name" \
        'cd /workspace && git rev-parse HEAD && git status --porcelain | head -n1' </dev/null 2>/dev/null) || _devmerge_state=""
    if [[ -n "$_devmerge_state" ]]; then
        _devmerge_chead="${_devmerge_state%%$'\n'*}"
        _devmerge_cdirty="${_devmerge_state#"$_devmerge_chead"}"
        if [[ "$_devmerge_chead" != "$_devmerge_agent_sha" || -n "${_devmerge_cdirty//[[:space:]]/}" ]]; then
            echo "WARNING: container '${_devmerge_name}' has changes that 'dev see' has not fetched — using the last dev see." >&2
        fi
    fi
fi

# Where the container's work starts: the newest commit on the agent branch's
# first-parent chain that was not made by the sandbox (agent commits, WIP
# syncs, host syncs). Everything above it is what the container added.
_devmerge_container_base() {
    local _sha _email _subject
    while read -r _sha _email _subject; do
        [[ -z "$_sha" ]] && continue
        [[ "$_email" == "$DEV_AUTOMATION_EMAIL" ]] && continue
        if [[ "$_email" == "$_devmerge_user_email" ]]; then
            case "$_subject" in
                WIP|"sync from host"|"WIP sync"|backup) continue ;;
            esac
        fi
        echo "$_sha"
        return 0
    done < <(_dg log --first-parent --format='%H %ae %s' "$_devmerge_agent_sha")
    return 1
}

# ── Parent of the new commit ─────────────────────────────────────────────────
_devmerge_target_exists=false
if _dg rev-parse -q --verify "refs/heads/${_devmerge_target}" >/dev/null; then
    _devmerge_target_exists=true
    _devmerge_parent=$(_dg rev-parse "refs/heads/${_devmerge_target}")
elif [[ "$_devmerge_mode" == "squash" ]]; then
    echo "Error: ${_devmerge_target} does not exist — use 'dev merge' to create it" >&2
    exit 1
elif [[ "$_devmerge_label" == wip/* ]] && _dg rev-parse -q --verify "refs/heads/${_devmerge_label}" >/dev/null; then
    # wip/<f> graduates to in-review/<f>: the first commit continues wip/<f>.
    _devmerge_parent=$(_dg rev-parse "refs/heads/${_devmerge_label}")
    echo "Base:       ${_devmerge_label} (branch the container was created from)"
else
    # First commit on a new branch: start where the container's work started.
    if ! _devmerge_parent=$(_devmerge_container_base); then
        echo "Error: could not find where the container's work starts on ${_devmerge_agent}" >&2
        exit 1
    fi
    echo "Base:       $(_dg log -1 --format='%h %s' "$_devmerge_parent") (where the container's work started)"
fi
_devmerge_parent_tree=$(_dg rev-parse "${_devmerge_parent}^{tree}")

# ── Tree of the new commit ───────────────────────────────────────────────────
# The container works on top of exactly what is on the target branch (dev show
# / dev . push it there — commit messages rewritten, content identical), so
# some commit on the agent branch has the parent's tree and the result is
# simply the agent's tree: the container's commits are added on top of the
# base. If the base changed on the host since (no such commit), it has
# diverged from what the container worked on: abort, that is yours to sort out.
_devmerge_tree=""
if _dg merge-base --is-ancestor "$_devmerge_parent" "$_devmerge_agent_sha"; then
    _devmerge_tree="$_devmerge_agent_tree"
else
    _devmerge_mb=$(_dg merge-base "$_devmerge_parent" "$_devmerge_agent_sha" 2>/dev/null) || _devmerge_mb=""
    if _dg log --format='%T' ${_devmerge_mb:+"^${_devmerge_mb}"} ${_devmerge_mb:-"-n 500"} "$_devmerge_agent_sha" | grep -qxF "$_devmerge_parent_tree"; then
        _devmerge_tree="$_devmerge_agent_tree"
    else
        _devmerge_cbase=$(_devmerge_container_base) || _devmerge_cbase=""
        echo "Error: ${_devmerge_target} changed since the container got it — no commit on ${_devmerge_agent} has the content of $(_dg log -1 --format='%h (%s)' "$_devmerge_parent")." >&2
        echo "Nothing was changed. Continue by hand, either:" >&2
        echo "  git checkout ${_devmerge_target} && dev show ${_devmerge_name}     # give the container the current branch, let the agent redo its changes, dev see again" >&2
        if [[ -n "$_devmerge_cbase" ]]; then
            echo "  git checkout ${_devmerge_target} && git cherry-pick ${_devmerge_cbase:0:12}..${_devmerge_agent}     # apply the container's commits yourself" >&2
        fi
        exit 1
    fi
fi

if [[ "$_devmerge_tree" == "$_devmerge_parent_tree" ]]; then
    if [[ "$_devmerge_mode" == "squash" ]]; then
        echo "Nothing to squash: ${_devmerge_target} already has the container's changes."
    else
        echo "Nothing to merge: no changes on top of $(_dg log -1 --format='%h' "$_devmerge_parent")."
    fi
    exit 0
fi

echo ""
_dg diff --stat "$_devmerge_parent" "$_devmerge_tree"
echo ""

_devmerge_sign=()
if [[ "$(_dg config --type=bool commit.gpgsign 2>/dev/null)" == "true" ]]; then
    _devmerge_sign=(-S)
fi

_devmerge_msgfile=$(mktemp)
trap 'rm -f "$_devmerge_msgfile"' EXIT

# ── Create the commit ────────────────────────────────────────────────────────
if [[ "$_devmerge_mode" == "merge" ]]; then
    if [[ -n "$_devmerge_message" ]]; then
        printf '%s\n' "$_devmerge_message" > "$_devmerge_msgfile"
    else
        if [[ ! -t 0 || ! -t 1 ]]; then
            echo "Error: no terminal for the editor — pass the message with -m" >&2
            exit 1
        fi
        {
            echo ""
            if [[ "$_devmerge_target_exists" == true ]]; then
                echo "# Commit message for a new commit on ${_devmerge_target}."
            else
                echo "# Commit message for the first commit on ${_devmerge_target} (new branch)."
            fi
            echo "# Lines starting with '#' are ignored; an empty message aborts."
            echo "# Signed-off-by: ${_devmerge_user_name} <${_devmerge_user_email}> is added automatically."
            echo "#"
            echo "# Changes:"
            _dg diff --stat "$_devmerge_parent" "$_devmerge_tree" | sed 's/^/#   /'
        } > "$_devmerge_msgfile"
        _devmerge_editor=$(_dg var GIT_EDITOR)
        (cd "$_devmerge_src" && eval "$_devmerge_editor \"\$_devmerge_msgfile\"") || {
            echo "Error: editor exited with an error, aborting" >&2
            exit 1
        }
    fi
    _devmerge_msg=$(_dg stripspace --strip-comments < "$_devmerge_msgfile")
    if [[ -z "${_devmerge_msg//[[:space:]]/}" ]]; then
        echo "Aborting: empty commit message." >&2
        exit 1
    fi
    printf '%s\n' "$_devmerge_msg" \
        | _dg interpret-trailers --if-exists addIfDifferent \
            --trailer "Signed-off-by: ${_devmerge_user_name} <${_devmerge_user_email}>" \
        > "$_devmerge_msgfile"

    _devmerge_new=$(_dg commit-tree "$_devmerge_tree" -p "$_devmerge_parent" "${_devmerge_sign[@]}" -F "$_devmerge_msgfile")
else
    _dg log -1 --format=%B "$_devmerge_parent" | _dg stripspace > "$_devmerge_msgfile"
    _devmerge_parents=()
    for _devmerge_p in $(_dg rev-list --parents -n1 "$_devmerge_parent" | cut -d' ' -f2-); do
        _devmerge_parents+=(-p "$_devmerge_p")
    done
    _devmerge_author_date=$(_dg log -1 --format=%ad --date=raw "$_devmerge_parent")
    _devmerge_new=$(GIT_AUTHOR_NAME="$_devmerge_user_name" GIT_AUTHOR_EMAIL="$_devmerge_user_email" \
        GIT_AUTHOR_DATE="$_devmerge_author_date" \
        _dg commit-tree "$_devmerge_tree" "${_devmerge_parents[@]}" "${_devmerge_sign[@]}" -F "$_devmerge_msgfile")
fi

# ── Move the branch and check it out ─────────────────────────────────────────
_devmerge_current=$(_dg branch --show-current 2>/dev/null) || _devmerge_current=""
if [[ "$_devmerge_current" == "$_devmerge_target" ]]; then
    # Already on the branch: move it and update the working tree together,
    # keeping local changes (refuses — and changes nothing — if they conflict).
    if ! _dg reset -q --keep "$_devmerge_new"; then
        echo "Error: ${_devmerge_target} is checked out with local changes in the way; commit or stash them and retry" >&2
        exit 1
    fi
else
    if [[ "$_devmerge_target_exists" == true ]]; then
        _dg update-ref "refs/heads/${_devmerge_target}" "$_devmerge_new" "$_devmerge_parent"
    else
        _dg update-ref "refs/heads/${_devmerge_target}" "$_devmerge_new" ""
    fi
    if ! _dg checkout -q "$_devmerge_target"; then
        echo "NOTE: ${_devmerge_target} updated but could not be checked out (local changes?); run: git -C ${_devmerge_src} checkout ${_devmerge_target}" >&2
    fi
fi

if [[ "$_devmerge_mode" == "squash" ]]; then
    echo "Amended ${_devmerge_target}: $(_dg log -1 --format='%h %s' "$_devmerge_new")"
elif [[ "$_devmerge_target_exists" == true ]]; then
    echo "Added to ${_devmerge_target}: $(_dg log -1 --format='%h %s' "$_devmerge_new")"
else
    echo "Created ${_devmerge_target}: $(_dg log -1 --format='%h %s' "$_devmerge_new")"
fi
echo "Author: ${_devmerge_user_name} <${_devmerge_user_email}>"

if _dg remote get-url "$DEV_GHCR_USER" &>/dev/null; then
    if [[ "$_devmerge_mode" == "squash" ]]; then
        echo "Push with: git push --force-with-lease ${DEV_GHCR_USER} ${_devmerge_target}"
    elif [[ "$_devmerge_target_exists" == true ]]; then
        echo "Push with: git push ${DEV_GHCR_USER} ${_devmerge_target}"
    else
        echo "Push with: git push -u ${DEV_GHCR_USER} ${_devmerge_target}"
    fi
fi
