#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devdel_name="${1:?'Usage: dev-delete.sh <name>'}"

if ! _dev_container_exists "$_devdel_name"; then
    echo "Error: container '${_devdel_name}' does not exist" >&2
    exit 1
fi

podman rm -f "$_devdel_name"
echo "Container '${_devdel_name}' deleted."

_dev_maybe_stop_proxy
