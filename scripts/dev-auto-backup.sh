#!/bin/bash
# Periodically snapshots the workspace to a backup branch so an un-pushed or
# interrupted session stays recoverable. Runs INSIDE a dev container, launched
# by entrypoint.sh.
#
# Why a standalone script: the old inline loop backgrounded `runuser` itself
# (`runuser ... &`), which silently dies under krun — it wrote zero objects and
# pushed nothing for a whole session. entrypoint.sh now backgrounds this with
# the proven `runuser -u dev -- bash -c '... &'` pattern, and the body below
# reports failures LOUDLY (to its log) instead of swallowing them, and records a
# status file so the host can tell whether backups are actually happening.
#
# The backup branch is a chain of "backup" snapshot commits: the first parent of
# each is the snapshot before it (`git log --first-parent -p` shows how the work
# went), the last parent the workspace's HEAD at that time (commits made here
# are backed up too). A snapshot is added when the workspace — uncommitted and
# untracked files included — or HEAD changed since the last one; nothing is
# pushed while nothing changes. Kept are all snapshots that were the current
# state in the last 10 minutes and, before that, the newest of every 20 minutes
# on the clock (:00, :20, :40). In the workspace the chain is the ref
# refs/dev-auto-backup, which also keeps it from gc.
#
# Overridable for tests (mirrors DEV_WORKSPACE in dev-workspace-sync.sh):
#   DEV_WORKSPACE        workspace git dir                (default /workspace)
#   DEV_BACKUP_STATUS    status file written each run     (default /mnt/bounded/backup/status)
#   DEV_BACKUP_BRANCH    branch force-pushed on change    (default dev-auto/<hostname>/backup)
#   DEV_BACKUP_REMOTE    git remote to push to            (default origin)
#   DEV_BACKUP_INTERVAL  seconds between snapshots         (default 30)
#   DEV_BACKUP_KEEP_ALL  seconds all snapshots are kept    (default 600)
#   DEV_BACKUP_SLOT      older: the newest of each ... s   (default 1200)
# Pass --once to take a single snapshot and exit (used by the tests).
#
# The status file has key=value lines, read by the host (dev list, dev see,
# dev show; see _dev_fmt_backup_state in dev-common.sh):
#   last_run    epoch of the last run (the loop is alive)
#   last_commit the newest snapshot
#   pushed      the snapshot the last push that succeeded sent (retried until newest)
#   last_push   epoch of the last push that succeeded
#   last_fail   epoch of the last push that failed (newer than last_push: failing)
#   last_error  git's output of that failed push
set -uo pipefail

readonly _ab_workspace="${DEV_WORKSPACE:-/workspace}"
readonly _ab_status="${DEV_BACKUP_STATUS:-/mnt/bounded/backup/status}"
readonly _ab_branch="${DEV_BACKUP_BRANCH:-dev-auto/$(hostname)/backup}"
readonly _ab_remote="${DEV_BACKUP_REMOTE:-origin}"
readonly _ab_interval="${DEV_BACKUP_INTERVAL:-30}"
readonly _ab_keep_all="${DEV_BACKUP_KEEP_ALL:-600}"
readonly _ab_slot="${DEV_BACKUP_SLOT:-1200}"
readonly _ab_ref="refs/dev-auto-backup"

_ab_log()  { printf '[dev-auto-backup] %s %s\n' "$(date -u +%FT%TZ)" "$*"; }
_ab_warn() { _ab_log "$*" >&2; }

# Update one `key=value` line in the status file (preserves the other keys).
_ab_status_set() {
    local _key="$1" _val="$2" _tmp
    mkdir -p "$(dirname "$_ab_status")" 2>/dev/null || true
    _tmp=$(mktemp) || return 0
    { [ -f "$_ab_status" ] && grep -v "^${_key}=" "$_ab_status"; echo "${_key}=${_val}"; } >"$_tmp" 2>/dev/null
    mv -f "$_tmp" "$_ab_status" 2>/dev/null || rm -f "$_tmp"
}

# Value of one key in the status file ("" when unset).
_ab_status_get() {
    sed -n "s/^${1}=//p" "$_ab_status" 2>/dev/null | tail -1
}

# The chain ending at snapshot <commit>, oldest first: one line
# "<commit> <tree> <head> <time>" per snapshot. The oldest snapshot has only
# its HEAD as parent; the walk also stops at anything that is no snapshot.
_ab_chain() {
    git log --first-parent --format='%H%x09%T%x09%ct%x09%P%x09%s' "$1" 2>/dev/null \
        | awk -F'\t' '$5 != "backup" { exit }
                      { n = split($4, p, " "); if (n == 0) exit
                        print $1, $2, p[n], $3
                        if (n == 1) exit }' \
        | tac
}

# Force-push the chain ending at <commit>; record how it went.
_ab_push() {
    local _commit="$1" _now _err
    _now=$(date +%s)
    if _err=$(git push -f "$_ab_remote" "${_commit}:refs/heads/${_ab_branch}" 2>&1); then
        _ab_status_set pushed "$_commit"
        _ab_status_set last_push "$_now"
        _ab_log "pushed ${_commit} -> ${_ab_remote}/${_ab_branch}"
    else
        _ab_status_set last_error "$(printf '%s' "$_err" | tr '\n' ' ')"
        _ab_status_set last_fail "$_now"
        _ab_warn "push to ${_ab_remote}/${_ab_branch} failed (snapshot ${_commit} kept locally): ${_err}"
    fi
}

