#!/bin/bash
set -euo pipefail
source /home/mvavrik/sandboxing/scripts/dev-common.sh

readonly _devstart_name="${1:?'Usage: dev-start.sh <name>'}"

# Ensure proxy is running before starting the container
_dev_ensure_proxy

podman start "$_devstart_name"
echo "Container '${_devstart_name}' started."
