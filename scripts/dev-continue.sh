#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devcont_input="${1:-}"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository" >&2
    exit 1
fi

_devcont_template_key=$(_dev_detect_template_from_cwd) || true
if [[ -z "$_devcont_template_key" ]]; then
    echo "Error: no project template matches the current directory" >&2
    exit 1
fi

_devcont_repo="${_devcont_template_key#*/}"
_devcont_src_dir=$(_dev_resolve_src_dir "$_devcont_template_key") || true
if [[ -z "$_devcont_src_dir" ]]; then
    _devcont_src_dir="$(pwd -P)"
fi

# ── Collect available features ────────────────────────────────────────────────
declare -A _devcont_branches
declare -A _devcont_labels

while read -r _devcont_b; do
    [[ -z "$_devcont_b" ]] && continue
    _devcont_b="${_devcont_b#\* }"
    _devcont_b="${_devcont_b## }"
    _devcont_f="${_devcont_b#in-review/}"
    _devcont_branches["$_devcont_f"]="$_devcont_b"

    _devcont_meta=$(_dev_get_branch_meta "$_devcont_repo" "$_devcont_f" 2>/dev/null) || true
    if [[ -n "$_devcont_meta" ]]; then
        _devcont_num=$(echo "$_devcont_meta" | jq -r '.number')
        _devcont_title=$(echo "$_devcont_meta" | jq -r '.title')
        _devcont_labels["$_devcont_f"]="(GitHub PR #${_devcont_num}) ${_devcont_title}"
    else
        _devcont_labels["$_devcont_f"]="PR details loading"
        _devcont_needs_sync=true
    fi
done < <(git -C "$_devcont_src_dir" branch --list 'in-review/*' 2>/dev/null)

if [[ "${_devcont_needs_sync:-}" == true ]]; then
    "${DEV_SCRIPTS_DIR}/dev-sync.sh" &>/dev/null &
    disown
fi

while read -r _devcont_b; do
    [[ -z "$_devcont_b" ]] && continue
    _devcont_b="${_devcont_b#\* }"
    _devcont_b="${_devcont_b## }"
    _devcont_f="${_devcont_b#wip/}"
    if [[ -z "${_devcont_branches[$_devcont_f]+x}" ]]; then
        _devcont_branches["$_devcont_f"]="$_devcont_b"
        _devcont_labels["$_devcont_f"]="WIP"
    fi
done < <(git -C "$_devcont_src_dir" branch --list 'wip/*' 2>/dev/null)

_devcont_seen_da=""
while read -r _devcont_b; do
    [[ -z "$_devcont_b" ]] && continue
    _devcont_b="${_devcont_b#\* }"
    _devcont_b="${_devcont_b## }"
    [[ "$_devcont_b" =~ ^dev-auto/([^/]+) ]] || continue
    _devcont_cname="${BASH_REMATCH[1]}"
    echo "$_devcont_seen_da" | grep -qxF "$_devcont_cname" && continue
    _devcont_seen_da="${_devcont_seen_da}
${_devcont_cname}"
    _devcont_f=$(_dev_container_name_to_feature "$_devcont_cname" "$_devcont_repo")
    if [[ -z "${_devcont_branches[$_devcont_f]+x}" ]]; then
        _devcont_branches["$_devcont_f"]="$_devcont_b"
        _devcont_labels["$_devcont_f"]="dev-auto"
    fi
done < <(git -C "$_devcont_src_dir" branch --list 'dev-auto/*' 2>/dev/null)

if [[ ${#_devcont_branches[@]} -eq 0 ]]; then
    echo "No continuable branches found (wip/*, in-review/*, or dev-auto/*)."
    exit 0
fi

# ── Match input ───────────────────────────────────────────────────────────────
if [[ -z "$_devcont_input" ]]; then
    if [[ ${#_devcont_branches[@]} -eq 1 ]]; then
        _devcont_input="${!_devcont_branches[@]}"
    else
        echo "Available branches:"
        for _devcont_f in $(echo "${!_devcont_branches[@]}" | tr ' ' '\n' | sort); do
            printf "  %-40s %s\n" "$_devcont_f" "${_devcont_labels[$_devcont_f]}"
        done
        exit 0
    fi
fi

_devcont_matches=()
for _devcont_f in "${!_devcont_branches[@]}"; do
    if [[ "$_devcont_f" == "$_devcont_input"* ]]; then
        _devcont_matches+=("$_devcont_f")
    fi
done

if [[ ${#_devcont_matches[@]} -eq 0 ]]; then
    echo "Error: no branch matching '${_devcont_input}'" >&2
    exit 1
elif [[ ${#_devcont_matches[@]} -gt 1 ]]; then
    echo "Multiple matches for '${_devcont_input}':"
    for _devcont_f in $(printf '%s\n' "${_devcont_matches[@]}" | sort); do
        printf "  %-40s %s\n" "$_devcont_f" "${_devcont_labels[$_devcont_f]}"
    done
    exit 1
fi

_devcont_feature="${_devcont_matches[0]}"
_devcont_target="${_devcont_branches[$_devcont_feature]}"

echo "Checking out ${_devcont_target}..."
git -C "$_devcont_src_dir" checkout "$_devcont_target"
