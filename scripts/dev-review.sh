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
    echo "  --agent=claude|bob|agy          Agent to use (default: agy)"
    echo "  --model=flash|claude|pro        Model to use for the agent"
    echo '  --prompt "text"                 Replace agent-specific prompt (base kept)'
    echo '  --append-to-prompt "text"       Append to default prompt'
    echo "  -h, --help                      Show this help"
}

_devreview_agent="agy"
_devreview_model=""
_devreview_custom_prompt=""
_devreview_append=""
_devreview_positional=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent=*) _devreview_agent="${1#--agent=}"; shift ;;
        --agent)   _devreview_agent="${2:?'--agent requires a value (claude|bob|agy)'}"; shift 2 ;;
        --model=*) _devreview_model="${1#--model=}"; shift ;;
        --model)   _devreview_model="${2:?'--model requires a value'}"; shift 2 ;;
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
    DEV_SKIP_ENTER=1 _DEV_SHELL_PID="${_DEV_SHELL_PID:-}" "${DEV_SCRIPTS_DIR}/dev-issue.sh" "$_devreview_positional"
    _devreview_name=$(cat "/run/user/$(id -u)/dev-last-container.${_DEV_SHELL_PID:-}" 2>/dev/null) || true
    [[ -z "$_devreview_name" ]] && _devreview_name=$(cat "/run/user/$(id -u)/dev-last-container" 2>/dev/null) || true
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
[[ -n "${_DEV_SHELL_PID:-}" ]] && echo "$_devreview_name" > "/run/user/$(id -u)/dev-last-container.${_DEV_SHELL_PID}"

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

_devreview_run_agent() {
    local agent="$1"
    local model="$2"
    local session_file="/run/user/$(id -u)/dev-review-session-${_devreview_name}-${agent}"
    local agent_continue=""
    
    if [[ "$_devreview_mode" == "followup" && -f "$session_file" ]]; then
        local session_id=$(cat "$session_file")
        case "$agent" in
            claude) agent_continue="-r ${session_id}" ;;
            agy)    agent_continue="--conversation ${session_id}" ;;
            bob)    agent_continue="-r ${session_id}" ;;
        esac
    fi

    local ts=$(date +%Y%m%d-%H%M%S)
    local review_file="/workspace/.reviews/${agent}/${ts}.md"
    ssh -q "$_devreview_name" "mkdir -p /workspace/.reviews/${agent} && grep -qxF '.reviews' /workspace/.git/info/exclude 2>/dev/null || echo '.reviews' >> /workspace/.git/info/exclude"

    if [[ -n "$model" ]]; then
        echo "Running ${agent} review (model: ${model}) in '${_devreview_name}'..."
    else
        echo "Running ${agent} review in '${_devreview_name}'..."
    fi
    
    local model_arg=""
    if [[ -n "$model" ]]; then
        if [[ "$agent" != "agy" ]]; then
            echo "Error: --model option is only supported for the 'agy' agent" >&2
            exit 1
        fi
        
        # Map shortcuts to actual models with highest effort
        case "$model" in
            pro)    model="gemini-3.1-pro-high" ;;
            flash)  model="gemini-3.8-flash-high" ;;
            claude) model="claude-opus-4-6-thinking" ;;
        esac
        model_arg="--model ${model}"
    fi

    case "$agent" in
        claude)
            ssh -q "$_devreview_name" \
                "cd /workspace && claude ${agent_continue} -p --verbose --output-format stream-json \"\$(cat /tmp/dev-review-prompt.txt)\"" \
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
                        printf '%s' "$_devreview_line" | jq -r '.session_id // empty' > "${session_file}.tmp"
                        break
                        ;;
                esac
            done
            echo
            [[ -f "${session_file}.tmp" ]] && mv "${session_file}.tmp" "$session_file"
            scp -q "$_devreview_host_tmp.out" "${_devreview_name}:${review_file}" 2>/dev/null && \
                echo "Review saved to ${review_file}" >&2
            [[ -f "$session_file" ]] && echo "Session: $(cat "$session_file")" >&2
            ;;
        bob)
            ssh -qt "$_devreview_name" \
                "cd /workspace && bob run ${agent_continue} ${model_arg} -p \"\$(cat /tmp/dev-review-prompt.txt)\"" \
                | tee "$_devreview_host_tmp.out"
            sed -r 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$_devreview_host_tmp.out" | awk '/Task ID:/ {id=$NF} END {if (id) print id}' > "${session_file}.tmp"
            [[ -s "${session_file}.tmp" ]] && mv "${session_file}.tmp" "$session_file"
            scp -q "$_devreview_host_tmp.out" "${_devreview_name}:${review_file}" 2>/dev/null && \
                echo "Review saved to ${review_file}" >&2
            [[ -f "$session_file" ]] && echo "Session: $(cat "$session_file")" >&2
            ;;
        agy)
            ssh -qt "$_devreview_name" \
                "cd /workspace && exec agy ${agent_continue} ${model_arg} -p \"\$(cat /tmp/dev-review-prompt.txt)\"" \
                | tee "$_devreview_host_tmp.out"
            scp -q "$_devreview_host_tmp.out" "${_devreview_name}:${review_file}" 2>/dev/null && \
                echo "Review saved to ${review_file}" >&2
            ;;
    esac
}

_devreview_run_agent "$_devreview_agent" "$_devreview_model"

_dev_stop_if_was_stopped "$_devreview_name"
