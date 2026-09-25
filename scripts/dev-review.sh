#!/bin/bash
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/dev-common.sh"

_devreview_usage() {
    echo "Usage: dev review [options] [url|container-name|follow-up-text]"
    echo "       dev <github-url> --loop[=profile|list] [options]"
    echo ""
    echo "Run a headless AI review in a dev container."
    echo ""
    echo "Modes:"
    echo "  dev review <url>                Set up container from GitHub URL and review"
    echo "  dev review [container-name]     Run first review in named/current container"
    echo '  dev review "follow-up text"     Resume session with follow-up question'
    echo ""
    echo "Options:"
    echo "  --agent=claude|bob|agy          Agent to use (default: claude; flash/pro imply agy)"
    echo "  --model=opus|fable|flash|pro    opus/fable for claude (latest of each family),"
    echo "                                  flash/pro for agy (latest, highest effort)"
    echo "  --loop[=normal|best|all|list]   Several reviewers in sequence; each does its own"
    echo "                                  review, then fact-checks the previous ones."
    echo "                                    normal  ${DEV_LOOP_NORMAL:-bob,flash,opus}   (default)"
    echo "                                    best    ${DEV_LOOP_BEST:-opus,pro,fable}"
    echo "                                    all     ${DEV_LOOP_ALL:-bob,pro,opus,flash,fable}"
    echo "                                  list: comma-separated bob|flash|pro|opus|fable"
    echo "                                  (gemini = flash, claude = opus, profiles may be"
    echo "                                  mixed in, e.g. --loop=normal,fable)"
    echo '  --prompt "text"                 Replace agent-specific prompt (base kept)'
    echo '  --append-to-prompt "text"       Append to default prompt'
    echo "  -h, --help                      Show this help"
}

_devreview_agent="claude"
_devreview_agent_set=false
_devreview_model=""
_devreview_loop=""
_devreview_custom_prompt=""
_devreview_append=""
_devreview_positional=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent=*) _devreview_agent="${1#--agent=}"; _devreview_agent_set=true; shift ;;
        --agent)   _devreview_agent="${2:?'--agent requires a value (claude|bob|agy)'}"; _devreview_agent_set=true; shift 2 ;;
        --model=*) _devreview_model="${1#--model=}"; shift ;;
        --model)   _devreview_model="${2:?'--model requires a value'}"; shift 2 ;;
        --loop)    _devreview_loop="normal"; shift ;;
        --loop=*)  _devreview_loop="${1#--loop=}"; [[ -n "$_devreview_loop" ]] || _devreview_loop="normal"; shift ;;
        --prompt)  _devreview_custom_prompt="${2:?'--prompt requires a value'}"; shift 2 ;;
        --append-to-prompt) _devreview_append="${2:?'--append-to-prompt requires a value'}"; shift 2 ;;
        --help|-h) _devreview_usage; exit 0 ;;
        *) _devreview_positional="$1"; shift ;;
    esac
done

# --model=flash|pro without --agent means the agy agent.
if [[ "$_devreview_agent_set" == false ]]; then
    case "$_devreview_model" in
        flash|pro) _devreview_agent="agy" ;;
    esac
fi

case "$_devreview_agent" in
    claude|bob|agy) ;;
    *) echo "Error: unknown agent '${_devreview_agent}'. Use claude, bob, or agy." >&2; exit 1 ;;
esac

# Model shortcut validation per agent (opus/claude with agy is the legacy
# "Claude through Antigravity" option).
_devreview_check_model() {
    local _agent="$1" _model="$2"
    case "$_agent" in
        claude)
            case "$_model" in
                ""|opus|fable) ;;
                *) echo "Error: --model for claude must be opus or fable (got '${_model}')" >&2; return 1 ;;
            esac
            ;;
        agy)
            case "$_model" in
                ""|flash|pro|opus|claude) ;;
                *) echo "Error: --model for agy must be flash or pro (got '${_model}')" >&2; return 1 ;;
            esac
            ;;
        bob)
            if [[ -n "$_model" ]]; then
                echo "Error: bob does not support --model (got '${_model}')" >&2
                return 1
            fi
            ;;
    esac
}

_devreview_profile() {
    case "$1" in
        normal) echo "${DEV_LOOP_NORMAL:-bob,flash,opus}" ;;
        best)   echo "${DEV_LOOP_BEST:-opus,pro,fable}" ;;
        all)    echo "${DEV_LOOP_ALL:-bob,pro,opus,flash,fable}" ;;
        *) return 1 ;;
    esac
}

