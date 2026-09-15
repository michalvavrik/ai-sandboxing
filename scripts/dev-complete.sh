#!/bin/bash
source "$(dirname "$(readlink -f "$0")")/dev-common.sh" 2>/dev/null || exit 0
set +euo pipefail

_comp_cword="$1"
_comp_prev="$2"
_comp_cur="$3"
shift 3 2>/dev/null || true
_comp_all_words=("$@")

if [[ $_comp_cword -eq 1 ]]; then
    compgen -W "new enter recreate delete start see show push merge rebase cp cpout use list pull sync continue install review ." -- "$_comp_cur"
elif [[ $_comp_cword -eq 2 && "$_comp_prev" =~ ^(enter|recreate|start|see|show|push|merge|rebase|use)$ ]]; then
    _comp_words="$(podman ps -a --filter=label=${DEV_LABEL} --format '{{.Names}}' 2>/dev/null)"
    [[ "$_comp_prev" == "see" ]] && _comp_words="--dont-squash $_comp_words"
    compgen -W "$_comp_words" -- "$_comp_cur"
elif [[ $_comp_cword -eq 2 && "$_comp_prev" == "delete" ]]; then
    _comp_words="--dont-merge $(podman ps -a --filter=label=${DEV_LABEL} --format '{{.Names}}' 2>/dev/null)"
    compgen -W "$_comp_words" -- "$_comp_cur"
elif [[ $_comp_cword -eq 2 && "$_comp_prev" == "continue" ]]; then
    _comp_src_dir=""
    _comp_tkey=$(_dev_detect_template_from_cwd 2>/dev/null) || true
    if [[ -n "$_comp_tkey" ]]; then
        _comp_src_dir=$(_dev_resolve_src_dir "$_comp_tkey" 2>/dev/null) || true
    fi
    if [[ -n "$_comp_src_dir" ]]; then
        _comp_repo="${_comp_tkey#*/}"
        _comp_features=""
        # in-review/* and wip/* feature names
        while read -r _comp_b; do
            [[ -z "$_comp_b" ]] && continue
            _comp_b="${_comp_b#\* }"
            _comp_b="${_comp_b## }"
            _comp_features="${_comp_features} ${_comp_b#in-review/}"
        done < <(git -C "$_comp_src_dir" branch --list 'in-review/*' 2>/dev/null)
        while read -r _comp_b; do
            [[ -z "$_comp_b" ]] && continue
            _comp_b="${_comp_b#\* }"
            _comp_b="${_comp_b## }"
            _comp_f="${_comp_b#wip/}"
            echo "$_comp_features" | grep -qwF "$_comp_f" || _comp_features="${_comp_features} ${_comp_f}"
        done < <(git -C "$_comp_src_dir" branch --list 'wip/*' 2>/dev/null)
        # dev-auto/* as fallback
        _comp_seen_da=""
        while read -r _comp_b; do
            [[ -z "$_comp_b" ]] && continue
            _comp_b="${_comp_b#\* }"
            _comp_b="${_comp_b## }"
            [[ "$_comp_b" =~ ^dev-auto/([^/]+) ]] || continue
            _comp_cname="${BASH_REMATCH[1]}"
            echo "$_comp_seen_da" | grep -qxF "$_comp_cname" && continue
            _comp_seen_da="${_comp_seen_da}
${_comp_cname}"
            _comp_f=$(_dev_container_name_to_feature "$_comp_cname" "$_comp_repo")
            echo "$_comp_features" | grep -qwF "$_comp_f" || _comp_features="${_comp_features} ${_comp_f}"
        done < <(git -C "$_comp_src_dir" branch --list 'dev-auto/*' 2>/dev/null)
        compgen -W "$_comp_features" -- "$_comp_cur"
    fi
elif [[ "$_comp_prev" == "--model" ]]; then
    compgen -W "flash pro opus claude" -- "$_comp_cur"
elif [[ "$_comp_prev" == "--agent" ]]; then
    compgen -W "claude bob agy" -- "$_comp_cur"
elif [[ "$_comp_prev" == "=" ]]; then
    _comp_prev2=""
    if [[ ${#_comp_all_words[@]} -ge 3 && $_comp_cword -ge 2 ]]; then
        _comp_prev2="${_comp_all_words[_comp_cword-2]:-}"
    fi
    case "$_comp_prev2" in
        *model*) compgen -W "flash pro opus claude" -- "$_comp_cur" ;;
        *agent*) compgen -W "claude bob agy" -- "$_comp_cur" ;;
        *)       compgen -W "flash pro opus claude bob agy" -- "$_comp_cur" ;;
    esac
elif [[ "$_comp_prev" == "review" || "${_comp_all_words[1]:-}" == "review" || "$_comp_prev" =~ ^(--agent=.*|--model=.*|--prompt|--append-to-prompt)$ ]]; then
    _comp_words="--agent=claude --agent=bob --agent=agy --model=flash --model=pro --model=opus --prompt --append-to-prompt $(podman ps -a --filter=label=${DEV_LABEL} --format '{{.Names}}' 2>/dev/null)"
    compgen -W "$_comp_words" -- "$_comp_cur"
elif [[ "$_comp_prev" =~ ^(--dont-squash|--dont-merge)$ ]]; then
    compgen -W "$(podman ps -a --filter=label=${DEV_LABEL} --format '{{.Names}}' 2>/dev/null)" -- "$_comp_cur"
elif [[ "$_comp_prev" == "cpout" ]]; then
    _comp_name=$(_dev_resolve_name "" 2>/dev/null) || exit 0
    _dev_update_ssh_config "$_comp_name" 2>/dev/null || exit 0
    _comp_prefix="/workspace/"
    [[ "$_comp_cur" == /* ]] && _comp_prefix=""
    ssh -q "$_comp_name" "ls -dp ${_comp_prefix}${_comp_cur}* 2>/dev/null" | sed "s|^${_comp_prefix}||"
fi
