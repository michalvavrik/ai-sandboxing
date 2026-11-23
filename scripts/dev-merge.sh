#!/bin/bash
# dev merge / dev squash — put the agent's work on in-review/<feature> as your
# own commit. Both work on what `dev see` fetched (the host branch
# dev-auto/<container>/main), never on the container directly, never rebase and
# push only with -p (a force push to your fork). For a study container, dev
# merge copies files `dev see` fetched into the study directory instead
# (_devmerge_study). See _devmerge_usage.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devmerge_usage() {
    cat <<'USAGE'
Usage: dev merge [-m <message>] [-p] [name]
       dev squash [-m <message>] [-p] [name]

Takes the agent's changes as fetched by the last `dev see` (host branch
dev-auto/<container>/main) and records them on in-review/<feature> as commits
of your host git identity. in-review/<feature> is checked out when done;
nothing is pushed unless you pass -p.

  dev merge   in-review/<feature> is rebuilt as the base plus your work commits,
              re-authored under your host identity with their messages kept and
              a Signed-off-by added; the sandbox's WIP-sync noise is folded away
              so the content matches the container exactly.
  dev squash  in-review/<feature> is rebuilt as the base plus a single commit
              with the whole change (message from -m or your editor). Run it
              again and it re-squashes, offering the previous message as default.
  -p          Then force-push in-review/<feature> to your fork (the
              DEV_GHCR_USER remote), also when there was nothing to rebuild.

The base is the commit the container's work sits on: the base recorded in the
container (/workspace/.base) or, when that is stale, where the work diverges
from origin, whichever is closer to the work. Both commands rebuild the target
from that base every time, so it always matches the container's current work
(like deleting and recreating the branch, but authored by you with the sandbox
noise removed). Anything previously on the target that is not part of this work
is dropped; its old tip stays in the reflog.

The target branch is the branch the container was created from with `dev .`
(main -> main, feature-x -> feature-x). Containers
created from an issue, a PR or by `dev new` use in-review/<feature>
(keycloak-53157 -> in-review/53157, keycloak-pr-51877 -> in-review/pr-51877;
a PR container of your own PR targets the PR's in-review/* branch).

Study containers:
       dev merge [name] [path...]

Copies files the last `dev see` fetched into the study directory, at the same
relative paths (relative to /workspace, as dev see lists them). Without paths
only the new files (A); a file that replaces one of yours (M) is only taken
when you name it or a directory it is in, and your version is saved to a
tarball first.
USAGE
}

