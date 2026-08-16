#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

# ── Pull images and sources first ─────────────────────────────────────────────
"${DEV_SCRIPTS_DIR}/dev-pull.sh"

# ── Prune dead branches per source repo ───────────────────────────────────────
_devsync_conf="${DEV_CONFIGS_DIR}/project-templates.conf"

while IFS='|' read -r _devsync_key _devsync_src _devsync_rest; do
    [[ "$_devsync_key" =~ ^[[:space:]]*# || -z "$_devsync_key" ]] && continue
    [[ "$_devsync_key" == "DEFAULT" ]] && continue
    [[ -z "$_devsync_src" ]] && continue
    _devsync_src_dir="$_devsync_src"
    [[ "$_devsync_src_dir" != /* ]] && _devsync_src_dir="${DEV_SOURCES_DIR}/${_devsync_src_dir}"
    [[ ! -d "$_devsync_src_dir/.git" ]] && continue

    _devsync_org="${_devsync_key%%/*}"
    _devsync_repo="${_devsync_key#*/}"

    echo "Syncing branches for ${_devsync_key}..."

    # ── 1. Delete dev-auto/* host branches where no container exists ──────
    _devsync_seen_containers=""
    while read -r _devsync_da_branch; do
        [[ -z "$_devsync_da_branch" ]] && continue
        _devsync_da_branch="${_devsync_da_branch#\* }"
        _devsync_da_branch="${_devsync_da_branch## }"
        [[ "$_devsync_da_branch" =~ ^dev-auto/([^/]+) ]] || continue
        _devsync_cname="${BASH_REMATCH[1]}"
        echo "$_devsync_seen_containers" | grep -qxF "$_devsync_cname" && continue
        _devsync_seen_containers="${_devsync_seen_containers}
${_devsync_cname}"
        if ! _dev_container_exists "$_devsync_cname"; then
            echo "  dev-auto/${_devsync_cname}/* — no container, deleting..."
            while read -r _devsync_sub; do
                _devsync_sub="${_devsync_sub#\* }"
                _devsync_sub="${_devsync_sub## }"
                [[ -z "$_devsync_sub" ]] && continue
                _dev_backup_and_delete_branch "$_devsync_src_dir" "$_devsync_sub"
            done < <(git -C "$_devsync_src_dir" branch --list "dev-auto/${_devsync_cname}/*" 2>/dev/null)
        fi
    done < <(git -C "$_devsync_src_dir" branch --list 'dev-auto/*' 2>/dev/null)

    # ── 2. Delete wip/* where in-review/* exists ──────────────────────────
    while read -r _devsync_wip; do
        [[ -z "$_devsync_wip" ]] && continue
        _devsync_wip="${_devsync_wip#\* }"
        _devsync_wip="${_devsync_wip## }"
        _devsync_feature="${_devsync_wip#wip/}"
        if git -C "$_devsync_src_dir" rev-parse --verify "in-review/${_devsync_feature}" &>/dev/null; then
            echo "  ${_devsync_wip} — in-review exists, deleting..."
            _dev_backup_and_delete_branch "$_devsync_src_dir" "$_devsync_wip"
        fi
    done < <(git -C "$_devsync_src_dir" branch --list 'wip/*' 2>/dev/null)

    # ── 3. Delete in-review/* where no associated PR exists ───────────────
    while read -r _devsync_ir; do
        [[ -z "$_devsync_ir" ]] && continue
        _devsync_ir="${_devsync_ir#\* }"
        _devsync_ir="${_devsync_ir## }"
        _devsync_feature="${_devsync_ir#in-review/}"

        _devsync_pr_json=""
        _devsync_pr_json=$(gh pr list --state open --head "${_devsync_ir}" \
            --repo "${_devsync_key}" --json number,title --jq '.[0] // empty' 2>/dev/null) || true

        if [[ -z "$_devsync_pr_json" ]]; then
            _devsync_pr_json=$(gh pr list --state open --head "${DEV_GHCR_USER}:${_devsync_ir}" \
                --repo "${_devsync_key}" --json number,title --jq '.[0] // empty' 2>/dev/null) || true
        fi

        if [[ -z "$_devsync_pr_json" ]]; then
            echo "  ${_devsync_ir} — no open PR, deleting..."
            _dev_remove_branch_meta "$_devsync_repo" "$_devsync_feature"
            _dev_backup_and_delete_branch "$_devsync_src_dir" "$_devsync_ir"
        else
            _devsync_pr_num=$(echo "$_devsync_pr_json" | jq -r '.number')
            _devsync_pr_title=$(echo "$_devsync_pr_json" | jq -r '.title')
            _dev_set_branch_meta "$_devsync_repo" "$_devsync_feature" "$_devsync_pr_num" "$_devsync_pr_title"
            echo "  ${_devsync_ir} — PR #${_devsync_pr_num}: ${_devsync_pr_title}"
        fi
    done < <(git -C "$_devsync_src_dir" branch --list 'in-review/*' 2>/dev/null)

    # ── 4. Delete old backup branches ─────────────────────────────────────
    _dev_prune_backup_branches "$_devsync_src_dir"

done < "$_devsync_conf"

echo "Branch sync complete."
