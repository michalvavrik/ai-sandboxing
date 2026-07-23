#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

if [[ $# -eq 0 ]]; then
    echo "Usage: dev cpout <remote-path>..." >&2
    echo "Copies files/dirs from the container to the current directory" >&2
    echo "Paths are relative to /workspace (e.g., dev cpout pom.xml src/main)" >&2
    exit 1
fi

readonly _devcpout_name=$(_dev_resolve_name "")

if ! _dev_container_running "$_devcpout_name"; then
    echo "Error: container '${_devcpout_name}' is not running" >&2
    exit 1
fi

_dev_update_ssh_config "$_devcpout_name"

for _devcpout_path in "$@"; do
    # Prefix with /workspace if not absolute
    if [[ "$_devcpout_path" != /* ]]; then
        _devcpout_path="/workspace/${_devcpout_path}"
    fi
    scp -q -r "${_devcpout_name}:${_devcpout_path}" .
done

echo "Copied $# item(s) to $(pwd)/"
