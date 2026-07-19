#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _deventer_name="${1:?'Usage: dev-enter.sh <name>'}"

if ! _dev_container_exists "$_deventer_name"; then
    echo "Error: container '${_deventer_name}' does not exist" >&2
    echo "Use 'dev new ${_deventer_name}' to create it, or 'dev list' to see available containers." >&2
    exit 1
fi

_dev_ensure_proxy

if _dev_container_running "$_deventer_name"; then
    _dev_ssh_cmd "$_deventer_name"
else
    echo "Starting container '${_deventer_name}'..."
    exec podman start -ai "$_deventer_name"
fi
