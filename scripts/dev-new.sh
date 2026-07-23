#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

readonly _devnew_name="${1:?'Usage: dev-new.sh <name> [org/repo]'}"

_dev_create_container "$_devnew_name" "${2:-}"

echo "Entering container '${_devnew_name}'..."
exec podman start -ai "$_devnew_name"
