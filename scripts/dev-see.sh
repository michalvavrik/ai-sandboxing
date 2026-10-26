#!/bin/bash
# dev see — commit whatever the container's workspace has, push it to
# dev-auto/<name>/main on the automation fork, fetch it and check it out on the
# host: afterwards the host branch dev-auto/<name>/main and its working tree
# are exactly the container's workspace. Commits are kept as they are (no
# squash, no rebase); `dev merge` / `dev squash` later turn them into your own
# commit on in-review/<feature>.
#
# Nothing of the host is carried over. Whatever dev-auto/<name>/main had that
# the container does not — its own commits, uncommitted changes while it is
# checked out (saved as a "WIP" commit first) — is backed up to
# dev-auto/<name>/backup-see/<timestamp> on the automation fork and stays in the
# host's reflog. Uncommitted changes on any other branch are left alone: commit
# or stash them first.
#
# For a study container it fetches the files the agents made into a review
# directory on the host instead, and lists them.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devsee_name_arg=""
for _devsee_arg in "$@"; do
    case "$_devsee_arg" in
        --help|-h) echo "Usage: dev see [name]"; exit 0 ;;
        -*) echo "dev see: unknown option '${_devsee_arg}'" >&2; exit 1 ;;
        *) _devsee_name_arg="$_devsee_arg" ;;
    esac
done

# Only inside the project's source directory, only its containers.
_devsee_name=$(_dev_resolve_project_container "$_devsee_name_arg")
readonly _devsee_name

# A study container: fetch the files the agents made (everything in /workspace
# but the material) into a review directory on the host and list them, newest
# first, against the study directory: A new file, M replaces one of your files
# (same relative path, other content); those with the same content as yours are
# only counted. The study directory is not touched — dev merge takes files from
# the review directory.
if _dev_container_is_study "$_devsee_name"; then
    _devsee_study=$(_dev_container_label "$_devsee_name" "dev-source-dir")
    _devsee_review="${DEV_STUDY_SEE_DIR}/${_devsee_name}"
    _dev_ensure_running "$_devsee_name"
    if ! _dev_study_fetch "$_devsee_name" "$_devsee_review"; then
        _dev_stop_if_was_stopped "$_devsee_name"
        echo "Error: could not fetch the files of '${_devsee_name}'" >&2
        exit 1
    fi
    _dev_stop_if_was_stopped "$_devsee_name"
    echo "Files the agents made, newest first, fetched to ${_devsee_review}/"
    echo "(A new, M replaces your file):"
    (cd "$_devsee_review" && find . -type f -printf '%TY-%Tm-%Td %TH:%TM %s %P\n') \
        | while read -r _d _t _s _p; do
            printf '%s %s %s %s %s\n' "$(_dev_study_mark "${_devsee_review}/${_p}" "${_devsee_study}/${_p}")" "$_d" "$_t" "$_s" "$_p"
        done \
        | sort -r -k2,3 | numfmt --field=4 --to=iec --padding=5 --invalid=ignore \
        | awk '$1 == "=" { same++; next }
               { if (++shown <= 100) print "  " $0 }
               END {
                   if (shown > 100) print "  ... and " shown - 100 " more"
                   if (shown + same == 0) print "  (none yet)"
                   else if (shown == 0) print "  (nothing new or changed)"
                   if (same > 0) print "  (" same " more, the same as yours)"
               }'
    echo "Compare a changed file: diff -u ${_devsee_study}/<path> ${_devsee_review}/<path>"
    echo "Take files into ${_devsee_study}: dev merge (the new ones) or dev merge <path>... (also replaces yours, backed up)"
    exit 0
fi

_devsee_template_key=$(_dev_container_template_key "$_devsee_name")
_devsee_repo="${_devsee_template_key#*/}"
if [[ -z "$_devsee_repo" ]]; then
    echo "Error: could not determine project from container labels" >&2
    exit 1
fi
# The template's source checkout; the current directory for templates without one.
_devsee_src=$(_dev_resolve_src_dir "$_devsee_template_key" 2>/dev/null) || _devsee_src="$(pwd -P)"
if ! git -C "$_devsee_src" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: ${_devsee_src} is not a git repository" >&2
    exit 1
