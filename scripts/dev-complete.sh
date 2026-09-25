#!/bin/bash
# Tab-completion backend for `dev` (called by _dev_completion in dev-shell-init.sh).
#
#   dev-complete.sh <cursor-word-index> <word0> <word1> ...
#
# Words are already re-joined at '=' and ':'. Prints one candidate per line.
# Lines starting with '%' are directives for the shell function:
#   %files    complete local file names      %dirs     complete local directories
#   %nospace  don't append a space           %nosort   keep candidate order
_DEV_NO_REMEMBER=1
source "$(dirname "$(readlink -f "$0")")/dev-common.sh" 2>/dev/null || exit 0
set +euo pipefail

_comp_cword="${1:-0}"
shift 2>/dev/null || true
_comp_words=("$@")
_comp_cur="${_comp_words[_comp_cword]:-}"
_comp_prev=""
(( _comp_cword >= 1 )) && _comp_prev="${_comp_words[_comp_cword-1]}"

_COMP_COMMANDS="new enter recreate delete start see show push merge rebase cp cpout use list pull sync continue install review ."
_COMP_AGENTS="claude bob agy"
_COMP_MODELS="opus fable flash pro"
_COMP_LOOPS="normal best all bob flash pro opus fable"
_COMP_AUTH="api-key vertex"
_COMP_REVIEW_OPTS="--loop= --agent= --model= --prompt --append-to-prompt --auth-method="

_comp_emit() { local _w; for _w in "$@"; do printf '%s\n' "$_w"; done; }
_comp_values() { local _p="$1" _w; shift; for _w in "$@"; do printf '%s%s\n' "$_p" "$_w"; done; }
_comp_containers() { podman ps -a --filter="label=${DEV_LABEL}" --format '{{.Names}}' 2>/dev/null; }

# Remote path listing inside the current container (dev cpout, dev cp --to).
_comp_remote_paths() {
    local _name _prefix="/workspace/"
    _name=$(_dev_resolve_name "" 2>/dev/null) || return 0
    _dev_container_running "$_name" || return 0
    _dev_update_ssh_config "$_name" 2>/dev/null || return 0
    [[ "$_comp_cur" == /* ]] && _prefix=""
    echo '%nospace'
    ssh -q -o ConnectTimeout=2 -o BatchMode=yes "$_name" \
        "ls -dp ${_prefix}${_comp_cur}* 2>/dev/null" </dev/null | sed "s|^${_prefix}||"
}

# ── Option values ─────────────────────────────────────────────────────────────
case "$_comp_cur" in
    --auth-method=*) _comp_values "--auth-method=" $_COMP_AUTH; exit 0 ;;
    --agent=*)       _comp_values "--agent=" $_COMP_AGENTS; exit 0 ;;
    --model=*)       _comp_values "--model=" $_COMP_MODELS; exit 0 ;;
    --loop=*)
        # Comma-separated list: complete the last entry, keep what was typed.
        _comp_list="${_comp_cur#--loop=}"
        _comp_pfx="--loop="
        [[ "$_comp_list" == *,* ]] && _comp_pfx="--loop=${_comp_list%,*},"
        _comp_values "$_comp_pfx" $_COMP_LOOPS
        exit 0
        ;;
esac
case "$_comp_prev" in
    --agent) _comp_emit $_COMP_AGENTS; exit 0 ;;
    --model) _comp_emit $_COMP_MODELS; exit 0 ;;
    --prompt|--append-to-prompt) exit 0 ;;
esac

# ── Locate the subcommand (first non-option word before the cursor) ───────────
_comp_cmd=""
_comp_cmd_idx=0
for (( _comp_i = 1; _comp_i < _comp_cword; _comp_i++ )); do
    if [[ "${_comp_words[_comp_i]}" != -* ]]; then
        _comp_cmd="${_comp_words[_comp_i]}"
        _comp_cmd_idx=$_comp_i
        break
    fi
done

if [[ -z "$_comp_cmd" ]]; then
    if [[ "$_comp_cur" == -* ]]; then
        _comp_emit "--auth-method="
    else
        _comp_emit $_COMP_COMMANDS
    fi
    exit 0
fi

# ── Per-command candidates ────────────────────────────────────────────────────
_comp_is_opt=false
[[ "$_comp_cur" == -* ]] && _comp_is_opt=true

case "$_comp_cmd" in
    new)
        $_comp_is_opt && _comp_emit "--auth-method="
        ;;
    enter|start|merge|rebase|use|show)
        $_comp_is_opt || _comp_containers
        ;;
    recreate)
        if $_comp_is_opt; then _comp_emit "--auth-method="; else _comp_containers; fi
        ;;
    see)
        if $_comp_is_opt; then _comp_emit "--dont-squash"; else _comp_containers; fi
        ;;
    delete)
        if $_comp_is_opt; then _comp_emit "--dont-merge"; else _comp_containers; fi
        ;;
    push)
        if $_comp_is_opt; then _comp_emit "--local"; else _comp_containers; fi
        ;;
    continue)
        (( _comp_cword == _comp_cmd_idx + 1 )) || exit 0
        _comp_tkey=$(_dev_detect_template_from_cwd 2>/dev/null) || exit 0
        _comp_src_dir=$(_dev_resolve_src_dir "$_comp_tkey" 2>/dev/null) || exit 0
        _comp_repo="${_comp_tkey#*/}"
        echo '%nosort'
        _comp_seen=""
        _comp_add() {
            printf '%s\n' "$_comp_seen" | grep -qxF "$1" && return 0
            _comp_seen="${_comp_seen}
$1"
            printf '%s\n' "$1"
        }
        while read -r _comp_b; do
            _comp_b="${_comp_b#\* }"; _comp_b="${_comp_b## }"
            [[ -z "$_comp_b" ]] && continue
            _comp_add "${_comp_b#in-review/}"
        done < <(git -C "$_comp_src_dir" branch --list 'in-review/*' 2>/dev/null)
        while read -r _comp_b; do
            _comp_b="${_comp_b#\* }"; _comp_b="${_comp_b## }"
            [[ -z "$_comp_b" ]] && continue
            _comp_add "${_comp_b#wip/}"
        done < <(git -C "$_comp_src_dir" branch --list 'wip/*' 2>/dev/null)
        while read -r _comp_b; do
            _comp_b="${_comp_b#\* }"; _comp_b="${_comp_b## }"
            [[ "$_comp_b" =~ ^dev-auto/([^/]+) ]] || continue
            _comp_add "$(_dev_container_name_to_feature "${BASH_REMATCH[1]}" "$_comp_repo")"
        done < <(git -C "$_comp_src_dir" branch --list 'dev-auto/*' 2>/dev/null)
        ;;
    review)
        if $_comp_is_opt; then _comp_emit $_COMP_REVIEW_OPTS; else _comp_containers; fi
        ;;
    http://*|https://*)
        $_comp_is_opt && _comp_emit $_COMP_REVIEW_OPTS
        ;;
    .)
        $_comp_is_opt && _comp_emit "--auth-method="
        ;;
    cp)
        if [[ "$_comp_prev" == "--to" ]]; then _comp_remote_paths
        elif $_comp_is_opt; then _comp_emit "--to"
        else echo '%files'
        fi
        ;;
    cpout)
        if [[ "$_comp_prev" == "--to" ]]; then echo '%dirs'
        elif $_comp_is_opt; then _comp_emit "--to"
        else _comp_remote_paths
        fi
        ;;
esac
exit 0
