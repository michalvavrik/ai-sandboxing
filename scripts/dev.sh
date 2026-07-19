# Sourced via: alias dev="source /home/mvavrik/sandboxing/scripts/dev.sh"
_dev_cmd="${1:-help}"
shift 2>/dev/null || true

# Check token expiry on any container-related command (soft warning, non-blocking)
case "$_dev_cmd" in
  new|enter|start|see|http*|https*)
    (source /home/mvavrik/sandboxing/scripts/dev-common.sh; _dev_check_container_pat) || true
    ;;
esac

case "$_dev_cmd" in
  new)
    DEV_LAST_CONTAINER="${1:?'Usage: dev new <name>'}"
    /home/mvavrik/sandboxing/scripts/dev-new.sh "$@"
    ;;
  delete)
    /home/mvavrik/sandboxing/scripts/dev-delete.sh "${1:-$DEV_LAST_CONTAINER}"
    ;;
  enter)
    DEV_LAST_CONTAINER="${1:-$DEV_LAST_CONTAINER}"
    /home/mvavrik/sandboxing/scripts/dev-enter.sh "${DEV_LAST_CONTAINER:?'No container specified. Use: dev enter <name>'}"
    ;;
  stop)
    /home/mvavrik/sandboxing/scripts/dev-stop.sh "${1:-${DEV_LAST_CONTAINER:?'No container specified'}}"
    ;;
  start)
    DEV_LAST_CONTAINER="${1:-$DEV_LAST_CONTAINER}"
    /home/mvavrik/sandboxing/scripts/dev-start.sh "${DEV_LAST_CONTAINER:?'No container specified'}"
    ;;
  see)
    /home/mvavrik/sandboxing/scripts/dev-see.sh "${1:-${DEV_LAST_CONTAINER:?'No container specified'}}"
    ;;
  list)
    /home/mvavrik/sandboxing/scripts/dev-list.sh
    ;;
  install)
    /home/mvavrik/sandboxing/scripts/dev-install.sh
    ;;
  http*|https*)
    DEV_LAST_CONTAINER=""
    /home/mvavrik/sandboxing/scripts/dev-issue.sh "$_dev_cmd"
    ;;
  help|*)
    echo "Usage: dev {new|delete|enter|stop|start|see|list|install|<github-url>}"
    echo ""
    echo "  new <name>     Create and enter a new dev container"
    echo "  enter [name]   Enter an existing container"
    echo "  delete [name]  Remove a container"
    echo "  stop [name]    Stop a container"
    echo "  start [name]   Start a stopped container"
    echo "  see [name]     Sync changes to host and show diff"
    echo "  list           List all dev containers"
    echo "  install        Install prerequisites and configure"
    echo "  <github-url>   Create/enter container for a GitHub issue"
    ;;
esac

unset _dev_cmd 2>/dev/null