fi

readonly _devsee_branch="dev-auto/${_devsee_name}/main"
_devsee_current=$(git -C "$_devsee_src" branch --show-current 2>/dev/null) || _devsee_current=""

# Uncommitted changes on another branch would be carried over by the checkout
# (or block it half-way), and the host would not show the container's state.
# Refuse before anything is pushed or fetched.
if [[ "$_devsee_current" != "$_devsee_branch" ]] \
    && [[ -n "$(git -C "$_devsee_src" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    echo "Error: ${_devsee_src} has uncommitted changes on ${_devsee_current:-detached HEAD}" >&2
    echo "Commit or stash them first — dev see does not carry them over to ${_devsee_branch}." >&2
    exit 1
fi

_dev_ensure_running "$_devsee_name"

echo "Pushing changes to ${_devsee_branch}..."
_dev_sync_workspace "$_devsee_name" "$_devsee_branch"
echo "Branch: ${_devsee_branch}"
_dev_warn_if_backup_stale "$_devsee_name"

_dev_ensure_automation_remote "$_devsee_src" "$_devsee_repo"

echo "Fetching from ${DEV_AUTOMATION_REMOTE}..."
git -C "$_devsee_src" fetch "$DEV_AUTOMATION_REMOTE" "$_devsee_branch"
# Pin the fetched commit right away: every later fetch overwrites FETCH_HEAD
# (the backup below fetches origin to tell host commits from upstream ones).
_devsee_new=$(git -C "$_devsee_src" rev-parse --verify 'FETCH_HEAD^{commit}')
readonly _devsee_new

if git -C "$_devsee_src" rev-parse -q --verify "refs/heads/${_devsee_branch}" >/dev/null; then
    # Uncommitted changes on the checked-out branch go into a WIP commit: the
    # backup gets them and the checkout below has nothing in its way.
    if [[ "$_devsee_current" == "$_devsee_branch" && -n "$(git -C "$_devsee_src" status --porcelain 2>/dev/null)" ]]; then
        git -C "$_devsee_src" add -A
        git -C "$_devsee_src" commit --quiet -m "WIP" --no-verify
        echo "Uncommitted host changes saved as WIP commit $(git -C "$_devsee_src" rev-parse --short HEAD)."
    fi
    _devsee_old=$(git -C "$_devsee_src" rev-parse "refs/heads/${_devsee_branch}")
    # Nothing to back up when the container's state contains the host's.
    if ! git -C "$_devsee_src" merge-base --is-ancestor "$_devsee_old" "$_devsee_new"; then
        # Not backup/see/: dev-auto/<name>/backup is the container's auto-backup
        # branch, and a branch cannot also be a directory of branches — of the two,
        # the later push is rejected ("cannot lock ref").
        _devsee_backup="dev-auto/${_devsee_name}/backup-see/$(date +%s)"
        echo "Backing up host state ($(git -C "$_devsee_src" rev-parse --short "$_devsee_old")) to ${_devsee_backup}..."
        # Sanitized like dev show: commits made on this host branch can mention issues.
        if ! _devsee_out=$(_dev_push_to_container_branch "$_devsee_src" "$_devsee_name" "$_devsee_old" \
                "$_devsee_repo" "$_devsee_backup" 2>&1); then
            printf '%s\n' "$_devsee_out" >&2
            echo "WARNING: could not back up ${_devsee_branch}; its previous state ${_devsee_old} stays in the host's git reflog" >&2
        fi
    fi
fi

if ! git -C "$_devsee_src" checkout -B "$_devsee_branch" "$_devsee_new"; then
    _dev_stop_if_was_stopped "$_devsee_name"
    echo "Error: could not check out ${_devsee_branch} — see git's message above, then run 'dev see ${_devsee_name}' again" >&2
    echo "(the container's state is already on the automation fork as ${_devsee_branch})" >&2
    exit 1
fi

_dev_stop_if_was_stopped "$_devsee_name"

echo "Done: ${_devsee_branch} is at $(git -C "$_devsee_src" log -1 --format='%h %s' "$_devsee_new")."