# Expand a --loop spec into "agent<TAB>model" lines, in order.
_devreview_expand_loop() {
    local _spec="$1" _tok _agent _model _profile
    local IFS=','
    for _tok in $_spec; do
        [[ -z "$_tok" ]] && continue
        if _profile=$(_devreview_profile "$_tok"); then
            _devreview_expand_loop "$_profile" || return 1
            continue
        fi
        _agent="${_tok%%:*}"
        _model=""
        [[ "$_tok" == *:* ]] && _model="${_tok#*:}"
        case "$_agent" in
            bob) ;;
            agy|gemini) _agent="agy"; _model="${_model:-flash}" ;;
            flash|pro)  _model="$_agent"; _agent="agy" ;;
            claude)     _model="${_model:-opus}" ;;
            opus|fable) _model="$_agent"; _agent="claude" ;;
            *)
                echo "Error: unknown loop entry '${_tok}' (use bob, flash, pro, opus, fable or a profile: normal, best, all)" >&2
                return 1
                ;;
        esac
        _devreview_check_model "$_agent" "$_model" || return 1
        printf '%s\t%s\n' "$_agent" "$_model"
    done
}

_devreview_steps=()
if [[ -n "$_devreview_loop" ]]; then
    mapfile -t _devreview_steps < <(_devreview_expand_loop "$_devreview_loop") || exit 1
    if [[ ${#_devreview_steps[@]} -eq 0 ]]; then
        echo "Error: --loop='${_devreview_loop}' expands to no reviewers" >&2
        exit 1
    fi
    if [[ "$_devreview_agent_set" == true || -n "$_devreview_model" ]]; then
        echo "Error: --loop cannot be combined with --agent/--model (put the models in the loop list)" >&2
        exit 1
    fi
else
    _devreview_check_model "$_devreview_agent" "$_devreview_model" || exit 1
    _devreview_steps=("${_devreview_agent}	${_devreview_model}")
fi

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

if ! _dev_container_exists "$_devreview_name"; then
    echo "Error: container '${_devreview_name}' does not exist" >&2
    exit 1
fi
_dev_remember_container "$_devreview_name"

if [[ "$_devreview_mode" == "followup" && -n "$_devreview_loop" ]]; then
    echo "Error: --loop cannot be used with a follow-up question (use --agent to pick whose session to continue)" >&2
    exit 1
fi

_dev_ensure_running "$_devreview_name"

_devreview_auth=$(podman inspect --format '{{index .Config.Labels "dev-auth-method"}}' "$_devreview_name" 2>/dev/null) || true
[[ "$_devreview_auth" == "api-key" ]] || _devreview_auth="vertex"

# ── Model resolution ──────────────────────────────────────────────────────────

# Claude: the opus/fable aliases resolve to the latest model of the family via
# the subscription. On Vertex the alias may point at a model the project cannot
# use, so the configured Vertex model is passed explicitly instead.
_devreview_claude_model_arg() {
    local _want="$1" _m
    [[ -z "$_want" ]] && return 0
    if [[ "$_devreview_auth" == "vertex" ]]; then
        if ! _m=$(_dev_vertex_model "$_want"); then
            echo "Error: no Vertex model configured for '${_want}' (set DEV_VERTEX_$(tr '[:lower:]' '[:upper:]' <<< "$_want")_MODEL in config.local)" >&2
            return 1
        fi
    else
        _m="$_want"
    fi
    printf -- "--model '%s'" "$_m"
}

# Antigravity: flash/pro mean the newest Gemini Flash/Pro at the highest effort.
# DEV_AGY_FLASH_MODEL / DEV_AGY_PRO_MODEL in config.local pin a model; otherwise
# the newest matching entry of `agy models` in the container is used, falling
# back to a built-in default.
_devreview_agy_models=""
_devreview_agy_model() {
    local _kind="$1" _default="" _pinned="" _found=""
    case "$_kind" in
        flash) _pinned="${DEV_AGY_FLASH_MODEL:-}"; _default="gemini-3.8-flash-high" ;;
        pro)   _pinned="${DEV_AGY_PRO_MODEL:-}";   _default="gemini-3.1-pro-high" ;;
        opus|claude) echo "${DEV_AGY_CLAUDE_MODEL:-claude-opus-4-6-thinking}"; return 0 ;;
        *) echo "$_kind"; return 0 ;;
    esac
    if [[ -n "$_pinned" ]]; then
        echo "$_pinned"
        return 0
    fi
    if [[ -z "$_devreview_agy_models" ]]; then
        _devreview_agy_models=$(ssh -q "$_devreview_name" "agy models 2>/dev/null" </dev/null 2>/dev/null | tr -d '\r') || true
        [[ -n "$_devreview_agy_models" ]] || _devreview_agy_models="(unavailable)"
    fi
    _found=$(printf '%s\n' "$_devreview_agy_models" \
        | grep -oiE "gemini-[0-9]+(\.[0-9]+)?-${_kind}-high" | tr '[:upper:]' '[:lower:]' | sort -uV | tail -n1) || true
    if [[ -z "$_found" ]]; then
        _found=$(printf '%s\n' "$_devreview_agy_models" \
            | grep -oiE "gemini [0-9]+(\.[0-9]+)? ${_kind} \(high\)" | tr '[:upper:]' '[:lower:]' \
            | sed -E 's/gemini ([0-9.]+) ([a-z]+) \(high\)/gemini-\1-\2-high/' | sort -uV | tail -n1) || true
    fi
    echo "${_found:-$_default}"
}

