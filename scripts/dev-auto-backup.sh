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
# Overridable for tests (mirrors DEV_WORKSPACE in dev-workspace-sync.sh):
#   DEV_WORKSPACE       workspace git dir             (default /workspace)
#   DEV_BACKUP_STATUS   status file written each run  (default /mnt/bounded/backup/status)
#   DEV_BACKUP_BRANCH   branch force-pushed on change (default dev-auto/<hostname>/backup)
#   DEV_BACKUP_REMOTE   git remote to push to         (default origin)
#   DEV_BACKUP_INTERVAL seconds between snapshots      (default 30)
# Pass --once to take a single snapshot and exit (used by the tests).
set -uo pipefail

readonly _ab_workspace="${DEV_WORKSPACE:-/workspace}"
readonly _ab_status="${DEV_BACKUP_STATUS:-/mnt/bounded/backup/status}"
readonly _ab_branch="${DEV_BACKUP_BRANCH:-dev-auto/$(hostname)/backup}"
readonly _ab_remote="${DEV_BACKUP_REMOTE:-origin}"
readonly _ab_interval="${DEV_BACKUP_INTERVAL:-30}"

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

# One snapshot. Never exits the loop on push failure — the local commit still
# has recovery value (debugfs / dev see), so it is kept and the error is loud.
_ab_once() {
    cd "$_ab_workspace" 2>/dev/null || { _ab_warn "workspace ${_ab_workspace} unavailable"; return 1; }

    local _idxdir _idx _tree _head _head_tree _commit _now _err
    _now=$(date +%s)

    # Fresh (non-existent) index path: git refuses an existing empty file with
    # "index file smaller than expected", so never hand it one `mktemp` created.
    _idxdir=$(mktemp -d) || return 1
    _idx="${_idxdir}/index"
    GIT_INDEX_FILE="$_idx" git add -A 2>/dev/null
    _tree=$(GIT_INDEX_FILE="$_idx" git write-tree 2>/dev/null) \
        || { rm -rf "$_idxdir"; _ab_warn "git write-tree failed"; return 1; }
    rm -rf "$_idxdir"

    _head=$(git rev-parse HEAD 2>/dev/null)      || { _ab_warn "no HEAD to back up"; return 1; }
    _head_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null) || { _ab_warn "no HEAD tree"; return 1; }

    _ab_status_set last_run "$_now"

    if [ "$_tree" = "$_head_tree" ]; then
        _ab_log "no changes to back up"
        return 0
    fi

    _commit=$(git commit-tree "$_tree" -p "$_head" -m "backup" 2>/dev/null) \
        || { _ab_warn "git commit-tree failed"; return 1; }
    _ab_status_set last_commit "$_commit"

    if _err=$(git push -f "$_ab_remote" "$_commit:refs/heads/${_ab_branch}" 2>&1); then
        _ab_status_set last_push "$_now"
        _ab_log "pushed ${_commit} -> ${_ab_remote}/${_ab_branch}"
    else
        _ab_status_set last_error "$(printf '%s' "$_err" | tr '\n' ' ')"
        _ab_warn "push to ${_ab_remote}/${_ab_branch} failed (snapshot ${_commit} kept locally): ${_err}"
    fi
    return 0
}

if [ "${1:-}" = "--once" ]; then
    _ab_once
    exit 0
fi

while sleep "$_ab_interval"; do
    _ab_once
done
