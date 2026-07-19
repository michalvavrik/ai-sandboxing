#!/bin/bash
set -euo pipefail

readonly _DEV_LABEL="dev-sandbox"

podman ps -a --filter="label=${_DEV_LABEL}" --format "table {{.Names}}\t{{.Status}}\t{{.Labels}}"
