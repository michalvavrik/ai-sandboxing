#!/bin/bash
# Shell integration for the dev sandbox CLI. `dev install` adds one line to
# ~/.bashrc:
#
#   source ~/sandboxing/scripts/dev-shell-init.sh
#
# Everything else (the `dev` command and its tab completion) lives here, so
# updating this repo updates the shell integration too.
#
# `dev` is a function that sources dev.sh, so dev.sh can update
# DEV_LAST_CONTAINER (the remembered current container) in the calling shell.

_DEV_SHELL_INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dev() {
    # shellcheck disable=SC1091
    source "${_DEV_SHELL_INIT_DIR}/dev.sh" "$@"
}

# Bash splits the command line at the characters in COMP_WORDBREAKS, which by
# default include '=' and ':'. That turns "--agent=cl" into the three words
# "--agent", "=", "cl" and a GitHub URL into "https", ":", "//github.com/...".
# Re-join them so dev-complete.sh sees logical words, then strip the part bash
# keeps ("--agent=") from the candidates before handing them back.
_dev_completion() {
    local IFS=$' \t\n'
    local raw_cur="${COMP_WORDS[COMP_CWORD]}"
    local words=() cword=-1 i w
    for ((i = 0; i < ${#COMP_WORDS[@]}; i++)); do
        w="${COMP_WORDS[i]}"
        if (( i > 0 )) && [[ "$w" == [=:]* || "${words[${#words[@]}-1]}" == *[=:] ]]; then
            words[${#words[@]}-1]+="$w"
        else
            words+=("$w")
        fi
        (( i == COMP_CWORD )) && cword=$(( ${#words[@]} - 1 ))
    done
    (( cword < 0 )) && return 0
    local cur="${words[cword]}"

    local line mode="" cands=()
    while IFS= read -r line; do
        case "$line" in
            '%files'|'%dirs') mode="${line#%}" ;;
            '%nospace') compopt -o nospace 2>/dev/null ;;
            '%nosort')  compopt -o nosort 2>/dev/null ;;
            '') ;;
            *) cands+=("$line") ;;
        esac
    done < <(DEV_LAST_CONTAINER="${DEV_LAST_CONTAINER:-}" \
             "${_DEV_SHELL_INIT_DIR}/dev-complete.sh" "$cword" "${words[@]}" 2>/dev/null)

    case "$mode" in
        files)
            compopt -o filenames 2>/dev/null
            mapfile -t COMPREPLY < <(compgen -f -- "$cur")
            return 0
            ;;
        dirs)
            compopt -o filenames 2>/dev/null
            mapfile -t COMPREPLY < <(compgen -d -- "$cur")
            return 0
            ;;
    esac

    mapfile -t COMPREPLY < <(compgen -W "${cands[*]}" -- "$cur")

    if [[ "$raw_cur" != "$cur" ]]; then
        local prefix="${cur%"$raw_cur"}"
        COMPREPLY=("${COMPREPLY[@]#"$prefix"}")
    fi
    if (( ${#COMPREPLY[@]} == 1 )) && [[ "${COMPREPLY[0]}" == *[=,] ]]; then
        compopt -o nospace 2>/dev/null
    fi
}

complete -F _dev_completion dev
