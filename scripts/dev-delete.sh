#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devdel_name="${1:?'Usage: dev-delete.sh <name>'}"

if ! _dev_container_exists "$_devdel_name"; then
    echo "Error: container '${_devdel_name}' does not exist" >&2
    exit 1
fi

podman rm -f "$_devdel_name"
_dev_remove_ssh_config "$_devdel_name"
echo "Container '${_devdel_name}' deleted."

podman image prune -f &>/dev/null &
_dev_maybe_stop_proxy

# Warn if images are using too much disk
_devdel_img_size=$(podman system df --format '{{.Size}}' 2>/dev/null | head -1)
_devdel_img_bytes=$(podman system df --format '{{.RawSize}}' 2>/dev/null | head -1) || true
if [[ -n "$_devdel_img_bytes" ]] && (( _devdel_img_bytes > 15000000000 )); then
    echo "WARNING: container images using ${_devdel_img_size}. Run 'podman image prune -a' to clean up (removes unused images)." >&2
fi
