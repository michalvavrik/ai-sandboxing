# The `dev` command. Sourced by the dev() function from dev-shell-init.sh so
# that DEV_LAST_CONTAINER (the remembered current container) lives in the
# calling shell. Not meant to be executed directly.
#
# Global option (anywhere on the command line, never seen by subcommands):
#   --auth-method=vertex|api-key   Claude Code auth for containers created by
#                                  this command (default: DEV_AUTH_METHOD from
#                                  config.local, else api-key)

_dev_usage() {
    echo "Usage: dev {new|enter|recreate|delete|start|see|show|push|merge|rebase|cp|cpout|use|list|pull|sync|continue|install|review|.|<url>}"
    echo ""
    echo "  new <name>     Create and enter a new dev container"
    echo "  enter [name]   Enter an existing container"
    echo "  recreate [name] Fresh container, preserves workspace and Claude session"
    echo "  delete [name]  Remove container (merges to tracked branch first; --dont-merge to skip)"
    echo "  start [name]   Start a stopped container"
    echo "  see [name]     Sync changes to host (squashes commits; --dont-squash to keep history)"
    echo "  show [name]    Push host changes into a container (works from wip/*, in-review/*, dev-auto/*)"
    echo "  push [name]    Push agent's work (wip/* becomes in-review/*, --local to skip remote push)"
    echo "  merge [name]   Sync container state to tracked branch (wip/*, in-review/*, etc.)"
    echo "  rebase [name]  Rebase container workspace on latest upstream main"
    echo "  cp [--to <dir>] <path>  Copy files/dirs into container (default: /tmp/workspace)"
    echo "  cpout [--to <dir>] <path> Copy files/dirs from container (default: cwd)"
    echo "  use <name>     Set current container without entering"
    echo "  list           List all dev containers"
    echo "  pull           Pull newer images and fetch project sources"
    echo "  sync           Pull images/sources + prune dead branches (wip, in-review, dev-auto)"
    echo "  continue [name] Check out an existing wip/in-review branch (tab-completes feature names)"
    echo "  install        Install prerequisites and configure"
    echo "  .              Create/enter container from current git project"
    echo "  review [opts] [url|container-name|\"follow-up\"]  Headless agent review"
    echo "                 (--agent=claude|bob|agy, --model=opus|fable|flash|pro, --loop[=normal|best|all|list])"
    echo "  <github-url>   Create/enter container for a GitHub issue/PR"
    echo "  <github-url> --loop[=profile]  Set up the container and run a multi-model review loop"
    echo ""
    echo "  --auth-method=vertex|api-key  Claude Code auth for newly created containers"
    echo "                 (default: DEV_AUTH_METHOD from config.local, else api-key)"
    echo ""
    echo "The container a command works with is remembered per terminal: after 'dev new foo'"
    echo "or 'dev enter foo', 'dev see', 'dev review', 'dev cp' ... apply to foo."
}

# Run a subcommand script. _DEV_SHELL_PID lets the script report the container
# it worked with (see _dev_remember_container in dev-common.sh); the remembered
# container is passed through the environment so scripts can resolve "no name".
_dev_sub() {
    local _dev_script="$1"
    shift
    _DEV_SHELL_PID=$$ DEV_LAST_CONTAINER="${DEV_LAST_CONTAINER:-}" "${_dev_dir}/${_dev_script}" "$@"
}

_dev_dispatch() {
    local _dev_cmd="$1"
    shift
    case "$_dev_cmd" in
        new|enter|recreate|delete|start|see|show|push|merge|rebase|cp|cpout|review|continue)
            _dev_sub "dev-${_dev_cmd}.sh" "$@"
            ;;
        use)
            if [[ -z "${1:-}" ]]; then
                echo "Usage: dev use <name>" >&2
                return 1
            fi
            if ! podman container exists "$1" 2>/dev/null; then
                echo "dev: container '$1' does not exist" >&2
                return 1
            fi
            DEV_LAST_CONTAINER="$1"
            echo "Using: ${DEV_LAST_CONTAINER}"
            ;;
        list|pull|sync|install)
            "${_dev_dir}/dev-${_dev_cmd}.sh"
            ;;
        .)
            _dev_sub dev-local.sh "$@"
            ;;
        http://*|https://*)
            # `dev <url>` creates/enters the container. With review options it
            # runs a headless review there instead (same as `dev review <url> ...`).
            local _dev_review=false _dev_a
            for _dev_a in "$@"; do
                case "$_dev_a" in
                    --loop|--loop=*|--agent|--agent=*|--model|--model=*|--prompt|--append-to-prompt)
                        _dev_review=true ;;
                esac
            done
            if [[ "$_dev_review" == true ]]; then
                _dev_sub dev-review.sh "$@" "$_dev_cmd"
            elif (( $# > 0 )); then
                echo "dev: unexpected arguments after <url>: $* (use --loop to run a review)" >&2
                return 1
            else
                _dev_sub dev-issue.sh "$_dev_cmd"
            fi
            ;;
        help|--help|-h)
            _dev_usage
            ;;
        *)
            echo "dev: unknown command '${_dev_cmd}'" >&2
            _dev_usage >&2
            return 1
            ;;
    esac
}

