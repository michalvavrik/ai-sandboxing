# Sourced via: alias dev="source <path>/scripts/dev.sh"
_dev_dir="$(dirname "${BASH_SOURCE[0]}")"
_dev_cmd="${1:-help}"
shift 2>/dev/null || true

# Global option --auth-method=vertex|api-key (Claude Code only; applies when a
# container is created). Stripped here so subcommands never see it.
unset DEV_AUTH_METHOD_OVERRIDE
_dev_rest=()
for _dev_a in "$@"; do
  case "$_dev_a" in
    --auth-method=*) DEV_AUTH_METHOD_OVERRIDE="${_dev_a#--auth-method=}" ;;
    *) _dev_rest+=("$_dev_a") ;;
  esac
done
if [[ -n "${DEV_AUTH_METHOD_OVERRIDE:-}" ]]; then
  case "$DEV_AUTH_METHOD_OVERRIDE" in
    vertex|api-key) export DEV_AUTH_METHOD_OVERRIDE ;;
    *)
      echo "dev: unknown --auth-method '${DEV_AUTH_METHOD_OVERRIDE}' (use: vertex, api-key)" >&2
      unset DEV_AUTH_METHOD_OVERRIDE _dev_rest _dev_a _dev_cmd _dev_dir
      return 1 2>/dev/null || exit 1
      ;;
  esac
fi

if [[ -n "${DEV_LAST_CONTAINER:-}" ]] && ! podman container exists "$DEV_LAST_CONTAINER" 2>/dev/null; then
    unset DEV_LAST_CONTAINER
fi

# Dispatch in a function so the filtered args never touch the caller's
# positional parameters (this file is sourced).
_dev_dispatch() {
case "$_dev_cmd" in
  new)
    DEV_LAST_CONTAINER="${1:?'Usage: dev new <name>'}"
    "${_dev_dir}/dev-new.sh" "$@"
    ;;
  recreate)
    DEV_LAST_CONTAINER="${1:-${DEV_LAST_CONTAINER:-}}"
    "${_dev_dir}/dev-recreate.sh" "$DEV_LAST_CONTAINER"
    ;;
  delete)
    _dev_del_name=""
    _dev_del_flags=()
    for _dev_a in "$@"; do
      if [[ "$_dev_a" == --* ]]; then _dev_del_flags+=("$_dev_a")
      elif [[ -z "$_dev_del_name" ]]; then _dev_del_name="$_dev_a"
      fi
    done
    _dev_del_name="${_dev_del_name:-${DEV_LAST_CONTAINER:-}}"
    "${_dev_dir}/dev-delete.sh" ${_dev_del_name:+"$_dev_del_name"} "${_dev_del_flags[@]+"${_dev_del_flags[@]}"}"
    if [[ "$_dev_del_name" == "${DEV_LAST_CONTAINER:-}" ]]; then
      unset DEV_LAST_CONTAINER
    fi
    ;;
  merge)
    DEV_LAST_CONTAINER="${1:-${DEV_LAST_CONTAINER:-}}"
    "${_dev_dir}/dev-merge.sh" "$DEV_LAST_CONTAINER"
    ;;
  enter)
    DEV_LAST_CONTAINER="${1:-${DEV_LAST_CONTAINER:-}}"
    "${_dev_dir}/dev-enter.sh" "$DEV_LAST_CONTAINER"
    ;;
  start)
    DEV_LAST_CONTAINER="${1:-${DEV_LAST_CONTAINER:-}}"
    "${_dev_dir}/dev-start.sh" "$DEV_LAST_CONTAINER"
    ;;
  see)
    DEV_LAST_CONTAINER="${1:-${DEV_LAST_CONTAINER:-}}"
    "${_dev_dir}/dev-see.sh" "$DEV_LAST_CONTAINER"
    ;;
  show)
    DEV_LAST_CONTAINER="${1:-${DEV_LAST_CONTAINER:-}}"
    "${_dev_dir}/dev-show.sh" "$DEV_LAST_CONTAINER"
    ;;
  push)
    for _dev_a in "$@"; do [[ "$_dev_a" != --* ]] && DEV_LAST_CONTAINER="$_dev_a" && break; done
    DEV_LAST_CONTAINER="${DEV_LAST_CONTAINER:-}" "${_dev_dir}/dev-push.sh" "$@"
    ;;
  rebase)
    DEV_LAST_CONTAINER="${1:-${DEV_LAST_CONTAINER:-}}"
    "${_dev_dir}/dev-rebase.sh" "$DEV_LAST_CONTAINER"
    ;;
  cp)
    DEV_LAST_CONTAINER="${DEV_LAST_CONTAINER:-}" "${_dev_dir}/dev-cp.sh" "$@"
    ;;
  cpout)
    DEV_LAST_CONTAINER="${DEV_LAST_CONTAINER:-}" "${_dev_dir}/dev-cpout.sh" "$@"
    ;;
  use)
    DEV_LAST_CONTAINER="${1:?'Usage: dev use <name>'}"
    echo "Using: ${DEV_LAST_CONTAINER}"
    ;;
  list)
    "${_dev_dir}/dev-list.sh"
    ;;
  pull)
    "${_dev_dir}/dev-pull.sh"
    ;;
  sync)
    "${_dev_dir}/dev-sync.sh"
    ;;
  continue)
    "${_dev_dir}/dev-continue.sh" "$@"
    ;;
  install)
    "${_dev_dir}/dev-install.sh"
    ;;
  .)
    _DEV_SHELL_PID=$$ "${_dev_dir}/dev-local.sh"
    DEV_LAST_CONTAINER=$(cat "/run/user/$(id -u)/dev-last-container.$$" 2>/dev/null) || true
    rm -f "/run/user/$(id -u)/dev-last-container.$$"
    ;;
  http*|https*)
    _DEV_SHELL_PID=$$ "${_dev_dir}/dev-issue.sh" "$_dev_cmd"
    DEV_LAST_CONTAINER=$(cat "/run/user/$(id -u)/dev-last-container.$$" 2>/dev/null) || true
    rm -f "/run/user/$(id -u)/dev-last-container.$$"
    ;;
  review)
    _DEV_SHELL_PID=$$ "${_dev_dir}/dev-review.sh" "$@"
    DEV_LAST_CONTAINER=$(cat "/run/user/$(id -u)/dev-last-container.$$" 2>/dev/null) || true
    rm -f "/run/user/$(id -u)/dev-last-container.$$"
    ;;
  help|*)
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
    echo "  review [opts] [url|container-name|\"follow-up\"]  Headless agent review (--agent=claude|bob|agy, --model=flash|pro|opus)"
    echo "  <github-url>   Create/enter container for a GitHub issue/PR"
    echo ""
    echo "  --auth-method=vertex|api-key  Claude Code auth for newly created containers"
    echo "                 (default: DEV_AUTH_METHOD from config.local, else vertex)"
    ;;
esac
}
_dev_dispatch "${_dev_rest[@]+"${_dev_rest[@]}"}"
unset -f _dev_dispatch
unset _dev_rest

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
  unset _dev_auth_actual
fi
unset DEV_AUTH_METHOD_OVERRIDE

unset _dev_cmd _dev_dir 2>/dev/null
