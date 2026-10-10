#!/bin/bash
# Rewrite commits so that no commit message references a GitHub issue or pull
# request. GitHub links every pushed commit whose message mentions an issue
# (#123, GH-123, owner/repo#123, https://github.com/owner/repo/issues/123) to
# that issue, so a commit like "closes: https://github.com/org/repo/issues/123"
# pushed to the automation fork would show up in the issue's timeline under the
# automation account. Every commit that leaves the host for the automation fork
# (dev show, dev .) and every commit that enters a container from GitHub
# (dev <pr-url>, dev <tree-url>) goes through this script first.
#
# Usage: dev-git-sanitize.sh [-C <repo>] <head> [<commit>...]
#
# The listed commits (any order) are rewritten with the same tree, author,
# committer and dates; parents are remapped to their rewritten versions, parents
# outside the list are kept. Commits whose message needs no change (and whose
# parents did not change) keep their id, so running this twice is a no-op. GPG
# signatures are dropped from rewritten commits. Prints the new id of <head>
# (which is <head> itself when nothing changed). No ref is moved.
#
# Message rewriting (readable, but not a GitHub reference any more):
#   https://github.com/org/repo/issues/123  ->  github.com/org/repo/issues/123
#   org/repo#123                            ->  org/repo issue 123
#   #123                                    ->  issue 123
#   GH-123                                  ->  GH 123
set -euo pipefail

if [[ "${1:-}" == "-C" ]]; then
    cd "${2:?-C needs a directory}"
    shift 2
fi
_san_head="${1:?usage: dev-git-sanitize.sh [-C <repo>] <head> [<commit>...]}"
shift

_san_head=$(git rev-parse --verify "${_san_head}^{commit}")

_san_sanitize_message() {
    sed -E \
        -e 's#https?://(www\.)?github\.com/#github.com/#g' \
        -e 's#([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\#([0-9]+)#\1 issue \2#g' \
        -e 's/(^|[^A-Za-z0-9&])#([0-9]+)/\1issue \2/g' \
        -e 's/(^|[^A-Za-z0-9])GH-([0-9]+)/\1GH \2/g'
}

if (( $# == 0 )); then
    echo "$_san_head"
    exit 0
fi

# Full ids of the commits to rewrite, as a set.
declare -A _san_set=()
for _san_c in "$@"; do
    _san_c=$(git rev-parse --verify "${_san_c}^{commit}")
    _san_set["$_san_c"]=1
done

# Parents of every listed commit (one git call), then a topological order so
# that a parent is rewritten before its children.
declare -A _san_parents=()
while read -r _san_c _san_ps; do
    [[ -n "$_san_c" ]] || continue
    _san_parents["$_san_c"]="$_san_ps"
done < <(git rev-list --no-walk=unsorted --parents "${!_san_set[@]}")

_san_order=()
declare -A _san_done=()
_san_remaining=${#_san_set[@]}
while (( _san_remaining > 0 )); do
    _san_progress=false
    for _san_c in "${!_san_set[@]}"; do
        [[ -n "${_san_done[$_san_c]:-}" ]] && continue
        _san_ready=true
        for _san_p in ${_san_parents[$_san_c]:-}; do
            if [[ -n "${_san_set[$_san_p]:-}" && -z "${_san_done[$_san_p]:-}" ]]; then
                _san_ready=false
                break
            fi
        done
        if [[ "$_san_ready" == true ]]; then
            _san_order+=("$_san_c")
            _san_done["$_san_c"]=1
            _san_remaining=$(( _san_remaining - 1 ))
            _san_progress=true
        fi
    done
    if [[ "$_san_progress" == false ]]; then
        echo "dev-git-sanitize: cycle in commit parents (corrupt repository?)" >&2
        exit 1
    fi
done

_san_msgfile=$(mktemp)
trap 'rm -f "$_san_msgfile"' EXIT

declare -A _san_map=()
_san_rewritten=0
for _san_c in "${_san_order[@]}"; do
    _san_tree="" _san_author="" _san_committer="" _san_in_body=false _san_body=""
    _san_old_parents=() _san_new_parents=() _san_parents_changed=false
    while IFS= read -r _san_line; do
        if [[ "$_san_in_body" == true ]]; then
            _san_body+="${_san_line}"$'\n'
            continue
        fi
        case "$_san_line" in
            "") _san_in_body=true ;;
            "tree "*) _san_tree="${_san_line#tree }" ;;
            "parent "*) _san_old_parents+=("${_san_line#parent }") ;;
            "author "*) _san_author="${_san_line#author }" ;;
            "committer "*) _san_committer="${_san_line#committer }" ;;
            *) ;;  # gpgsig, mergetag, encoding: dropped
        esac
    done < <(git cat-file commit "$_san_c")

    for _san_p in "${_san_old_parents[@]}"; do
        _san_np="${_san_map[$_san_p]:-$_san_p}"
        [[ "$_san_np" != "$_san_p" ]] && _san_parents_changed=true
        _san_new_parents+=(-p "$_san_np")
    done

    _san_new_body=$(printf '%s' "$_san_body" | _san_sanitize_message; printf x)
    _san_new_body="${_san_new_body%x}"
    if [[ "$_san_new_body" == "$_san_body" && "$_san_parents_changed" == false ]]; then
        _san_map["$_san_c"]="$_san_c"
        continue
    fi

    if [[ ! "$_san_author" =~ ^(.*)\ \<([^\>]*)\>\ ([0-9]+\ [-+][0-9]{4})$ ]]; then
        echo "dev-git-sanitize: cannot parse author of ${_san_c}" >&2
        exit 1
    fi
    _san_an="${BASH_REMATCH[1]}" _san_ae="${BASH_REMATCH[2]}" _san_ad="${BASH_REMATCH[3]}"
    if [[ ! "$_san_committer" =~ ^(.*)\ \<([^\>]*)\>\ ([0-9]+\ [-+][0-9]{4})$ ]]; then
        echo "dev-git-sanitize: cannot parse committer of ${_san_c}" >&2
        exit 1
    fi
    _san_cn="${BASH_REMATCH[1]}" _san_ce="${BASH_REMATCH[2]}" _san_cd="${BASH_REMATCH[3]}"

    printf '%s' "$_san_new_body" > "$_san_msgfile"
    _san_new=$(GIT_AUTHOR_NAME="$_san_an" GIT_AUTHOR_EMAIL="$_san_ae" GIT_AUTHOR_DATE="$_san_ad" \
        GIT_COMMITTER_NAME="$_san_cn" GIT_COMMITTER_EMAIL="$_san_ce" GIT_COMMITTER_DATE="$_san_cd" \
        git commit-tree "$_san_tree" "${_san_new_parents[@]}" --no-gpg-sign -F "$_san_msgfile")
    _san_map["$_san_c"]="$_san_new"
    _san_rewritten=$(( _san_rewritten + 1 ))
done

if (( _san_rewritten > 0 )); then
    echo "dev-git-sanitize: rewrote ${_san_rewritten} commit(s) to drop GitHub issue/PR references" >&2
fi
echo "${_san_map[$_san_head]:-$_san_head}"
