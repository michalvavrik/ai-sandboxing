#!/bin/bash
# Runs INSIDE a dev container (piped over SSH by _dev_sync_workspace) to stage
# /workspace, commit a "WIP sync", and force-push it to the container's dev-auto
# branch ($1). DEV_WORKSPACE overrides the workspace dir (for tests).
#
# Before syncing it repairs object-store/ref damage that an unclean microVM stop
# can leave behind — git fsyncs neither refs nor loose objects by default, so a
# hard stop right after a commit can zero just-written files. On a healthy repo
# every repair below is a no-op and the commit/push path is byte-for-byte the
# normal sync.

_branch="${1:?usage: dev-workspace-sync.sh <branch>}"
cd "${DEV_WORKSPACE:-/workspace}" || exit 1

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

# A broken current-branch ref leaves HEAD unresolvable ("reference broken"), so
# a normal commit cannot lock HEAD. Reduce it to an unborn branch; the commit
# below then captures the full working tree as a fresh root commit (prior
# history was already lost with the zeroed objects).
if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    _ref="$(git symbolic-ref -q HEAD)"
    [[ -n "$_ref" ]] || _ref="refs/heads/${_branch}"
    git update-ref -d "$_ref" 2>/dev/null || rm -f ".git/${_ref}"
fi

git add -A
git reset HEAD -- .pr .issue .pnpm-store 2>/dev/null
git diff --cached --quiet || git commit -m 'WIP sync'
git push -f origin "HEAD:refs/heads/${_branch}"
