#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devidea_name=$(_dev_resolve_name "${1:-}")

if ! _dev_container_running "$_devidea_name"; then
    echo "Error: container '${_devidea_name}' is not running" >&2
    exit 1
fi

readonly _devidea_port=$(_dev_ssh_port "$_devidea_name")

readonly _devidea_url="jetbrains-gateway://connect#idePath=%2Fopt%2Fidea&host=localhost&port=${_devidea_port}&user=dev&type=ssh&deploy=false&projectPath=%2Fworkspace"

# Try IntelliJ directly, fall back to xdg-open
if command -v intellij-idea-ultimate &>/dev/null; then
    intellij-idea-ultimate "$_devidea_url" &>/dev/null &
    disown
elif command -v idea &>/dev/null; then
    idea "$_devidea_url" &>/dev/null &
    disown
else
    xdg-open "$_devidea_url"
fi
echo "Opening IntelliJ Gateway → localhost:${_devidea_port} → /workspace"
