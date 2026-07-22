#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devidea_name="${1:-${DEV_LAST_CONTAINER:?'No container selected. Run dev use <name> first.'}}"

if ! _dev_container_running "$_devidea_name"; then
    echo "Error: container '${_devidea_name}' is not running" >&2
    exit 1
fi

readonly _devidea_port=$(_dev_ssh_port "$_devidea_name")

xdg-open "jetbrains-gateway://connect#idePath=%2Fopt%2Fidea&host=localhost&port=${_devidea_port}&user=dev&type=ssh&deploy=false&projectPath=%2Fworkspace"
