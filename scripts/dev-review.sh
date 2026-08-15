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
trap 'rm -f "$_devreview_host_tmp" "$_devreview_host_tmp.out" "${_devreview_session_file}.tmp"' EXIT
printf '%s\n' "$_devreview_prompt" > "$_devreview_host_tmp"
scp -q "$_devreview_host_tmp" "${_devreview_name}:/tmp/dev-review-prompt.txt"

_devreview_session_file="/run/user/$(id -u)/dev-review-session-${_devreview_name}-${_devreview_agent}"
_devreview_continue=""
if [[ "$_devreview_mode" == "followup" && -f "$_devreview_session_file" ]]; then
    _devreview_session_id=$(cat "$_devreview_session_file")
    case "$_devreview_agent" in
        claude) _devreview_continue="-r ${_devreview_session_id}" ;;
        agy)    _devreview_continue="--conversation ${_devreview_session_id}" ;;
    esac
fi

_devreview_ts=$(date +%Y%m%d-%H%M%S)
_devreview_review_file="/workspace/.reviews/${_devreview_agent}/${_devreview_ts}.md"
ssh -q "$_devreview_name" "mkdir -p /workspace/.reviews/${_devreview_agent} && grep -qxF '.reviews' /workspace/.git/info/exclude 2>/dev/null || echo '.reviews' >> /workspace/.git/info/exclude"

echo "Running ${_devreview_agent} review in '${_devreview_name}'..."
_devreview_header_shown=false
case "$_devreview_agent" in
    claude)
        ssh -q "$_devreview_name" \
            "cd /workspace && claude ${_devreview_continue} -p --verbose --output-format stream-json \"\$(cat /tmp/dev-review-prompt.txt)\"" \
            < /dev/null \
        | while IFS= read -r _devreview_line; do
            _devreview_evt=$(printf '%s' "$_devreview_line" | jq -r '.type // empty' 2>/dev/null) || continue
            case "$_devreview_evt" in
                system)
                    _devreview_sub=$(printf '%s' "$_devreview_line" | jq -r '.subtype // empty' 2>/dev/null)
                    [[ "$_devreview_sub" == "init" ]] && printf '  ⚡ agent ready\n' >&2
                    ;;
                assistant)
                    _devreview_ct=$(printf '%s' "$_devreview_line" | jq -r '.message.content[-1].type // empty' 2>/dev/null)
                    case "$_devreview_ct" in
                        tool_use)
                            _devreview_tool=$(printf '%s' "$_devreview_line" | jq -r '.message.content[-1].name // empty' 2>/dev/null)
                            _devreview_input=$(printf '%s' "$_devreview_line" | jq -r '(.message.content[-1].input.command // .message.content[-1].input.file_path // .message.content[-1].input.query // "") | tostring | .[0:120]' 2>/dev/null)
                            printf '  → %s %s\n' "$_devreview_tool" "$_devreview_input" >&2
                            ;;
                        thinking)
                            _devreview_thought=$(printf '%s' "$_devreview_line" | jq -r '.message.content[-1].thinking // empty' 2>/dev/null)
                            [[ -n "$_devreview_thought" ]] && printf '  ✦ %s\n' "$_devreview_thought" >&2
                            ;;
                        text)
                            printf '%s' "$_devreview_line" | jq -r '.message.content[-1].text // empty' 2>/dev/null >&2
                            ;;
                    esac
                    ;;
                result)
                    printf '\n════════════════════ REVIEW ════════════════════\n\n' >&2
                    printf '%s' "$_devreview_line" | jq -r '.result // empty' | tee "$_devreview_host_tmp.out"
                    printf '%s' "$_devreview_line" | jq -r '.session_id // empty' > "${_devreview_session_file}.tmp"
                    break
                    ;;
            esac
        done
        echo
        [[ -f "${_devreview_session_file}.tmp" ]] && mv "${_devreview_session_file}.tmp" "$_devreview_session_file"
        scp -q "$_devreview_host_tmp.out" "${_devreview_name}:${_devreview_review_file}" 2>/dev/null && \
            echo "Review saved to ${_devreview_review_file}" >&2
        ;;
    bob)
        ssh -qt "$_devreview_name" \
            "cd /workspace && bob -p \"\$(cat /tmp/dev-review-prompt.txt)\"" \
            | tee "$_devreview_host_tmp.out"
        scp -q "$_devreview_host_tmp.out" "${_devreview_name}:${_devreview_review_file}" 2>/dev/null && \
            echo "Review saved to ${_devreview_review_file}" >&2
        ;;
    agy)
        ssh -q "$_devreview_name" \
            "cd /workspace && agy ${_devreview_continue} -p --verbose --output-format stream-json \"\$(cat /tmp/dev-review-prompt.txt)\"" \
            < /dev/null \
        | while IFS= read -r _devreview_line; do
            _devreview_evt=$(printf '%s' "$_devreview_line" | jq -r '.type // empty' 2>/dev/null) || continue
            case "$_devreview_evt" in
                system)
                    _devreview_sub=$(printf '%s' "$_devreview_line" | jq -r '.subtype // empty' 2>/dev/null)
                    [[ "$_devreview_sub" == "init" ]] && printf '  ⚡ agent ready\n' >&2
                    ;;
                assistant)
                    _devreview_ct=$(printf '%s' "$_devreview_line" | jq -r '.message.content[-1].type // empty' 2>/dev/null)
                    case "$_devreview_ct" in
                        tool_use)
                            _devreview_tool=$(printf '%s' "$_devreview_line" | jq -r '.message.content[-1].name // empty' 2>/dev/null)
                            _devreview_input=$(printf '%s' "$_devreview_line" | jq -r '(.message.content[-1].input.command // .message.content[-1].input.file_path // .message.content[-1].input.query // "") | tostring | .[0:120]' 2>/dev/null)
                            printf '  → %s %s\n' "$_devreview_tool" "$_devreview_input" >&2
                            ;;
                        thinking)
                            _devreview_thought=$(printf '%s' "$_devreview_line" | jq -r '.message.content[-1].thinking // empty' 2>/dev/null)
                            [[ -n "$_devreview_thought" ]] && printf '  ✦ %s\n' "$_devreview_thought" >&2
                            ;;
                        text)
                            printf '%s' "$_devreview_line" | jq -r '.message.content[-1].text // empty' 2>/dev/null >&2
                            ;;
                    esac
                    ;;
                result)
                    printf '\n════════════════════ REVIEW ════════════════════\n\n' >&2
                    printf '%s' "$_devreview_line" | jq -r '.result // empty' | tee "$_devreview_host_tmp.out"
                    printf '%s' "$_devreview_line" | jq -r '.session_id // empty' > "${_devreview_session_file}.tmp"
                    break
                    ;;
            esac
        done
        echo
        [[ -f "${_devreview_session_file}.tmp" ]] && mv "${_devreview_session_file}.tmp" "$_devreview_session_file"
        scp -q "$_devreview_host_tmp.out" "${_devreview_name}:${_devreview_review_file}" 2>/dev/null && \
            echo "Review saved to ${_devreview_review_file}" >&2
        ;;
esac

_dev_stop_if_was_stopped "$_devreview_name"
