#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

if [[ $# -eq 0 ]]; then
    echo "Usage: dev cp <path>... " >&2
    echo "Copies files/dirs into the current container's /workspace" >&2
    exit 1
fi

if [[ -z "${DEV_LAST_CONTAINER:-}" ]]; then
    echo "Error: no container selected." >&2
    echo "Either use 'dev enter <name>' first, or: export DEV_LAST_CONTAINER=<name>" >&2
    exit 1
fi
readonly _devcp_name="$DEV_LAST_CONTAINER"

if ! _dev_container_running "$_devcp_name"; then
    echo "Error: container '${_devcp_name}' is not running" >&2
    exit 1
fi

readonly _devcp_port=$(_dev_ssh_port "$_devcp_name")
readonly _devcp_key="${DEV_KEYS_DIR}/id_ed25519_dev_automation"

_dev_ssh_cmd "$_devcp_name" 'mkdir -p /tmp/workspace'

scp -q -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$_devcp_key" -P "$_devcp_port" \
    "$@" "dev@127.0.0.1:/tmp/workspace/"

echo "Copied $# item(s) to /tmp/workspace/"
