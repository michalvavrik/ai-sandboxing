#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

readonly _devstop_name="${1:?'Usage: dev-stop.sh <name>'}"

podman stop "$_devstop_name"
echo "Container '${_devstop_name}' stopped."

_dev_maybe_stop_proxy