# One run: a new snapshot when something changed, else the retry of a failed
# push. Never exits the loop on push failure — the local chain still has
# recovery value (debugfs / dev see), so it is kept and the error is loud.
_ab_once() {
    cd "$_ab_workspace" 2>/dev/null || { _ab_warn "workspace ${_ab_workspace} unavailable"; return 1; }

    local _idxdir _idx _tree _head _head_tree _tip _last _last_tree _last_head _now
    local _chain=() _i _c _t _h _ts _next _prev="" _rewrite=false _parents=()
    _now=$(date +%s)

    # The workspace's tree, through a copy of its index: git re-reads only the
    # files changed since, and tracked files that match .gitignore stay in (an
    # empty index leaves them out, so the snapshot never equals HEAD). A file
    # git cannot read keeps its indexed version (git add exits 1). When git add
    # dies on the copy (a damaged index — write-tree would still make a tree of
    # it), again from no index: a path that does not exist, since git refuses an
    # empty file ("index file smaller than expected") such as `mktemp` creates.
    _idxdir=$(mktemp -d) || return 1
    _idx="${_idxdir}/index"
    cp -p "$(git rev-parse --git-path index 2>/dev/null)" "$_idx" 2>/dev/null
    [ -s "$_idx" ] || rm -f "$_idx"
    GIT_INDEX_FILE="$_idx" git add -A --ignore-errors 2>/dev/null
    if (( $? >= 128 )); then
        rm -f "$_idx"
        GIT_INDEX_FILE="$_idx" git add -A --ignore-errors 2>/dev/null
        (( $? < 128 )) || { rm -rf "$_idxdir"; _ab_warn "git add failed"; return 1; }
    fi
    _tree=$(GIT_INDEX_FILE="$_idx" git write-tree 2>/dev/null) \
        || { rm -rf "$_idxdir"; _ab_warn "git write-tree failed"; return 1; }
    rm -rf "$_idxdir"

    _head=$(git rev-parse HEAD 2>/dev/null)      || { _ab_warn "no HEAD to back up"; return 1; }
    _head_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null) || { _ab_warn "no HEAD tree"; return 1; }

    _ab_status_set last_run "$_now"

    # The newest snapshot: the ref, else the one the status file names. A ref
    # emptied by an unclean stop blocks every update of it (and makes git warn
    # about it everywhere): removed first.
    if ! _tip=$(git rev-parse -q --verify "${_ab_ref}^{commit}" 2>/dev/null); then
        rm -f "$(git rev-parse --git-path "$_ab_ref")"
        _tip=$(git rev-parse -q --verify "$(_ab_status_get last_commit)^{commit}" 2>/dev/null) || _tip=""
        [ -n "$_tip" ] && git update-ref "$_ab_ref" "$_tip"
    fi

    # Changed since the newest snapshot (its tree and HEAD), or, without one,
    # since HEAD: a clean workspace has nothing to back up.
    if [ -n "$_tip" ]; then
        _last=$(git log -1 --format='%T %P' "$_tip")
        _last_tree=${_last%% *} _last_head=${_last##* }
    else
        _last_tree=$_head_tree _last_head=$_head
    fi
    if [ "$_tree" = "$_last_tree" ] && [ "$_head" = "$_last_head" ]; then
        if [ -n "$_tip" ] && [ "$_tip" != "$(_ab_status_get pushed)" ]; then
            _ab_push "$_tip"
        else
            _ab_log "no changes to back up"
        fi
        return 0
    fi

    # No chain here (a new container, or its ref was lost): continue the one
    # on the fork, if there is one.
    if [ -z "$_tip" ] && git fetch -q --no-write-fetch-head "$_ab_remote" \
            "+refs/heads/${_ab_branch}:${_ab_ref}" 2>/dev/null; then
        _tip=$(git rev-parse -q --verify "${_ab_ref}^{commit}" 2>/dev/null) || _tip=""
    fi

    # The chain plus the new snapshot, oldest first. A snapshot stops being the
    # current state when the next one is taken; once that is more than
    # _ab_keep_all seconds ago, it goes if the next one is in its _ab_slot too.
    # Snapshots before the first one dropped stay as they are, those after it
    # are made again on their new parent, with their own dates.
    [ -n "$_tip" ] && mapfile -t _chain < <(_ab_chain "$_tip")
    _chain+=("- ${_tree} ${_head} ${_now}")
    for _i in "${!_chain[@]}"; do
        read -r _c _t _h _ts <<<"${_chain[$_i]}"
        _next=${_chain[$((_i + 1))]:-}
        _next=${_next##* }
        if [ -n "$_next" ] && (( _now - _next > _ab_keep_all && _next / _ab_slot == _ts / _ab_slot )); then
            _rewrite=true
            continue
        fi
        if [ "$_rewrite" = false ] && [ "$_c" != - ]; then
            _prev=$_c
            continue
        fi
        _rewrite=true
        _parents=()
        [ -n "$_prev" ] && _parents=(-p "$_prev")
        _prev=$(GIT_AUTHOR_DATE="@${_ts} +0000" GIT_COMMITTER_DATE="@${_ts} +0000" \
            git commit-tree "$_t" "${_parents[@]}" -p "$_h" -m "backup" 2>/dev/null) \
            || { _ab_warn "git commit-tree failed"; return 1; }
    done
    git update-ref "$_ab_ref" "$_prev" || { _ab_warn "could not update ${_ab_ref}"; return 1; }
    _ab_status_set last_commit "$_prev"

    _ab_push "$_prev"
    return 0
}

if [ "${1:-}" = "--once" ]; then
    _ab_once
    exit 0
fi

while sleep "$_ab_interval"; do
    _ab_once
done
