#!/bin/bash
# Runs INSIDE a dev container (piped over SSH by _dev_sync_workspace) to stage
# /workspace, commit a "WIP sync", and force-push it to the container's dev-auto
# branch. DEV_WORKSPACE overrides the workspace dir (for tests).
#
#   dev-workspace-sync.sh [--repair] <branch>
#
# Before syncing it repairs object-store/ref damage that an unclean microVM stop
# can leave behind — git fsyncs neither refs nor loose objects by default, so a
# hard stop right after a commit can zero just-written files. On a healthy repo
# every repair below is a no-op and the commit/push path is byte-for-byte the
# normal sync. With --repair (the entrypoint, at every container start) it stops
# after the repairs: nothing is committed or pushed.

_repair_only=false
if [[ "${1:-}" == "--repair" ]]; then
    _repair_only=true
    shift
fi
_branch="${1:?usage: dev-workspace-sync.sh [--repair] <branch>}"
cd "${DEV_WORKSPACE:-/workspace}" || exit 1

# Stale lock files (git interrupted: ssh dropped, VM killed). Nothing runs git
# at container start, so they would only block every later command.
if [[ "$_repair_only" == true ]]; then
    find .git -name '*.lock' -type f -delete 2>/dev/null
fi

# Zero-length or garbled HEAD makes git refuse the whole repository ("not a git
# repository"): point it at the branch again.
if [[ -d .git/objects && -d .git/refs ]] && ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ref: refs/heads/${_branch}" > .git/HEAD
fi

# Zero-length index (killed mid-write): drop it, git rebuilds from the tree.
if [[ -f .git/index && ! -s .git/index ]]; then
    rm -f .git/index
fi

# Zero-length packfiles (.pack emptied while .idx still advertises its objects)
# make every object read fail with "far too short to be a packfile". Park the
# triple so git falls back to loose objects; move (don't delete) to keep it.
for _pack in .git/objects/pack/*.pack; do
    [[ -e "$_pack" && ! -s "$_pack" ]] || continue
    mkdir -p .git/broken-objects
    mv -f "${_pack%.pack}".pack "${_pack%.pack}".idx "${_pack%.pack}".rev \
        .git/broken-objects/ 2>/dev/null
done

# Empty loose objects ("object file ... is empty"): remove so git treats them
# as absent instead of erroring on every read.
find .git/objects -type f -empty -delete 2>/dev/null

# A zeroed current-branch ref leaves HEAD unresolvable ("reference broken"), so
# a normal commit cannot lock HEAD. Put the ref back at the newest commit of its
# reflog that still exists; when none does, reduce it to an unborn branch, and
# the commit below captures the full working tree as a fresh root commit.
if ! git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
    # Read the symref from the file: git symbolic-ref refuses a broken HEAD.
    # A detached HEAD at a lost commit goes back to the branch.
    _ref=$(sed -n 's/^ref: //p' .git/HEAD 2>/dev/null)
    if [[ -z "$_ref" ]]; then
        _ref="refs/heads/${_branch}"
        echo "ref: ${_ref}" > .git/HEAD
    fi
    if ! git rev-parse --verify -q "${_ref}^{commit}" >/dev/null 2>&1; then
        _last=""
        while read -r _old _new _rest; do
            if [[ -n "$_new" ]] && git cat-file -e "${_new}^{commit}" 2>/dev/null; then
                _last="$_new"
                break
            fi
        done < <(tac ".git/logs/${_ref}" 2>/dev/null)
        rm -f ".git/${_ref}"
        if [[ -n "$_last" ]]; then
            git update-ref "$_ref" "$_last"
        fi
    fi
fi

if [[ "$_repair_only" == true ]]; then
    exit 0
fi

git add -A
git reset HEAD -- .pr .issue .pnpm-store 2>/dev/null
git diff --cached --quiet || git commit -m 'WIP sync'
git push -f origin "HEAD:refs/heads/${_branch}"