# Antigravity signs in interactively on first use (prints a Google URL, waits
# for the code). Do that before the loop starts so nobody has to wait for an
# earlier reviewer to finish just to paste a code; later runs reuse the token.
_devreview_agy_signed_in() {
    ssh -q "$_devreview_name" \
        'ls /home/dev/.gemini/antigravity-cli/*oauth*token* >/dev/null 2>&1 || agy models >/dev/null 2>&1' </dev/null
}

_devreview_agy_ensure_auth() {
    if _devreview_agy_signed_in; then
        return 0
    fi
    echo "Antigravity CLI is not signed in yet in '${_devreview_name}' — sign in now, the review continues unattended afterwards."
    ssh -qt "$_devreview_name" "cd /workspace && agy -p 'Reply with exactly: OK'" || true
    if ! _devreview_agy_signed_in; then
        echo "Error: Antigravity CLI sign-in did not complete" >&2
        return 1
    fi
}

_devreview_needs_agy=false
for _devreview_step in "${_devreview_steps[@]}"; do
    [[ "${_devreview_step%%	*}" == "agy" ]] && _devreview_needs_agy=true
done
if [[ "$_devreview_needs_agy" == true ]]; then
    _devreview_agy_ensure_auth || exit 1
fi

# ── Prompt ────────────────────────────────────────────────────────────────────
_devreview_base=""
_devreview_base_file="${DEV_CONFIGS_DIR}/review-prompts/base.txt"
if [[ -f "$_devreview_base_file" ]]; then
    _devreview_base=$(cat "$_devreview_base_file")
fi
_devreview_loop_tpl=""
_devreview_loop_file="${DEV_CONFIGS_DIR}/review-prompts/loop.txt"
if [[ -f "$_devreview_loop_file" ]]; then
    _devreview_loop_tpl=$(cat "$_devreview_loop_file")
fi

# Human-readable label for a step, e.g. "claude (opus)" or "bob".
_devreview_step_label() {
    local _agent="$1" _model="$2"
    if [[ -n "$_model" ]]; then
        echo "${_agent} (${_model})"
    else
        echo "$_agent"
    fi
}

