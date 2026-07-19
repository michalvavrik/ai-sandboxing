#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devstop_name="${1:?'Usage: dev-stop.sh <name>'}"

podman stop "$_devstop_name"
echo "Container '${_devstop_name}' stopped."

_dev_maybe_stop_proxy
