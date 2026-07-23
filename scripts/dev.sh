# Sourced via: alias dev="source <path>/scripts/dev.sh"
_dev_dir="$(dirname "${BASH_SOURCE[0]}")"
_dev_cmd="${1:-help}"
shift 2>/dev/null || true

# Check token expiry on any container-related command (soft warning, non-blocking)
case "$_dev_cmd" in
  new|enter|start|see|http*|https*)
    (source "${_dev_dir}/dev-common.sh"; _dev_check_container_pat) || true
    ;;
esac

case "$_dev_cmd" in
  new)
    DEV_LAST_CONTAINER="${1:?'Usage: dev new <name>'}"
    "${_dev_dir}/dev-new.sh" "$@"
    ;;
  delete)
    "${_dev_dir}/dev-delete.sh" "${1:-$DEV_LAST_CONTAINER}"
    if [[ "${1:-$DEV_LAST_CONTAINER}" == "${DEV_LAST_CONTAINER:-}" ]]; then
      unset DEV_LAST_CONTAINER
    fi
    ;;
  enter)
    DEV_LAST_CONTAINER="${1:-$DEV_LAST_CONTAINER}"
    "${_dev_dir}/dev-enter.sh" "${DEV_LAST_CONTAINER:?'No container specified. Use: dev enter <name>'}"
    ;;
  stop)
    "${_dev_dir}/dev-stop.sh" "${1:-${DEV_LAST_CONTAINER:?'No container specified'}}"
    ;;
  start)
    DEV_LAST_CONTAINER="${1:-$DEV_LAST_CONTAINER}"
    "${_dev_dir}/dev-start.sh" "${DEV_LAST_CONTAINER:?'No container specified'}"
    ;;
  see)
    "${_dev_dir}/dev-see.sh" "${1:-${DEV_LAST_CONTAINER:?'No container specified'}}"
    ;;
  cp)
    DEV_LAST_CONTAINER="${DEV_LAST_CONTAINER:-}" "${_dev_dir}/dev-cp.sh" "$@"
    ;;
  cpout)
    DEV_LAST_CONTAINER="${DEV_LAST_CONTAINER:-}" "${_dev_dir}/dev-cpout.sh" "$@"
    ;;
  idea)
    "${_dev_dir}/dev-idea.sh" "${1:-$DEV_LAST_CONTAINER}"
    ;;
  use)
    DEV_LAST_CONTAINER="${1:?'Usage: dev use <name>'}"
    echo "Using: ${DEV_LAST_CONTAINER}"
    ;;
  list)
    "${_dev_dir}/dev-list.sh"
    ;;
  install)
    "${_dev_dir}/dev-install.sh"
    ;;
  http*|https*)
    "${_dev_dir}/dev-issue.sh" "$_dev_cmd"
    DEV_LAST_CONTAINER=$(cat "/run/user/$(id -u)/dev-last-container" 2>/dev/null) || true
    ;;
  help|*)
    echo "Usage: dev {new|enter|delete|stop|start|see|cp|cpout|use|idea|list|install|<url>}"
    echo ""
    echo "  new <name>     Create and enter a new dev container"
    echo "  enter [name]   Enter an existing container"
    echo "  delete [name]  Remove a container"
    echo "  stop [name]    Stop a container"
    echo "  start [name]   Start a stopped container"
    echo "  see [name]     Sync changes to host and show diff"
    echo "  cp <path>      Copy files/dirs into container's /tmp/workspace"
    echo "  cpout <path>   Copy files/dirs from container to current dir"
    echo "  use <name>     Set current container without entering"
    echo "  idea [name]    Open container in IntelliJ IDEA via Gateway"
    echo "  list           List all dev containers"
    echo "  install        Install prerequisites and configure"
    echo "  <github-url>   Create/enter container for a GitHub issue/PR"
    ;;
esac

unset _dev_cmd _dev_dir 2>/dev/null