# Prompt for one step. Loop steps get the loop section with the list of
# reviews written so far; every step is told the exact file to write.
_devreview_build_prompt() {
    local _agent="$1" _model="$2" _step="$3" _total="$4" _review_file="$5"
    local _previous="${6:-}"
    local _agent_prompt _prompt _loop_text _loop_desc="" _self

    if [[ "$_devreview_mode" == "followup" ]]; then
        printf '%s\n' "$_devreview_positional"
        return 0
    fi

    if [[ -n "$_devreview_custom_prompt" ]]; then
        _agent_prompt="$_devreview_custom_prompt"
    elif [[ -f "${DEV_CONFIGS_DIR}/review-prompts/${_agent}.txt" ]]; then
        _agent_prompt=$(cat "${DEV_CONFIGS_DIR}/review-prompts/${_agent}.txt")
    else
        _agent_prompt="Review the code changes thoroughly."
    fi

    _prompt="${_devreview_base}

${_agent_prompt}"

    if [[ -n "$_devreview_loop" ]]; then
        local _s
        for _s in "${_devreview_steps[@]}"; do
            _loop_desc="${_loop_desc:+${_loop_desc} → }$(_devreview_step_label "${_s%%	*}" "${_s#*	}")"
        done
        _self=$(_devreview_step_label "$_agent" "$_model")
        [[ -n "$_previous" ]] || _previous="(none — you are the first reviewer in this loop, so there is nothing to verify in step 2 and no verification section is needed)"
        _loop_text="$_devreview_loop_tpl"
        _loop_text="${_loop_text//\{\{STEP\}\}/"$_step"}"
        _loop_text="${_loop_text//\{\{TOTAL\}\}/"$_total"}"
        _loop_text="${_loop_text//\{\{LOOP\}\}/"$_loop_desc"}"
        _loop_text="${_loop_text//\{\{SELF\}\}/"$_self"}"
        _loop_text="${_loop_text//\{\{PREVIOUS\}\}/"$_previous"}"
        _loop_text="${_loop_text//\{\{REVIEW_FILE\}\}/"$_review_file"}"
        _prompt="${_prompt}

${_loop_text}"
    else
        _prompt="${_prompt}

Write the complete review to ${_review_file} (this exact path replaces the path from the output-format section)."
    fi

    if [[ -n "$_devreview_append" ]]; then
        _prompt="${_prompt}

${_devreview_append}"
    fi
    printf '%s\n' "$_prompt"
}

# ── Running an agent ──────────────────────────────────────────────────────────
_devreview_session_file=""
_devreview_host_tmp=$(mktemp /tmp/dev-review-prompt.XXXXXX)
trap 'rm -f "$_devreview_host_tmp" "$_devreview_host_tmp.out" 2>/dev/null; [[ -n "$_devreview_session_file" ]] && rm -f "${_devreview_session_file}.tmp" 2>/dev/null' EXIT

# _devreview_run_agent <agent> <model-shortcut> <review-file> <prompt-text>
# Runs one review, streams progress, stores the session id for follow-ups and
# makes sure the review file exists in the container (the agent is asked to
# write it; the captured output is saved there when it did not).
_devreview_run_agent() {
    local agent="$1"
    local model="$2"
    local review_file="$3"
    local prompt="$4"
    local session_file="/run/user/$(id -u)/dev-review-session-${_devreview_name}-${agent}"
    _devreview_session_file="$session_file"
    local agent_continue=""
    local model_arg=""
    local model_id=""
    local rc=0

    if [[ "$_devreview_mode" == "followup" && -f "$session_file" ]]; then
        local session_id
        session_id=$(cat "$session_file")
        case "$agent" in
            claude) agent_continue="-r ${session_id}" ;;
            agy)    agent_continue="--conversation ${session_id}" ;;
            bob)    agent_continue="-r ${session_id}" ;;
        esac
    fi

    case "$agent" in
        claude)
            model_arg=$(_devreview_claude_model_arg "$model") || return 1
            ;;
        agy)
            if [[ -n "$model" ]]; then
                model_id=$(_devreview_agy_model "$model")
                model_arg="--model ${model_id}"
            fi
            ;;
    esac

    printf '%s\n' "$prompt" > "$_devreview_host_tmp"
    scp -q "$_devreview_host_tmp" "${_devreview_name}:/tmp/dev-review-prompt.txt"
    rm -f "$_devreview_host_tmp.out"

    ssh -q "$_devreview_name" "mkdir -p '$(dirname "$review_file")' && grep -qxF '.reviews' /workspace/.git/info/exclude 2>/dev/null || echo '.reviews' >> /workspace/.git/info/exclude" </dev/null

    if [[ -n "$model" ]]; then
        echo "Running ${agent} review (model: ${model}${model_id:+ = ${model_id}}) in '${_devreview_name}'..."
    else
        echo "Running ${agent} review in '${_devreview_name}'..."
    fi

    case "$agent" in
        claude)
            ssh -q "$_devreview_name" \
                "cd /workspace && claude ${agent_continue} ${model_arg} -p --verbose --output-format stream-json \"\$(cat /tmp/dev-review-prompt.txt)\"" \
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
            done || true
            echo
            [[ -s "$_devreview_host_tmp.out" ]] || rc=1
            [[ -s "${session_file}.tmp" ]] && mv "${session_file}.tmp" "$session_file"
            ;;
        bob)
            ssh -qt "$_devreview_name" \
                "cd /workspace && bob run ${agent_continue} -p \"\$(cat /tmp/dev-review-prompt.txt)\"" \
                | tee "$_devreview_host_tmp.out" || rc=1
            sed -r 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$_devreview_host_tmp.out" | awk '/Task ID:/ {id=$NF} END {if (id) print id}' > "${session_file}.tmp"
            [[ -s "${session_file}.tmp" ]] && mv "${session_file}.tmp" "$session_file"
            ;;
        agy)
            ssh -qt "$_devreview_name" \
                "cd /workspace && exec agy ${agent_continue} ${model_arg} -p \"\$(cat /tmp/dev-review-prompt.txt)\"" \
                | tee "$_devreview_host_tmp.out" || rc=1
            ;;
    esac
    rm -f "${session_file}.tmp"

    if [[ -s "$_devreview_host_tmp.out" ]]; then
        if ssh -q "$_devreview_name" "test -s '${review_file}'" </dev/null; then
            echo "Review saved to ${review_file}" >&2
        elif scp -q "$_devreview_host_tmp.out" "${_devreview_name}:${review_file}" 2>/dev/null; then
            echo "Review saved to ${review_file}" >&2
        fi
    fi
    [[ -f "$session_file" ]] && echo "Session: $(cat "$session_file")" >&2
    return "$rc"
}

