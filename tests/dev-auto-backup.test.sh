#!/bin/bash
# Drives scripts/dev-auto-backup.sh --once with DEV_* overrides (mirrors the
# DEV_WORKSPACE test convention in scripts/dev-workspace-sync.sh). Written
# BEFORE the script exists: these MUST fail until the fix is implemented.
#
# They encode the fix's contract and reproduce the incident's inverse — the
# dead loop wrote zero objects and pushed nothing; here a snapshot must create
# objects, push a backup ref, and advance a readable status file, while a push
# failure must stay LOUD yet keep the local snapshot.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
source tests/lib.sh

readonly SCRIPT=scripts/dev-auto-backup.sh
readonly BRANCH=dev-auto/testhost/backup

run_once() { # <workspace> <status> [remote] — one snapshot; echoes combined output
    DEV_WORKSPACE="$1" DEV_BACKUP_STATUS="$2" DEV_BACKUP_BRANCH="$BRANCH" \
    DEV_BACKUP_REMOTE="${3:-origin}" DEV_BACKUP_INTERVAL=1 \
        bash "$SCRIPT" --once 2>&1
}

# ── Case 1: changes present → objects written, pushed, status advances ────────
case_changes_pushed() {
    echo "-- case 1: changes present → commit + push"
    local tmp; tmp=$(mktemp -d)
    make_ws "$tmp/ws"; make_bare "$tmp/origin.git"
    git -C "$tmp/ws" remote add origin "$tmp/origin.git"
    echo "new work" > "$tmp/ws/feature.txt"

    local out rc
    out=$(run_once "$tmp/ws" "$tmp/status"); rc=$?
    assert_eq 0 "$rc" "case1: exit 0"
    if git -C "$tmp/origin.git" rev-parse --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
        _t_ok "case1: backup ref pushed to origin"
    else
        _t_fail "case1: backup ref NOT pushed to origin"
    fi
    assert_eq "new work" "$(git -C "$tmp/origin.git" show "refs/heads/$BRANCH:feature.txt" 2>/dev/null)" \
        "case1: pushed snapshot contains the uncommitted change"
    assert_file "$tmp/status" "case1: status file written"
    assert_fresh_epoch "$(status_get "$tmp/status" last_run)"  "case1: last_run fresh"
    assert_fresh_epoch "$(status_get "$tmp/status" last_push)" "case1: last_push fresh"
    rm -rf "$tmp"
}

# ── Case 2: no changes → no spurious commit, but loop proved alive ────────────
case_no_changes() {
    echo "-- case 2: no changes → no push, status still refreshed"
    local tmp; tmp=$(mktemp -d)
    make_ws "$tmp/ws"; make_bare "$tmp/origin.git"
    git -C "$tmp/ws" remote add origin "$tmp/origin.git"

    local out rc
    out=$(run_once "$tmp/ws" "$tmp/status"); rc=$?
    assert_eq 0 "$rc" "case2: exit 0"
    if git -C "$tmp/origin.git" rev-parse --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
        _t_fail "case2: unexpected backup ref created"
    else
        _t_ok "case2: no backup ref created when nothing changed"
    fi
    assert_fresh_epoch "$(status_get "$tmp/status" last_run)" "case2: last_run refreshed (loop alive)"
    assert_empty "$(status_get "$tmp/status" last_push)" "case2: last_push not set (nothing pushed)"
    rm -rf "$tmp"
}

# ── Case 3: push fails → local snapshot kept, failure is LOUD ─────────────────
case_push_fails() {
    echo "-- case 3: push fails → local snapshot preserved, loud error"
    local tmp; tmp=$(mktemp -d)
    make_ws "$tmp/ws"
    git -C "$tmp/ws" remote add origin "$tmp/does-not-exist.git"   # unreachable
    echo "important" > "$tmp/ws/wip.txt"

    local out rc
    out=$(run_once "$tmp/ws" "$tmp/status"); rc=$?
    assert_eq 0 "$rc" "case3: exit 0 (best-effort loop keeps running)"
    local sha; sha=$(status_get "$tmp/status" last_commit)
    assert_match "$sha" '^[0-9a-f]{40}$' "case3: local snapshot sha recorded"
    assert_eq commit "$(git -C "$tmp/ws" cat-file -t "$sha" 2>/dev/null)" \
        "case3: local snapshot commit exists despite push failure"
    assert_contains "$(git -C "$tmp/ws" ls-tree -r --name-only "$sha" 2>/dev/null)" wip.txt \
        "case3: local snapshot captured the change"
    assert_empty "$(status_get "$tmp/status" last_push)" "case3: last_push not set (push failed)"
    assert_contains "$out" "push" "case3: push failure is reported loudly"
    rm -rf "$tmp"
}

# ── Case 4: host-side staleness formatter (pure, integer math, no `date -d`) ──
case_staleness_formatter() {
    echo "-- case 4: _dev_fmt_backup_age formatting"
    fmt() { bash -c 'source scripts/dev-common.sh >/dev/null 2>&1; _dev_fmt_backup_age "$@"' _ "$@"; }
    assert_eq never "$(fmt '' 1000)" "case4: missing epoch → never"
    local fresh; fresh=$(fmt 988 1000)      # 12s old, under threshold
    assert_contains "$fresh" 12s   "case4: recent → '12s ago'"
    assert_not_contains "$fresh" STALE "case4: recent is not stale"
    assert_contains "$(fmt 0 100000)" STALE "case4: very old → STALE"
}

case_changes_pushed
case_no_changes
case_push_fails
case_staleness_formatter
finish
