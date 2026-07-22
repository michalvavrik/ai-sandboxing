#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devidea_name=$(_dev_resolve_name "${1:-}")

if ! _dev_container_running "$_devidea_name"; then
    echo "Error: container '${_devidea_name}' is not running" >&2
    exit 1
fi

readonly _devidea_port=$(_dev_ssh_port "$_devidea_name")
readonly _devidea_gateway="${HOME}/.local/share/JetBrains/Toolbox/scripts/gateway"

if [[ ! -x "$_devidea_gateway" ]]; then
    echo "Error: JetBrains Gateway not found. Install it via JetBrains Toolbox." >&2
    exit 1
fi

"$_devidea_gateway" "jetbrains-gateway://connect#host=dev-sandbox&port=${_devidea_port}&user=dev&type=ssh&deploy=false&projectPath=%2Fworkspace" &>/dev/null &
disown
echo "Gateway opening → dev-sandbox:${_devidea_port} → /workspace"
echo "If connection fails, enable 'Parse SSH config' in Gateway SSH settings."
