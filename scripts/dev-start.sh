#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devstart_name=$(_dev_resolve_name "${1:-}")
readonly _devstart_name

# Ensure proxy is running before starting the container
_dev_ensure_proxy

podman start "$_devstart_name"
echo "Container '${_devstart_name}' started."
