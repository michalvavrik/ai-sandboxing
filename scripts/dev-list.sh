#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

# BACKUP = age of the in-container auto-backup loop's last run (loop liveness):
# "STALE"/"never" on a running container means the backup loop is not working.
# Read over SSH for running containers only (kept light); "-" when stopped.
{
    printf 'NAME\tSTATUS\tBACKUP\n'
    while IFS='|' read -r _dev_name _dev_state _dev_status; do
        [[ -z "$_dev_name" ]] && continue
        _dev_backup='-'
        if [[ "$_dev_state" == "running" ]]; then
            _dev_backup=$(_dev_backup_age "$_dev_name" 2>/dev/null) || _dev_backup='?'
        fi
        printf '%s\t%s\t%s\n' "$_dev_name" "$_dev_status" "$_dev_backup"
    done < <(podman ps -a --filter="label=${DEV_LABEL}" --format '{{.Names}}|{{.State}}|{{.Status}}')
} | column -t -s $'\t'
