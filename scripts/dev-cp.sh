#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

if [[ $# -eq 0 ]]; then
    echo "Usage: dev cp <path>... " >&2
    echo "Copies files/dirs into the current container's /workspace" >&2
    exit 1
fi

readonly _devcp_name=$(_dev_resolve_name "")

if ! _dev_container_running "$_devcp_name"; then
    echo "Error: container '${_devcp_name}' is not running" >&2
    exit 1
fi

_dev_update_ssh_config "$_devcp_name"
_dev_ssh_cmd "$_devcp_name" 'mkdir -p /tmp/workspace'

scp -q -r "$@" "${_devcp_name}:/tmp/workspace/"

echo "Copied $# item(s) to /tmp/workspace/"