# ── Run ───────────────────────────────────────────────────────────────────────
_devreview_total=${#_devreview_steps[@]}
_devreview_previous=""
_devreview_results=()
_devreview_failed=0
_devreview_i=0

for _devreview_step in "${_devreview_steps[@]}"; do
    _devreview_i=$(( _devreview_i + 1 ))
    _devreview_s_agent="${_devreview_step%%	*}"
    _devreview_s_model="${_devreview_step#*	}"
    _devreview_s_label=$(_devreview_step_label "$_devreview_s_agent" "$_devreview_s_model")
    _devreview_s_file="/workspace/.reviews/${_devreview_s_agent}/$(date +%Y%m%d-%H%M%S)${_devreview_s_model:+-${_devreview_s_model}}.md"

    if [[ "$_devreview_s_agent" == "claude" && "$_devreview_auth" == "vertex" && -n "$_devreview_s_model" ]] \
        && ! _dev_vertex_model "$_devreview_s_model" >/dev/null; then
        echo "Skipping ${_devreview_s_label}: no Vertex model configured for '${_devreview_s_model}' (set DEV_VERTEX_$(tr '[:lower:]' '[:upper:]' <<< "$_devreview_s_model")_MODEL in config.local, or use --auth-method=api-key)" >&2
        _devreview_results+=("${_devreview_s_label}	skipped	")
        continue
    fi

    if (( _devreview_total > 1 )); then
        echo ""
        echo "═══ Loop step ${_devreview_i}/${_devreview_total}: ${_devreview_s_label} ═══"
    fi

    _devreview_prompt=$(_devreview_build_prompt "$_devreview_s_agent" "$_devreview_s_model" \
        "$_devreview_i" "$_devreview_total" "$_devreview_s_file" "$_devreview_previous")

    if _devreview_run_agent "$_devreview_s_agent" "$_devreview_s_model" "$_devreview_s_file" "$_devreview_prompt"; then
        _devreview_results+=("${_devreview_s_label}	ok	${_devreview_s_file}")
        _devreview_previous="${_devreview_previous:+${_devreview_previous}
}- ${_devreview_s_label}: ${_devreview_s_file}"
    else
        echo "WARNING: ${_devreview_s_label} review failed" >&2
        _devreview_failed=$(( _devreview_failed + 1 ))
        _devreview_results+=("${_devreview_s_label}	FAILED	")
    fi
done

if (( _devreview_total > 1 )); then
    echo ""
    echo "════════════════════ LOOP SUMMARY ════════════════════"
    _devreview_i=0
    for _devreview_r in "${_devreview_results[@]}"; do
        _devreview_i=$(( _devreview_i + 1 ))
        IFS='	' read -r _devreview_r_label _devreview_r_status _devreview_r_file <<< "$_devreview_r"
        printf '  %d. %-16s %-8s %s\n' "$_devreview_i" "$_devreview_r_label" "$_devreview_r_status" "$_devreview_r_file"
    done
fi

_dev_stop_if_was_stopped "$_devreview_name"

(( _devreview_failed == 0 ))
