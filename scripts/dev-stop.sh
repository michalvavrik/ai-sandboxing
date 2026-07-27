#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devstop_name=$(_dev_resolve_name "${1:-}")
readonly _devstop_name

podman stop "$_devstop_name"
echo "Container '${_devstop_name}' stopped."

_dev_maybe_stop_proxy
