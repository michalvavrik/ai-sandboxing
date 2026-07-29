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

_dev_check_container_pat || true
