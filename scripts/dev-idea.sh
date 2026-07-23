#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

readonly _devidea_name=$(_dev_resolve_name "${1:-}")

if ! _dev_container_running "$_devidea_name"; then
    echo "Error: container '${_devidea_name}' is not running" >&2
    exit 1
fi

_dev_update_ssh_config "$_devidea_name"

readonly _devidea_port=$(_dev_ssh_port "$_devidea_name")
readonly _devidea_gateway="${HOME}/.local/share/JetBrains/Toolbox/scripts/gateway"

if [[ ! -x "$_devidea_gateway" ]]; then
    echo "Error: JetBrains Gateway not found. Install it via JetBrains Toolbox." >&2
    exit 1
fi

echo "In Gateway: SSH → Host: ${_devidea_name}, User: dev, Password: (leave empty) → Project: /workspace"

"$_devidea_gateway" &>/dev/null &
disown
