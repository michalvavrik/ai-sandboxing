#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devcp_dest="/tmp/workspace"
_devcp_paths=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) _devcp_dest="$2"; shift 2 ;;
        *) _devcp_paths+=("$1"); shift ;;
    esac
done

if [[ ${#_devcp_paths[@]} -eq 0 ]]; then
    echo "Usage: dev cp [--to <container-dir>] <path>..." >&2
    exit 1
fi

readonly _devcp_name=$(_dev_resolve_name "")

_dev_ensure_running "$_devcp_name"
_dev_ssh_cmd "$_devcp_name" "mkdir -p '${_devcp_dest}'"

scp -q -r "${_devcp_paths[@]}" "${_devcp_name}:${_devcp_dest}/"

_dev_stop_if_was_stopped "$_devcp_name"
echo "Copied ${#_devcp_paths[@]} item(s) to ${_devcp_dest}/"