# Study container <name>: copy files of the last `dev see` — its review
# directory, so only what you could look at — into the study directory, at the
# same relative paths. Without paths only the new files; one that replaces a
# file of yours is taken only when its path or a directory it is in is given,
# after your version was saved to a tarball in DEV_STUDY_SAVE_DIR.
_devmerge_study() {
    local _name="$1" _review _study _p _start _f _saved=""
    shift
    local _named=true _new=() _repl=() _left=()
    local -A _seen=()
    _review="${DEV_STUDY_SEE_DIR}/${_name}"
    _study=$(_dev_container_label "$_name" "dev-source-dir")
    if [[ ! -d "$_study" ]]; then
        echo "Error: the study directory ${_study} does not exist" >&2
        return 1
    fi
    if [[ ! -d "$_review" ]]; then
        echo "Error: nothing fetched from '${_name}' yet — run 'dev see' first" >&2
        return 1
    fi
    if (( $# == 0 )); then
        _named=false
        set -- .
    fi
    for _p in "$@"; do
        while [[ "$_p" == ./* ]]; do _p="${_p#./}"; done
        while [[ "$_p" == */ ]]; do _p="${_p%/}"; done
        if [[ -z "$_p" || "$_p" == "." ]]; then
            _start="."
        elif [[ "$_p" != /* && "/${_p}/" != */../* && -e "${_review}/${_p}" ]]; then
            _start="./${_p}"
        else
            echo "Error: '${_p}' is not among the files the last dev see fetched (paths are relative to /workspace)" >&2
            return 1
        fi
        while IFS= read -r -d '' _f; do
            _f="${_f#./}"
            [[ -n "${_seen[$_f]:-}" ]] && continue
            _seen[$_f]=1
            if [[ -d "${_study}/${_f}" ]]; then
                echo "Error: ${_study}/${_f} is a directory — not replacing it with a file" >&2
                return 1
            fi
            case "$(_dev_study_mark "${_review}/${_f}" "${_study}/${_f}")" in
                A) _new+=("$_f") ;;
                M) if [[ "$_named" == true ]]; then _repl+=("$_f"); else _left+=("$_f"); fi ;;
            esac
        done < <(cd "$_review" && find "$_start" -type f -print0 | sort -z)
    done

    if (( ${#_repl[@]} > 0 )); then
        mkdir -p "$DEV_STUDY_SAVE_DIR"
        _saved=$(mktemp --suffix=.tar.gz "${DEV_STUDY_SAVE_DIR}/${_name}-merge-$(date +%s)-XXXX")
        if ! printf '%s\0' "${_repl[@]}" | tar -C "$_study" --null -T - -czf "$_saved"; then
            rm -f "$_saved"
            echo "Error: could not save your files that would be replaced — nothing taken" >&2
            return 1
        fi
    fi
    for _f in "${_new[@]}" "${_repl[@]}"; do
        mkdir -p "$(dirname "${_study}/${_f}")"
        cp -fT --no-preserve=mode "${_review}/${_f}" "${_study}/${_f}"
    done

    if (( ${#_new[@]} + ${#_repl[@]} == 0 )); then
        echo "Nothing to take into ${_study}."
    else
        echo "Took $(( ${#_new[@]} + ${#_repl[@]} )) file(s) into ${_study}:"
        for _f in "${_new[@]}"; do echo "  A ${_f}"; done
        for _f in "${_repl[@]}"; do echo "  M ${_f}"; done
    fi
    [[ -n "$_saved" ]] && echo "Your versions of the replaced files: ${_saved} (kept ${DEV_BACKUP_MAX_AGE_DAYS} days)"
    if (( ${#_left[@]} > 0 )); then
        echo "Not taken, they would replace files of yours (name them to take them):"
        for _f in "${_left[@]}"; do echo "  M ${_f}"; done
    fi
    return 0
}

_devmerge_mode="merge"
_devmerge_message=""
_devmerge_push=false
_devmerge_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --squash) _devmerge_mode="squash"; shift ;;
        -m) _devmerge_message="${2:?'-m requires a message'}"; shift 2 ;;
        -m*) _devmerge_message="${1#-m}"; shift ;;
        -p) _devmerge_push=true; shift ;;
        --help|-h) _devmerge_usage; exit 0 ;;
        -*) echo "dev ${_devmerge_mode}: unknown option '$1'" >&2; _devmerge_usage >&2; exit 1 ;;
        *) _devmerge_args+=("$1"); shift ;;
    esac
done
# The first argument names the container when one of that name exists; the
# others are paths, which only a study container takes.
_devmerge_name_arg=""
if (( ${#_devmerge_args[@]} > 0 )) && _dev_container_exists "${_devmerge_args[0]}"; then
    _devmerge_name_arg="${_devmerge_args[0]}"
    _devmerge_args=("${_devmerge_args[@]:1}")
fi

# Only inside the project's source directory, only its containers.
_devmerge_name=$(_dev_resolve_project_container "$_devmerge_name_arg")
readonly _devmerge_name

if _dev_container_is_study "$_devmerge_name"; then
    if [[ "$_devmerge_mode" == "squash" || -n "$_devmerge_message" || "$_devmerge_push" == true ]]; then
        echo "Error: ${_devmerge_name} is a study container — there is no commit to squash, push or write a message for" >&2
        echo "('dev merge [path...]' copies files of the last dev see into its directory)" >&2
        exit 1
    fi
    _devmerge_study "$_devmerge_name" "${_devmerge_args[@]}"
    exit 0
fi
if (( ${#_devmerge_args[@]} > 0 )); then
    echo "Error: container '${_devmerge_args[0]}' does not exist" >&2
    exit 1
fi

_devmerge_template_key=$(_dev_container_template_key "$_devmerge_name")
if [[ -z "$_devmerge_template_key" ]]; then
    echo "Error: could not determine template from container labels" >&2
    exit 1
fi
_devmerge_repo="${_devmerge_template_key#*/}"
_devmerge_src=$(_dev_resolve_src_dir "$_devmerge_template_key") || {
    echo "Error: source directory not found for '${_devmerge_template_key}'" >&2
    exit 1
}
readonly _devmerge_src _devmerge_repo

_devmerge_target=$(_dev_container_target_branch "$_devmerge_name" "$_devmerge_repo")
readonly _devmerge_target
readonly _devmerge_agent="dev-auto/${_devmerge_name}/main"
_devmerge_label=$(_dev_container_label "$_devmerge_name" "dev-original-branch")

_dg() { git -C "$_devmerge_src" "$@"; }

if [[ "$_devmerge_push" == true ]] && ! _dg remote get-url "$DEV_GHCR_USER" &>/dev/null; then
    echo "Error: ${_devmerge_src} has no git remote '${DEV_GHCR_USER}' (your fork) for -p to push to" >&2
    exit 1
fi

# -p: force-push the target branch to your fork. A branch this run created gets
# it as its upstream; an existing one keeps the upstream it has.
_devmerge_push_target() {
    local _upstream=()
    [[ "$_devmerge_target_exists" == true ]] || _upstream=(-u)
    if ! _dg push --force "${_upstream[@]}" "$DEV_GHCR_USER" \
            "refs/heads/${_devmerge_target}:refs/heads/${_devmerge_target}"; then
        echo "Error: could not push ${_devmerge_target} to ${DEV_GHCR_USER}" >&2
        exit 1
    fi
}

if ! _dg rev-parse -q --verify "refs/heads/${_devmerge_agent}" >/dev/null; then
    echo "Error: host branch ${_devmerge_agent} not found — run 'dev see ${_devmerge_name}' first" >&2
    exit 1
fi
_devmerge_agent_sha=$(_dg rev-parse "refs/heads/${_devmerge_agent}")
_devmerge_agent_tree=$(_dg rev-parse "${_devmerge_agent_sha}^{tree}")

_devmerge_user_name=$(_dg config user.name 2>/dev/null) || true
_devmerge_user_email=$(_dg config user.email 2>/dev/null) || true
if [[ -z "$_devmerge_user_name" || -z "$_devmerge_user_email" ]]; then
    echo "Error: git user.name or user.email not configured in ${_devmerge_src}" >&2
    exit 1
fi

echo "Container:  ${_devmerge_name}"
echo "Source:     ${_devmerge_agent} ($(_dg log -1 --format='%h %s' "$_devmerge_agent_sha"))"
echo "Target:     ${_devmerge_target}"

# ── Warn when the container has moved on since the last dev see ──────────────
if _dev_container_running "$_devmerge_name" && _dev_update_ssh_config "$_devmerge_name" 2>/dev/null; then
    _devmerge_state=$(ssh -q -o ConnectTimeout=3 -o BatchMode=yes "$_devmerge_name" \
        'cd /workspace && git rev-parse HEAD && git status --porcelain | head -n1' </dev/null 2>/dev/null) || _devmerge_state=""
    if [[ -n "$_devmerge_state" ]]; then
        _devmerge_chead="${_devmerge_state%%$'\n'*}"
        _devmerge_cdirty="${_devmerge_state#"$_devmerge_chead"}"
        if [[ "$_devmerge_chead" != "$_devmerge_agent_sha" || -n "${_devmerge_cdirty//[[:space:]]/}" ]]; then
            echo "WARNING: container '${_devmerge_name}' has changes that 'dev see' has not fetched — using the last dev see." >&2
        fi
    fi
fi

# ── Base: the upstream commit the container's work is built on ────────────────
# Both commands rebuild <target> from this base, so everything above it on the
# agent branch counts as the work. Two candidates: the container's recorded
# .base (valid only when it is a real commit the work still sits on) and where
# the work diverges from origin's default branch. Use whichever is closer to the
# work, so it stays right when .base is stale (main moved on) and when the work
# sits on a feature branch (no origin merge base near it).
_devmerge_recorded=""
if _dev_container_running "$_devmerge_name" && _dev_update_ssh_config "$_devmerge_name" 2>/dev/null; then
    _devmerge_recorded=$(ssh -q -o ConnectTimeout=3 -o BatchMode=yes "$_devmerge_name" \
        'cat /workspace/.base 2>/dev/null' </dev/null 2>/dev/null | tr -d '[:space:]') || _devmerge_recorded=""
fi
if [[ ! "$_devmerge_recorded" =~ ^[0-9a-f]{40}$ ]] \
    || ! _dg cat-file -e "${_devmerge_recorded}^{commit}" 2>/dev/null \
    || ! _dg merge-base --is-ancestor "$_devmerge_recorded" "$_devmerge_agent_sha" 2>/dev/null; then
    _devmerge_recorded=""
fi
_devmerge_up=$(_dg rev-parse --verify -q 'refs/remotes/origin/HEAD^{commit}' 2>/dev/null) \
    || _devmerge_up=$(_dg rev-parse --verify -q 'refs/remotes/origin/main^{commit}' 2>/dev/null) \
    || _devmerge_up=$(_dg rev-parse --verify -q 'refs/remotes/origin/master^{commit}' 2>/dev/null) \
    || _devmerge_up=""
_devmerge_diverge=""
if [[ -n "$_devmerge_up" ]]; then
    _devmerge_diverge=$(_dg merge-base "$_devmerge_up" "$_devmerge_agent_sha" 2>/dev/null) || _devmerge_diverge=""
fi
if [[ -n "$_devmerge_recorded" && -n "$_devmerge_diverge" ]]; then
    # The newer of the two is the one that descends from the other; when they are
    # unrelated (feature branch), .base is the one that tracks the work.
    if _dg merge-base --is-ancestor "$_devmerge_recorded" "$_devmerge_diverge" 2>/dev/null; then
        _devmerge_base="$_devmerge_diverge"
    else
        _devmerge_base="$_devmerge_recorded"
    fi
elif [[ -n "$_devmerge_recorded" ]]; then
    _devmerge_base="$_devmerge_recorded"
else
    _devmerge_base="$_devmerge_diverge"
fi
if [[ -z "$_devmerge_base" ]]; then
    echo "Error: could not determine the base for ${_devmerge_name} (no readable .base, no origin merge base)." >&2
    echo "Start the container so its /workspace/.base can be read, then retry." >&2
    exit 1
fi
readonly _devmerge_base
_devmerge_base_tree=$(_dg rev-parse "${_devmerge_base}^{tree}")
echo "Base:       $(_dg log -1 --format='%h %s' "$_devmerge_base")"

if _dg rev-parse -q --verify "refs/heads/${_devmerge_target}" >/dev/null; then
    _devmerge_target_exists=true
else
    _devmerge_target_exists=false
fi

# Nothing to do when the work is identical to the base.
if [[ "$_devmerge_agent_tree" == "$_devmerge_base_tree" ]]; then
    echo "Nothing to ${_devmerge_mode}: no changes on top of the base."
    if [[ "$_devmerge_push" == true && "$_devmerge_target_exists" == true ]]; then
        _devmerge_push_target
    fi
    exit 0
fi

# Sandbox commits carry uncommitted changes across a sync; folded away, never
# kept as commits of their own.
_devmerge_is_sandbox_subject() {
    case "$1" in WIP|"sync from host"|"WIP sync"|backup|"pre-rebase save") return 0 ;; esac
    return 1
}

# Resolve a commit message into _devmerge_resolved_msg: from -m, else the editor
# pre-filled with $1. It runs the editor itself, so call it as a statement, never
# in a command substitution (that would capture the editor's terminal output).
_devmerge_resolved_msg=""
_devmerge_resolve_message() {
    local _default="$1" _f _ed
    if [[ -n "$_devmerge_message" ]]; then
        _devmerge_resolved_msg="$_devmerge_message"
        return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "Error: no terminal for the editor — pass the message with -m" >&2
        return 1
    fi
    _f=$(mktemp)
    {
        printf '%s\n' "$_default"
        echo ""
        echo "# Commit message for ${_devmerge_target}."
        echo "# Lines starting with '#' are ignored; an empty message aborts."
        echo "# Signed-off-by is added automatically."
    } > "$_f"
    _ed=$(_dg var GIT_EDITOR)
    if ! (cd "$_devmerge_src" && eval "$_ed \"\$_f\""); then
        rm -f "$_f"; echo "Error: editor exited with an error, aborting" >&2; return 1
    fi
    _devmerge_resolved_msg=$(_dg stripspace --strip-comments < "$_f"); rm -f "$_f"
    if [[ -z "${_devmerge_resolved_msg//[[:space:]]/}" ]]; then
        echo "Aborting: empty commit message." >&2; return 1
    fi
    return 0
}

# Write <message> plus a Signed-off-by trailer to the shared message file, which
# each commit below is built from in turn (a commit reads it right away, so one
# file is reused rather than tracking many across command substitutions).
_devmerge_msgfile=$(mktemp)
trap 'rm -f "$_devmerge_msgfile"' EXIT
_devmerge_write_msg() {
    # Drop any Co-authored-by trailer the agent's commit carried: in-review
    # commits are yours, authored solely by your host identity. Then add the
    # Signed-off-by.
    printf '%s\n' "$1" \
        | sed -E '/^[[:space:]]*[Cc]o-[Aa]uthored-[Bb]y:/d' \
        | _dg interpret-trailers --if-exists addIfDifferent \
            --trailer "Signed-off-by: ${_devmerge_user_name} <${_devmerge_user_email}>" \
        > "$_devmerge_msgfile"
}

echo ""
_dg diff --stat "$_devmerge_base" "$_devmerge_agent_tree"
echo ""

# ── Build the new tip on the base ─────────────────────────────────────────────
if [[ "$_devmerge_mode" == "squash" ]]; then
    # One commit on the base holding the whole net change.
    _devmerge_default=""
    if [[ "$_devmerge_target_exists" == true \
          && "$(_dg rev-parse -q --verify "${_devmerge_target}^" 2>/dev/null)" == "$_devmerge_base" ]]; then
        _devmerge_default=$(_dg log -1 --format=%B "$_devmerge_target")   # re-squash keeps the message
    else
        while read -r _devmerge_s _devmerge_subj; do
            [[ -z "$_devmerge_s" ]] && continue
            if _devmerge_is_sandbox_subject "$_devmerge_subj"; then continue; fi
            _devmerge_default=$(_dg log -1 --format=%B "$_devmerge_s")
            break
        done < <(_dg log --first-parent --format='%H %s' "${_devmerge_base}..${_devmerge_agent_sha}")
    fi
    if ! _devmerge_resolve_message "$_devmerge_default"; then exit 1; fi
    _devmerge_write_msg "$_devmerge_resolved_msg"
    _devmerge_new=$(_dev_commit_as_host "$_devmerge_src" "$_devmerge_agent_tree" \
        "$_devmerge_msgfile" "" "$_devmerge_base")
else
    # merge: replay the real work commits on the base, each with its own author
    # date, folding the sandbox and any uncommitted changes into the last one so
    # the content ends up identical to the container's.
    _devmerge_reals=()
    while read -r _devmerge_s _devmerge_subj; do
        [[ -z "$_devmerge_s" ]] && continue
        if _devmerge_is_sandbox_subject "$_devmerge_subj"; then continue; fi
        _devmerge_reals+=("$_devmerge_s")
    done < <(_dg log --first-parent --reverse --format='%H %s' "${_devmerge_base}..${_devmerge_agent_sha}")

    if (( ${#_devmerge_reals[@]} == 0 )); then
        # Only sandbox or uncommitted work: one commit, message from -m or editor.
        if ! _devmerge_resolve_message ""; then exit 1; fi
        _devmerge_write_msg "$_devmerge_resolved_msg"
        _devmerge_new=$(_dev_commit_as_host "$_devmerge_src" "$_devmerge_agent_tree" \
            "$_devmerge_msgfile" "" "$_devmerge_base")
    else
        _devmerge_new="$_devmerge_base"
        _devmerge_last=$(( ${#_devmerge_reals[@]} - 1 ))
        for _devmerge_i in "${!_devmerge_reals[@]}"; do
            _devmerge_c="${_devmerge_reals[$_devmerge_i]}"
            if (( _devmerge_i == _devmerge_last )); then
                _devmerge_ct="$_devmerge_agent_tree"
            else
                _devmerge_ct=$(_dg rev-parse "${_devmerge_c}^{tree}")
            fi
            _devmerge_write_msg "$(_dg log -1 --format=%B "$_devmerge_c")"
            _devmerge_new=$(_dev_commit_as_host "$_devmerge_src" "$_devmerge_ct" "$_devmerge_msgfile" \
                "$(_dg log -1 --format=%ad --date=raw "$_devmerge_c")" "$_devmerge_new")
        done
    fi
fi

# ── Rebuild the target branch at the new tip and check it out ─────────────────
_devmerge_current=$(_dg branch --show-current 2>/dev/null) || _devmerge_current=""
if [[ "$_devmerge_current" == "$_devmerge_target" ]]; then
    # On the branch already: move it and update the working tree together, keeping
    # local changes (refuses, and changes nothing, if they would be overwritten).
    if ! _dg reset -q --keep "$_devmerge_new"; then
        echo "Error: ${_devmerge_target} is checked out with local changes in the way; commit or stash them and retry" >&2
        exit 1
    fi
else
    _dg update-ref "refs/heads/${_devmerge_target}" "$_devmerge_new"
    if ! _dg checkout -q "$_devmerge_target"; then
        echo "NOTE: ${_devmerge_target} updated but could not be checked out (local changes?); run: git -C ${_devmerge_src} checkout ${_devmerge_target}" >&2
    fi
fi

_devmerge_count=$(_dg rev-list --count "${_devmerge_base}..${_devmerge_new}")
if [[ "$_devmerge_target_exists" == true ]]; then
    echo "Rebuilt ${_devmerge_target} (${_devmerge_count} commit(s) on the base); tip $(_dg log -1 --format='%h %s' "$_devmerge_new")"
else
    echo "Created ${_devmerge_target} (${_devmerge_count} commit(s) on the base); tip $(_dg log -1 --format='%h %s' "$_devmerge_new")"
fi
echo "Author: ${_devmerge_user_name} <${_devmerge_user_email}>"

if [[ "$_devmerge_push" == true ]]; then
    _devmerge_push_target
fi
