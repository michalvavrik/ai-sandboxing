#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

# BACKUP = age of the in-container auto-backup loop's last run (loop liveness):
# "STALE"/"never" on a running container means the backup loop is not working,
# "?" that it could not be read; "-" when stopped, and for study containers
# (they have no auto-backup). One `podman ps` provides the rest, SSH port
# included; the running containers are then read over SSH in parallel, so the
# list takes as long as the slowest of them.
_dev_tmp=$(mktemp -d)
trap 'rm -rf "$_dev_tmp"' EXIT
# Background jobs of a script ignore Ctrl-C: take them down with the script
# instead of leaving an ssh waiting on a stuck container.
trap 'trap - INT TERM; rm -rf "$_dev_tmp"; kill 0' INT TERM

_dev_names=() _dev_statuses=()
while IFS='|' read -r _dev_name _dev_state _dev_status _dev_profiles _dev_ports; do
    [[ -z "$_dev_name" ]] && continue
    _dev_names+=("$_dev_name")
    _dev_statuses+=("$_dev_status")
    if [[ "$_dev_state" == "running" ]] && ! _dev_has_profile "$_dev_profiles" "study"; then
        _dev_port=""
        [[ "$_dev_ports" =~ :([0-9]+)-\>2222/tcp ]] && _dev_port="${BASH_REMATCH[1]}"
        _dev_backup_age "$_dev_name" "$_dev_port" > "${_dev_tmp}/${_dev_name}" &
    fi
done < <(podman ps -a --filter="label=${DEV_LABEL}" --format '{{.Names}}|{{.State}}|{{.Status}}|{{index .Labels "dev-profiles"}}|{{.Ports}}')
wait

{
    printf 'NAME\tSTATUS\tBACKUP\n'
    for _dev_i in "${!_dev_names[@]}"; do
        _dev_name="${_dev_names[$_dev_i]}"
        _dev_backup='-'
        if [[ -e "${_dev_tmp}/${_dev_name}" ]]; then
            _dev_backup=$(<"${_dev_tmp}/${_dev_name}")
            _dev_backup="${_dev_backup:-?}"
        fi
        printf '%s\t%s\t%s\n' "$_dev_name" "${_dev_statuses[$_dev_i]}" "$_dev_backup"
    done
} | column -t -s $'\t'
