#!/bin/bash
set -euo pipefail

readonly DEV_AUTOMATION_USER="michalvavrik-dev-automation"
readonly DEV_SCRIPTS_DIR="/home/mvavrik/sandboxing/scripts"
readonly DEV_BASE_DIR="/home/mvavrik/sandboxing"
readonly DEV_KEYS_DIR="/home/mvavrik/sandboxing/keys"
readonly DEV_CONFIGS_DIR="/home/mvavrik/sandboxing/configs"
readonly DEV_IMAGE="ghcr.io/michalvavrik/ai-sandboxing/dev-sandbox:latest"
readonly DEV_LABEL="dev-sandbox"
readonly DEV_RUNTIME="krun"
readonly DEV_DEFAULT_RAM=8192
readonly DEV_DEFAULT_CPUS=4

_dev_pid_file() {
    echo "/run/user/$(id -u)/dev-proxy.pid"
}

_dev_port_file() {
    echo "/run/user/$(id -u)/dev-proxy.port"
}

_dev_resolve_name() {
    local _dev_name="${1:-${DEV_LAST_CONTAINER:-}}"
    if [[ -z "$_dev_name" ]]; then
        local _dev_all
        _dev_all=$(podman ps -a --filter="label=${DEV_LABEL}" --format '{{.Names}}' 2>/dev/null)
        if [[ $(echo "$_dev_all" | wc -l) -eq 1 && -n "$_dev_all" ]]; then
            _dev_name="$_dev_all"
        else
            echo "Error: no container specified and multiple (or zero) exist. Use 'dev use <name>' first." >&2
            return 1
        fi
    fi
    echo "$_dev_name"
}

_dev_ensure_proxy() {
    local _dev_pf _dev_ptf
    _dev_pf="$(_dev_pid_file)"
    _dev_ptf="$(_dev_port_file)"

    if [[ -f "$_dev_pf" ]] && kill -0 "$(cat "$_dev_pf")" 2>/dev/null; then
        return 0
    fi

    echo "Starting vertex proxy..."
    DEV_PROXY_PID_FILE="$_dev_pf" DEV_PROXY_PORT_FILE="$_dev_ptf" \
        python3 "${DEV_SCRIPTS_DIR}/vertex-proxy.py" 2>/dev/null &
    disown

    local _dev_wait=0
    while [[ ! -f "$_dev_ptf" ]] && (( _dev_wait < 10 )); do
        sleep 1
        _dev_wait=$(( _dev_wait + 1 ))
    done

    if [[ ! -f "$_dev_ptf" ]]; then
        echo "Error: proxy did not write port file within 10s" >&2
        return 1
    fi
}

_dev_maybe_stop_proxy() {
    local _dev_count
    _dev_count=$(podman ps -a --filter="label=${DEV_LABEL}" --format "{{.Names}}" 2>/dev/null | wc -l)

    if (( _dev_count == 0 )); then
        local _dev_pf _dev_ptf
        _dev_pf="$(_dev_pid_file)"
        _dev_ptf="$(_dev_port_file)"

        if [[ -f "$_dev_pf" ]]; then
            kill "$(cat "$_dev_pf")" 2>/dev/null || true
            rm -f "$_dev_pf" "$_dev_ptf"
            echo "Proxy stopped (no dev containers remain)."
        fi
    fi
}

_dev_proxy_port() {
    local _dev_ptf
    _dev_ptf="$(_dev_port_file)"

    if [[ ! -f "$_dev_ptf" ]]; then
        echo "Error: proxy not running (no port file)" >&2
        return 1
    fi
    cat "$_dev_ptf"
}

_dev_container_exists() {
    local _dev_name="$1"
    podman container exists "$_dev_name" 2>/dev/null
}

_dev_container_running() {
    local _dev_name="$1"
    local _dev_state
    _dev_state=$(podman inspect --format '{{.State.Running}}' "$_dev_name" 2>/dev/null) || return 1
    [[ "$_dev_state" == "true" ]]
}

