#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

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

readonly _devcp_port=$(_dev_ssh_port "$_devcp_name")

_dev_ssh_cmd "$_devcp_name" 'mkdir -p /tmp/workspace'

scp -q -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -P "$_devcp_port" \
    "$@" "dev-sandbox:/tmp/workspace/"

echo "Copied $# item(s) to /tmp/workspace/"
