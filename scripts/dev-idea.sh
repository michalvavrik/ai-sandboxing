#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devidea_name=$(_dev_resolve_name "${1:-}")

if ! _dev_container_running "$_devidea_name"; then
    echo "Error: container '${_devidea_name}' is not running" >&2
    exit 1
fi

if ! xdg-mime query default x-scheme-handler/jetbrains-gateway &>/dev/null; then
    echo "Error: JetBrains Gateway URL handler not registered. Install Gateway via JetBrains Toolbox." >&2
    exit 1
fi

readonly _devidea_port=$(_dev_ssh_port "$_devidea_name")
readonly _devidea_url="jetbrains-gateway://connect#host=dev-sandbox&port=${_devidea_port}&user=dev&type=ssh&deploy=false&projectPath=%2Fworkspace"

xdg-open "$_devidea_url"
echo "Opening Gateway → localhost:${_devidea_port} → /workspace"