_dev_lookup_template() {
    local _dev_key="$1"
    local _dev_conf="${DEV_CONFIGS_DIR}/project-templates.conf"
    local _dev_line _dev_default=""

    while IFS= read -r _dev_line; do
        [[ "$_dev_line" =~ ^[[:space:]]*# || -z "$_dev_line" ]] && continue
        if [[ "$_dev_line" =~ ^DEFAULT\| ]]; then
            _dev_default="$_dev_line"
            continue
        fi
        local _dev_tmpl_key="${_dev_line%%|*}"
        if [[ "$_dev_tmpl_key" == "$_dev_key" ]]; then
            echo "${_dev_line#*|}"
            return 0
        fi
    done < "$_dev_conf"

    if [[ -n "$_dev_default" ]]; then
        echo "${_dev_default#*|}"
        return 0
    fi

    return 1
}

_dev_create_container() {
    local _dev_name="$1"
    local _dev_template_key="${2:-}"

    _dev_check_container_pat || return 1

    if [[ ! "$_dev_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        echo "Error: invalid container name '${_dev_name}'" >&2
        echo "Names must start with a letter/digit and contain only [a-zA-Z0-9._-]" >&2
        return 1
    fi

    if _dev_container_exists "$_dev_name"; then
        echo "Error: container '${_dev_name}' already exists" >&2
        echo "Use 'dev enter ${_dev_name}' or 'dev delete ${_dev_name}' first." >&2
        return 1
    fi

    # Resolve template: explicit key > cwd detection > name heuristic > DEFAULT
    if [[ -z "$_dev_template_key" ]]; then
        _dev_template_key=$(_dev_detect_template_from_cwd) || true
    fi

    if [[ -z "$_dev_template_key" ]]; then
        local _dev_best_key="" _dev_best_len=0 _dev_tline _dev_tkey _dev_trepo
        while IFS= read -r _dev_tline; do
            [[ "$_dev_tline" =~ ^[[:space:]]*# || -z "$_dev_tline" ]] && continue
            [[ "$_dev_tline" =~ ^DEFAULT\| ]] && continue
            _dev_tkey="${_dev_tline%%|*}"
            _dev_trepo="${_dev_tkey#*/}"
            if [[ "$_dev_name" == "$_dev_trepo" || "$_dev_name" == "${_dev_trepo}-"* ]]; then
                if (( ${#_dev_trepo} > _dev_best_len )); then
                    _dev_best_key="$_dev_tkey"
                    _dev_best_len=${#_dev_trepo}
                fi
            fi
        done < "${DEV_CONFIGS_DIR}/project-templates.conf"
        _dev_template_key="${_dev_best_key:-}"
    fi

    local _dev_source_dir="" _dev_ram="$DEV_DEFAULT_RAM" _dev_cpus="$DEV_DEFAULT_CPUS"

    if [[ -n "$_dev_template_key" ]]; then
        local _dev_tmpl
        _dev_tmpl=$(_dev_lookup_template "$_dev_template_key") || true
        if [[ -n "$_dev_tmpl" ]]; then
            IFS='|' read -r _dev_source_dir _dev_ram _dev_cpus <<< "$_dev_tmpl"
            echo "Matched template: ${_dev_template_key} (RAM=${_dev_ram}MiB, CPUs=${_dev_cpus})"
        fi
    else
        local _dev_tmpl
        _dev_tmpl=$(_dev_lookup_template "DEFAULT") || true
        if [[ -n "$_dev_tmpl" ]]; then
            IFS='|' read -r _dev_source_dir _dev_ram _dev_cpus <<< "$_dev_tmpl"
        fi
        echo "Using default template (RAM=${_dev_ram}MiB, CPUs=${_dev_cpus})"
    fi

    _dev_ensure_proxy
    local _dev_port
    _dev_port=$(_dev_proxy_port)

    # Warn if image is stale (>4 days old)
    local _dev_img_date
    _dev_img_date=$(podman image inspect "$DEV_IMAGE" --format '{{.Created}}' 2>/dev/null | cut -d' ' -f1) || true
    if [[ -n "$_dev_img_date" ]]; then
        local _dev_age=$(( ($(date +%s) - $(date -d "$_dev_img_date" +%s)) / 86400 ))
        if (( _dev_age > 4 )); then
            echo "WARNING: dev image is ${_dev_age} days old. Check if background pull is working." >&2
        fi
    fi

    _dev_ensure_ghcr_auth
    CONTAINERS_CONF_OVERRIDE=<(printf '[engine]\nimage_parallel_copies = 1\n') \
        podman pull --policy newer "$DEV_IMAGE"

    # Build volume mounts
    local _dev_volumes=(
        -v "${DEV_KEYS_DIR}:/opt/dev-keys:ro"
    )
    if [[ -d "${HOME}/.m2/repository" ]]; then
        _dev_volumes+=(-v "${HOME}/.m2/repository:/opt/m2-base:ro")
    fi
    if [[ -n "$_dev_source_dir" && -d "$_dev_source_dir" && "$_dev_source_dir" == "${HOME}/sources/"* ]]; then
        _dev_volumes+=(-v "${_dev_source_dir}:/opt/project-src:ro")
    elif [[ -n "$_dev_source_dir" ]]; then
        echo "WARNING: source dir '${_dev_source_dir}' is not under ~/sources/, skipping mount" >&2
    fi

    echo "Creating container '${_dev_name}'..."
    podman create -it \
        --runtime="$DEV_RUNTIME" \
        --name="$_dev_name" \
        --privileged \
        --annotation "krun.ram_mib=${_dev_ram}" \
        --annotation "krun.cpus=${_dev_cpus}" \
        --add-host=host.internal:host-gateway \
        --hostname="$_dev_name" \
        --label="$DEV_LABEL" \
        --label="dev-source-dir=${_dev_source_dir}" \
        --label="dev-template-key=${_dev_template_key}" \
        -e "PROXY_PORT=${_dev_port}" \
        -e "CLAUDE_CODE_USE_VERTEX=1" \
        -e "CLAUDE_CODE_SKIP_VERTEX_AUTH=1" \
        -e "ANTHROPIC_VERTEX_BASE_URL=http://host.internal:${_dev_port}" \
        -e "ANTHROPIC_VERTEX_PROJECT_ID=${ANTHROPIC_VERTEX_PROJECT_ID}" \
        -e "CLOUD_ML_REGION=${CLOUD_ML_REGION:-global}" \
        -e "CLAUDE_CODE_EFFORT_LEVEL=${CLAUDE_CODE_EFFORT_LEVEL:-max}" \
        -e "DEV_TEMPLATE_KEY=${_dev_template_key}" \
        ${DEV_PR_NUMBER:+-e "DEV_PR_NUMBER=${DEV_PR_NUMBER}"} \
        ${DEV_ISSUE_NUMBER:+-e "DEV_ISSUE_NUMBER=${DEV_ISSUE_NUMBER}"} \
        -p "127.0.0.1::22" \
        "${_dev_volumes[@]}" \
        "$DEV_IMAGE"
}

_dev_ssh_port() {
    local _dev_name="$1"
    podman port "$_dev_name" 22/tcp 2>/dev/null | cut -d: -f2
}

_dev_ssh_cmd() {
    local _dev_name="$1"
    shift
    local _dev_sport
    _dev_sport=$(_dev_ssh_port "$_dev_name")
    if [[ -z "$_dev_sport" ]]; then
        echo "Error: could not determine SSH port for '${_dev_name}'" >&2
        return 1
    fi
    ssh -q "$_dev_name" "$@"
}

_dev_remove_ssh_config() {
    local _dev_name="$1"
    local _dev_ssh_conf="/run/user/$(id -u)/dev-sandbox-ssh.conf"
    sed -i "/^# dev-sandbox: ${_dev_name}$/,/^$/d" "$_dev_ssh_conf" 2>/dev/null || true
}

_dev_update_ssh_config() {
    local _dev_name="$1"
    local _dev_sport
    _dev_sport=$(_dev_ssh_port "$_dev_name")
    if [[ -z "$_dev_sport" ]]; then
        return 1
    fi
    local _dev_ssh_conf="/run/user/$(id -u)/dev-sandbox-ssh.conf"

    _dev_remove_ssh_config "$_dev_name"

    # Write new entry
    cat >> "$_dev_ssh_conf" <<SSHENTRY
# dev-sandbox: ${_dev_name}
Host ${_dev_name}
    HostName 127.0.0.1
    Port ${_dev_sport}
    User dev
    IdentityFile /home/mvavrik/sandboxing/keys/id_ed25519_dev_automation
    IdentitiesOnly yes
    AddKeysToAgent yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

SSHENTRY
}

_dev_check_container_pat() {
    local _dev_pat_file="${DEV_KEYS_DIR}/gh-pat-container"
    if [[ ! -f "$_dev_pat_file" ]]; then
        return 0
    fi

    local _dev_expiry_header
    _dev_expiry_header=$(GH_TOKEN="$(cat "$_dev_pat_file")" gh api /user -i 2>/dev/null \
        | grep -i 'Github-Authentication-Token-Expiration' \
        | sed 's/.*: //') || true

    if [[ -z "$_dev_expiry_header" ]]; then
        return 0
    fi

    local _dev_expiry_epoch _dev_now_epoch _dev_days_left
    _dev_expiry_epoch=$(date -d "$_dev_expiry_header" +%s 2>/dev/null) || return 0
    _dev_now_epoch=$(date +%s)
    _dev_days_left=$(( (_dev_expiry_epoch - _dev_now_epoch) / 86400 ))

    if (( _dev_days_left < 0 )); then
        echo "ERROR: Container GitHub token EXPIRED on ${_dev_expiry_header}" >&2
        echo "Rotate it: create a new fine-grained PAT and save to ${_dev_pat_file}" >&2
        return 1
    elif (( _dev_days_left <= 1 )); then
        echo "WARNING: Container GitHub token expires TOMORROW (${_dev_expiry_header})" >&2
    elif (( _dev_days_left <= 2 )); then
        echo "WARNING: Container GitHub token expires in ${_dev_days_left} days (${_dev_expiry_header})" >&2
    fi
}

_dev_ensure_ghcr_auth() {
    if ! podman login --get-login ghcr.io &>/dev/null; then
        echo "Re-authenticating to GHCR..."
        gh auth token | podman login ghcr.io -u michalvavrik --password-stdin
    fi
}

_dev_detect_template_from_cwd() {
    local _dev_cwd _dev_conf _dev_line _dev_src_dir
    _dev_cwd="$(pwd -P)"
    _dev_conf="${DEV_CONFIGS_DIR}/project-templates.conf"

    while IFS= read -r _dev_line; do
        [[ "$_dev_line" =~ ^[[:space:]]*# || -z "$_dev_line" ]] && continue
        [[ "$_dev_line" =~ ^DEFAULT\| ]] && continue
        _dev_src_dir=$(echo "$_dev_line" | cut -d'|' -f2)
        if [[ -n "$_dev_src_dir" && "$_dev_cwd" == "$_dev_src_dir"* ]]; then
            echo "${_dev_line%%|*}"
            return 0
        fi
    done < "$_dev_conf"

    return 1
}
