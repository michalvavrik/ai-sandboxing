#!/bin/bash
# Runs every tests/*.test.sh in its own process; exits non-zero if any fail.
# Usage: bash tests/run.sh
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

_fails=0
shopt -s nullglob
for _t in tests/*.test.sh; do
    printf '== %s ==\n' "$_t"
    if ! bash "$_t"; then _fails=$((_fails + 1)); fi
done

if [[ "$_fails" -eq 0 ]]; then
    echo "ALL TEST FILES PASSED"
else
    echo "${_fails} TEST FILE(S) FAILED" >&2
fi
[[ "$_fails" -eq 0 ]]
