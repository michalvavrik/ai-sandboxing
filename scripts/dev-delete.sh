#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devdel_name=$(_dev_resolve_name "${1:-}")
readonly _devdel_name

if ! _dev_container_exists "$_devdel_name"; then
    echo "Error: container '${_devdel_name}' does not exist" >&2
    exit 1
fi

# Delete remote branch if it was pushed
_devdel_template_key=$(podman inspect --format '{{index .Config.Labels "dev-template-key"}}' "$_devdel_name" 2>/dev/null) || true
if [[ -n "$_devdel_template_key" ]]; then
    _devdel_repo="${_devdel_template_key#*/}"
    _devdel_git_ssh="ssh -i ${DEV_KEYS_DIR}/id_ed25519_dev_automation -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
    _devdel_remote="git@github.com:${DEV_AUTOMATION_USER}/${_devdel_repo}.git"
    _devdel_refs=$(GIT_SSH_COMMAND="$_devdel_git_ssh" \
        git ls-remote --refs "$_devdel_remote" "refs/heads/dev-auto/${_devdel_name}/*" 2>/dev/null \
        | awk '{print $2}') || true
    if [[ -n "$_devdel_refs" ]]; then
        GIT_SSH_COMMAND="$_devdel_git_ssh" \
            git push "$_devdel_remote" --delete $_devdel_refs 2>/dev/null || true
    fi
fi

# Revoke Antigravity CLI OAuth token (read from bounded disk image via debugfs — works whether container is running or stopped)
_devdel_agy_disk="${DEV_DISK_DIR}/${_devdel_name}.img"
_devdel_agy_refresh=""
if [[ -f "$_devdel_agy_disk" ]]; then
    _devdel_agy_token_file=$(debugfs -R "cat home-upper/.gemini/antigravity-cli/antigravity-oauth-token" "$_devdel_agy_disk" 2>/dev/null) || true
    if [[ -n "$_devdel_agy_token_file" ]]; then
        _devdel_agy_refresh=$(echo "$_devdel_agy_token_file" | jq -r '.token.refresh_token // empty' 2>/dev/null) || true
    fi
fi

_devdel_agy_used=false
if [[ -f "$_devdel_agy_disk" ]] && debugfs -R "stat agy-used" "$_devdel_agy_disk" &>/dev/null; then
    _devdel_agy_used=true
fi

if [[ -n "$_devdel_agy_refresh" ]]; then
    curl -sf -X POST "https://oauth2.googleapis.com/revoke?token=${_devdel_agy_refresh}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        && echo "Antigravity CLI OAuth token revoked." \
        || echo "WARNING: Failed to revoke Antigravity CLI token — revoke manually at myaccount.google.com/permissions" >&2
elif [[ "$_devdel_agy_used" == true ]]; then
    echo "WARNING: Antigravity CLI was used but no OAuth token found — it may have been deleted." >&2
    echo "         Revoke manually at: https://myaccount.google.com/permissions" >&2
fi

_dev_release_proxy_port "$_devdel_name"
podman rm -f "$_devdel_name"
_dev_remove_ssh_config "$_devdel_name"
echo "Container '${_devdel_name}' deleted."

# Remove bounded disk files
for _devdel_disk in "${DEV_DISK_DIR}/${_devdel_name}.img" "${DEV_DISK_DIR}/${_devdel_name}-podman.img"; do
    [[ -f "$_devdel_disk" ]] && rm -f "$_devdel_disk"
done
echo "Bounded disks removed."

# Clean orphaned disk files (no matching container)
for _devdel_img in "${DEV_DISK_DIR}/"*.img; do
    [[ -f "$_devdel_img" ]] || continue
    _devdel_cname="$(basename "$_devdel_img" .img)"
    _devdel_cname="${_devdel_cname%-podman}"
    if ! _dev_container_exists "$_devdel_cname"; then
        rm -f "$_devdel_img"
        echo "Cleaned orphaned disk: $(basename "$_devdel_img")"
    fi
done

podman image prune -f &>/dev/null &
_dev_maybe_stop_proxy

# Warn if images are using too much disk
_devdel_img_size=$(podman system df --format '{{.Size}}' 2>/dev/null | head -1)
_devdel_img_bytes=$(podman system df --format '{{.RawSize}}' 2>/dev/null | head -1) || true
if [[ -n "$_devdel_img_bytes" ]] && (( _devdel_img_bytes > 15000000000 )); then
    echo "WARNING: container images using ${_devdel_img_size}. Run 'podman image prune -a' to clean up (removes unused images)." >&2
fi
