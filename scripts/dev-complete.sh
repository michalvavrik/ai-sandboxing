#!/bin/bash
source "$(dirname "$(readlink -f "$0")")/dev-common.sh" 2>/dev/null || exit 0
set +euo pipefail

_comp_cword="$1"
_comp_prev="$2"
_comp_cur="$3"

if [[ $_comp_cword -eq 1 ]]; then
    compgen -W "new enter delete stop start see cp cpout use gemini idea list pull install" -- "$_comp_cur"
elif [[ $_comp_cword -eq 2 && "$_comp_prev" =~ ^(enter|delete|stop|start|see|use|gemini)$ ]]; then
    compgen -W "$(podman ps -a --filter=label=${DEV_LABEL} --format '{{.Names}}' 2>/dev/null)" -- "$_comp_cur"
elif [[ "$_comp_prev" == "cpout" ]]; then
    _comp_name=$(_dev_resolve_name "" 2>/dev/null) || exit 0
    _dev_update_ssh_config "$_comp_name" 2>/dev/null || exit 0
    _comp_prefix="/workspace/"
    [[ "$_comp_cur" == /* ]] && _comp_prefix=""
    ssh -q "$_comp_name" "ls -dp ${_comp_prefix}${_comp_cur}* 2>/dev/null" | sed "s|^${_comp_prefix}||"
fi
