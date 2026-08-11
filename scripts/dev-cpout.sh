#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devcpout_dest="."
_devcpout_paths=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) _devcpout_dest="$2"; shift 2 ;;
        *) _devcpout_paths+=("$1"); shift ;;
    esac
done

if [[ ${#_devcpout_paths[@]} -eq 0 ]]; then
    echo "Usage: dev cpout [--to <local-dir>] <remote-path>..." >&2
    echo "Paths are relative to /workspace (e.g., dev cpout pom.xml src/main)" >&2
    exit 1
fi

readonly _devcpout_name=$(_dev_resolve_name "")

_dev_ensure_running "$_devcpout_name"
mkdir -p "$_devcpout_dest"

for _devcpout_path in "${_devcpout_paths[@]}"; do
    if [[ "$_devcpout_path" != /* ]]; then
        _devcpout_path="/workspace/${_devcpout_path}"
    fi
    scp -q -r "${_devcpout_name}:${_devcpout_path}" "$_devcpout_dest"
done

_dev_stop_if_was_stopped "$_devcpout_name"
echo "Copied ${#_devcpout_paths[@]} item(s) to ${_devcpout_dest}/"
