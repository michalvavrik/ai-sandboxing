#!/bin/bash
# Acceptance test for the in-container auto-backup loop — the ONE part that can
# only be verified under krun, with a running container. Run it after a
# container is up (and after the passt downgrade that unblocks starts):
#
#   bash tests/acceptance-auto-backup.sh <container-name>
#
# It proves the krun-launch fix: the loop process is actually alive, and a
# workspace change is snapshotted (status advances) within one interval. Run it
# against the OLD image first to see it fail (no loop process), then the fixed
# image to see it pass.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../scripts/dev-common.sh"

_name="${1:?usage: acceptance-auto-backup.sh <container-name>}"
_fail=0
_status() { _dev_ssh_cmd "$_name" "sed -n 's/^$1=//p' /mnt/bounded/backup/status 2>/dev/null | tail -1"; }

echo "== auto-backup acceptance: ${_name} =="

if _dev_ssh_cmd "$_name" 'pgrep -f dev-auto-backup.sh >/dev/null'; then
    echo "  ok   loop process is running"
else
    echo "  FAIL loop process is NOT running (krun launch still broken)" >&2; _fail=1
fi

_before_run=$(_status last_run)
_before_push=$(_status last_push)
_marker="/workspace/.auto-backup-acceptance.$$"
_dev_ssh_cmd "$_name" "date > '${_marker}'"
echo "  ..   made a change; waiting ~35s for the next snapshot"
sleep 35
_after_run=$(_status last_run)
_after_push=$(_status last_push)
_dev_ssh_cmd "$_name" "rm -f '${_marker}'" 2>/dev/null || true

if [[ -n "$_after_run" && "$_after_run" != "$_before_run" ]]; then
    echo "  ok   last_run advanced (${_before_run:-none} -> ${_after_run}) — loop is alive"
else
    echo "  FAIL last_run did not advance (${_before_run:-none} -> ${_after_run:-none})" >&2; _fail=1
fi

if [[ -n "$_after_push" && "$_after_push" != "$_before_push" ]]; then
    echo "  ok   last_push advanced (${_before_push:-none} -> ${_after_push}) — off-machine push works"
else
    echo "  note last_push did not advance (${_before_push:-none} -> ${_after_push:-none}); check the push path / log" >&2
fi

if [[ "$_fail" -eq 0 ]]; then echo "ACCEPTANCE PASSED"; else echo "ACCEPTANCE FAILED" >&2; exit 1; fi
