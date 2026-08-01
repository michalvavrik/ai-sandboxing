#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

exec 9>/tmp/dev-pull.lock
if ! flock -n 9; then
    echo "Another pull is already running."
    exit 0
fi

_dev_ensure_ghcr_auth

_DEV_IMAGE_REPO="${DEV_IMAGE%:*}"
CONTAINERS_CONF_OVERRIDE=<(printf '[engine]\nimage_parallel_copies = 1\n') \
    podman pull --policy newer "$DEV_IMAGE"
CONTAINERS_CONF_OVERRIDE=<(printf '[engine]\nimage_parallel_copies = 1\n') \
    podman pull --policy newer "${_DEV_IMAGE_REPO}:latest-next" 2>/dev/null || true

# ── Update template project sources ─────────────────────────────────────────
_dev_conf="${DEV_CONFIGS_DIR}/project-templates.conf"
while IFS='|' read -r _dev_key _dev_src _dev_rest; do
    [[ "$_dev_key" =~ ^[[:space:]]*# || -z "$_dev_key" ]] && continue
    [[ "$_dev_key" == "DEFAULT" ]] && continue
    [[ -z "$_dev_src" ]] && continue
    _dev_src_dir="$_dev_src"
    [[ "$_dev_src_dir" != /* ]] && _dev_src_dir="${DEV_SOURCES_DIR}/${_dev_src_dir}"
    [[ ! -d "$_dev_src_dir/.git" ]] && continue

    echo "Fetching ${_dev_src}..."
    git -C "$_dev_src_dir" fetch origin 2>/dev/null || continue

    _dev_default_branch=$(git -C "$_dev_src_dir" remote show origin 2>/dev/null \
        | sed -n 's/.*HEAD branch: //p')
    _dev_default_branch="${_dev_default_branch:-main}"
    _dev_current_branch=$(git -C "$_dev_src_dir" branch --show-current 2>/dev/null)

    if [[ "$_dev_current_branch" == "$_dev_default_branch" ]]; then
        _dev_had_changes=false
        if ! git -C "$_dev_src_dir" diff --quiet HEAD 2>/dev/null; then
            _dev_had_changes=true
            git -C "$_dev_src_dir" stash 2>/dev/null || continue
        fi
        git -C "$_dev_src_dir" pull --rebase origin "$_dev_default_branch" 2>/dev/null || {
            git -C "$_dev_src_dir" rebase --abort 2>/dev/null || true
            echo "  rebase failed for ${_dev_src}" >&2
        }
        if [[ "$_dev_had_changes" == true ]]; then
            git -C "$_dev_src_dir" stash pop 2>/dev/null \
                || echo "  WARNING: stash pop conflict in ${_dev_src} — changes saved in 'git stash'" >&2
        fi
    else
        git -C "$_dev_src_dir" fetch origin "${_dev_default_branch}:${_dev_default_branch}" 2>/dev/null || true
    fi
done < "$_dev_conf"

_dev_check_container_pat || true
