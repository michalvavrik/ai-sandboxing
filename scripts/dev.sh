# Sourced via: alias dev="source <path>/scripts/dev.sh"
_dev_dir="$(dirname "${BASH_SOURCE[0]}")"
_dev_cmd="${1:-help}"
shift 2>/dev/null || true

if [[ -n "${DEV_LAST_CONTAINER:-}" ]] && ! podman container exists "$DEV_LAST_CONTAINER" 2>/dev/null; then
    unset DEV_LAST_CONTAINER
fi

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
    "${_dev_dir}/dev-delete.sh" "${1:-${DEV_LAST_CONTAINER:-}}"
    if [[ "${1:-${DEV_LAST_CONTAINER:-}}" == "${DEV_LAST_CONTAINER:-}" ]]; then
      unset DEV_LAST_CONTAINER
    fi
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
  install)
    "${_dev_dir}/dev-install.sh"
    ;;
  .)
    "${_dev_dir}/dev-local.sh"
    DEV_LAST_CONTAINER=$(cat "/run/user/$(id -u)/dev-last-container" 2>/dev/null) || true
    ;;
  http*|https*)
    "${_dev_dir}/dev-issue.sh" "$_dev_cmd"
    DEV_LAST_CONTAINER=$(cat "/run/user/$(id -u)/dev-last-container" 2>/dev/null) || true
    ;;
  help|*)
    echo "Usage: dev {new|enter|recreate|delete|start|see|show|push|rebase|cp|cpout|use|list|pull|install|.|<url>}"
    echo ""
    echo "  new <name>     Create and enter a new dev container"
    echo "  enter [name]   Enter an existing container"
    echo "  recreate [name] Fresh container, preserves workspace and Claude session"
    echo "  delete [name]  Remove a container"
    echo "  start [name]   Start a stopped container"
    echo "  see [name]     Sync changes to host (squashes commits; --dont-squash to keep history)"
    echo "  show [name]    Push host changes into a container"
    echo "  push [name]    Push agent's work to the original branch (--local to skip)"
    echo "  rebase [name]  Rebase container workspace on latest upstream main"
    echo "  cp [--to <dir>] <path>  Copy files/dirs into container (default: /tmp/workspace)"
    echo "  cpout [--to <dir>] <path> Copy files/dirs from container (default: cwd)"
    echo "  use <name>     Set current container without entering"
    echo "  list           List all dev containers"
    echo "  pull           Pull newer images and fetch project sources (runs on login)"
    echo "  install        Install prerequisites and configure"
    echo "  .              Create/enter container from current git project"
    echo "  <github-url>   Create/enter container for a GitHub issue/PR"
    ;;
esac

unset _dev_cmd _dev_dir 2>/dev/null
