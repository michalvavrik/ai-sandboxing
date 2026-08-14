#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devreview_usage() {
    echo "Usage: dev review [options] [url|container-name|follow-up-text]"
    echo ""
    echo "Run a headless AI review in a dev container."
    echo ""
    echo "Modes:"
    echo "  dev review <url>                Set up container from GitHub URL and review"
    echo "  dev review [container-name]     Run first review in named/current container"
    echo '  dev review "follow-up text"     Resume session with follow-up question'
    echo ""
    echo "Options:"
    echo "  --agent=claude|bob|agy          Agent to use (default: claude)"
    echo '  --prompt "text"                 Replace agent-specific prompt (base kept)'
    echo '  --append-to-prompt "text"       Append to default prompt'
    echo "  -h, --help                      Show this help"
}

_devreview_agent="claude"
_devreview_custom_prompt=""
_devreview_append=""
_devreview_positional=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent=*) _devreview_agent="${1#--agent=}"; shift ;;
        --agent)   _devreview_agent="${2:?'--agent requires a value (claude|bob|agy)'}"; shift 2 ;;
        --prompt)  _devreview_custom_prompt="${2:?'--prompt requires a value'}"; shift 2 ;;
        --append-to-prompt) _devreview_append="${2:?'--append-to-prompt requires a value'}"; shift 2 ;;
        --help|-h) _devreview_usage; exit 0 ;;
        *) _devreview_positional="$1"; shift ;;
    esac
done

case "$_devreview_agent" in
    claude|bob|agy) ;;
    *) echo "Error: unknown agent '${_devreview_agent}'. Use claude, bob, or agy." >&2; exit 1 ;;
esac

_devreview_mode="review"
_devreview_name=""

if [[ -z "$_devreview_positional" ]]; then
    _devreview_name=$(_dev_resolve_name "")

elif [[ "$_devreview_positional" =~ ^https?:// ]]; then
    DEV_SKIP_ENTER=1 "${DEV_SCRIPTS_DIR}/dev-issue.sh" "$_devreview_positional"
    _devreview_name=$(cat "/run/user/$(id -u)/dev-last-container" 2>/dev/null) || true
    if [[ -z "$_devreview_name" ]]; then
        echo "Error: container setup did not produce a container name" >&2
        exit 1
    fi

elif _dev_container_exists "$_devreview_positional"; then
    _devreview_name="$_devreview_positional"

else
    _devreview_mode="followup"
    _devreview_name=$(_dev_resolve_name "")
fi

echo "$_devreview_name" > "/run/user/$(id -u)/dev-last-container"

if ! _dev_container_exists "$_devreview_name"; then
    echo "Error: container '${_devreview_name}' does not exist" >&2
    exit 1
fi

_dev_ensure_running "$_devreview_name"

if [[ "$_devreview_mode" == "followup" ]]; then
    _devreview_prompt="$_devreview_positional"
else
    _devreview_base=""
    _devreview_base_file="${DEV_CONFIGS_DIR}/review-prompts/base.txt"
    if [[ -f "$_devreview_base_file" ]]; then
        _devreview_base=$(cat "$_devreview_base_file")
    fi

    if [[ -n "$_devreview_custom_prompt" ]]; then
        _devreview_agent_prompt="$_devreview_custom_prompt"
    else
        _devreview_agent_file="${DEV_CONFIGS_DIR}/review-prompts/${_devreview_agent}.txt"
        if [[ -f "$_devreview_agent_file" ]]; then
            _devreview_agent_prompt=$(cat "$_devreview_agent_file")
        else
            _devreview_agent_prompt="Review the code changes thoroughly."
        fi
    fi

    _devreview_prompt="${_devreview_base}

${_devreview_agent_prompt}"

    if [[ -n "$_devreview_append" ]]; then
        _devreview_prompt="${_devreview_prompt}

${_devreview_append}"
    fi
fi

_devreview_host_tmp=$(mktemp /tmp/dev-review-prompt.XXXXXX)
trap 'rm -f "$_devreview_host_tmp"' EXIT
printf '%s\n' "$_devreview_prompt" > "$_devreview_host_tmp"
scp -q "$_devreview_host_tmp" "${_devreview_name}:/tmp/dev-review-prompt.txt"

_devreview_continue=""
if [[ "$_devreview_mode" == "followup" ]]; then
    case "$_devreview_agent" in
        claude) _devreview_continue="-c" ;;
        agy)    _devreview_continue="--continue" ;;
    esac
fi

echo "Running ${_devreview_agent} review in '${_devreview_name}'..."
case "$_devreview_agent" in
    claude)
        _dev_ssh_cmd "$_devreview_name" \
            "cd /workspace && exec claude ${_devreview_continue} -p \"\$(cat /tmp/dev-review-prompt.txt)\""
        ;;
    bob)
        _dev_ssh_cmd "$_devreview_name" \
            "cd /workspace && exec bob -p \"\$(cat /tmp/dev-review-prompt.txt)\""
        ;;
    agy)
        _dev_ssh_cmd "$_devreview_name" \
            "cd /workspace && exec agy ${_devreview_continue} -p \"\$(cat /tmp/dev-review-prompt.txt)\""
        ;;
esac

_dev_stop_if_was_stopped "$_devreview_name"