_dev_main() {
    local _dev_dir _dev_cmd _dev_rest=() _dev_a _dev_state _dev_rc _dev_new _dev_auth_actual
    _dev_dir="$(dirname "${BASH_SOURCE[0]}")"
    _dev_cmd="${1:-help}"
    shift 2>/dev/null || true

    unset DEV_AUTH_METHOD_OVERRIDE
    for _dev_a in "$@"; do
        case "$_dev_a" in
            --auth-method=*) DEV_AUTH_METHOD_OVERRIDE="${_dev_a#--auth-method=}" ;;
            *) _dev_rest+=("$_dev_a") ;;
        esac
    done
    if [[ "$_dev_cmd" == --auth-method=* ]]; then
        DEV_AUTH_METHOD_OVERRIDE="${_dev_cmd#--auth-method=}"
        _dev_cmd="${_dev_rest[0]:-help}"
        _dev_rest=("${_dev_rest[@]:1}")
    fi
    if [[ -n "${DEV_AUTH_METHOD_OVERRIDE:-}" ]]; then
        case "$DEV_AUTH_METHOD_OVERRIDE" in
            vertex|api-key) export DEV_AUTH_METHOD_OVERRIDE ;;
            *)
                echo "dev: unknown --auth-method '${DEV_AUTH_METHOD_OVERRIDE}' (use: vertex, api-key)" >&2
                unset DEV_AUTH_METHOD_OVERRIDE
                return 1
                ;;
        esac
    fi

    # Forget a remembered container that no longer exists (deleted elsewhere).
    if [[ -n "${DEV_LAST_CONTAINER:-}" ]] && ! podman container exists "$DEV_LAST_CONTAINER" 2>/dev/null; then
        unset DEV_LAST_CONTAINER
    fi

    # Subcommands report the container they actually worked with through this
    # per-shell file (names resolved from cwd, created from a URL, ...). Only a
    # successful report changes the remembered container, so a failed or
    # aborted command never clears it.
    _dev_state="/run/user/$(id -u)/dev-last-container.$$"
    rm -f "$_dev_state"

    _dev_dispatch "$_dev_cmd" "${_dev_rest[@]+"${_dev_rest[@]}"}"
    _dev_rc=$?

    if [[ -s "$_dev_state" ]]; then
        _dev_new=$(<"$_dev_state")
        if [[ -n "$_dev_new" ]] && podman container exists "$_dev_new" 2>/dev/null; then
            DEV_LAST_CONTAINER="$_dev_new"
        fi
    fi
    rm -f "$_dev_state"
    if [[ -n "${DEV_LAST_CONTAINER:-}" ]] && ! podman container exists "$DEV_LAST_CONTAINER" 2>/dev/null; then
        unset DEV_LAST_CONTAINER
    fi

    # --auth-method only takes effect when a container is created; warn if an
    # existing container was reused with a different method.
    if [[ -n "${DEV_AUTH_METHOD_OVERRIDE:-}" && -n "${DEV_LAST_CONTAINER:-}" ]] \
        && podman container exists "$DEV_LAST_CONTAINER" 2>/dev/null; then
        _dev_auth_actual=$(podman inspect --format '{{index .Config.Labels "dev-auth-method"}}' "$DEV_LAST_CONTAINER" 2>/dev/null) || true
        [[ -z "$_dev_auth_actual" || "$_dev_auth_actual" == "<no value>" ]] && _dev_auth_actual="vertex"
        if [[ "$_dev_auth_actual" != "$DEV_AUTH_METHOD_OVERRIDE" ]]; then
            echo "WARNING: '${DEV_LAST_CONTAINER}' uses --auth-method=${_dev_auth_actual} (set when it was created)." >&2
            echo "         To switch: dev recreate --auth-method=${DEV_AUTH_METHOD_OVERRIDE} ${DEV_LAST_CONTAINER}" >&2
        fi
    fi
    unset DEV_AUTH_METHOD_OVERRIDE
    return "$_dev_rc"
}

_dev_main "$@"
_dev_main_rc=$?
unset -f _dev_main _dev_dispatch _dev_sub _dev_usage
eval "unset _dev_main_rc; return ${_dev_main_rc} 2>/dev/null || exit ${_dev_main_rc}"
