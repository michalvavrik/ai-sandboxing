#!/bin/bash
set -euo pipefail

readonly _DEV_BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly _DEV_KEYS_DIR="${_DEV_BASE_DIR}/keys"
readonly _DEV_CONFIG_FILE="${_DEV_BASE_DIR}/config.local"

_dev_step_header() {
    local _dev_step="$1"
    local _dev_total="$2"
    local _dev_title="$3"
    echo ""
    echo "=== Step ${_dev_step}/${_dev_total}: ${_dev_title} ==="
    echo ""
}

# --------------------------------------------------------------------------
# Step 0: config.local validation
# --------------------------------------------------------------------------
readonly _DEV_REQUIRED_VARS=(DEV_AUTOMATION_USER DEV_AUTOMATION_EMAIL DEV_AUTOMATION_NAME DEV_GHCR_USER DEV_IMAGE DEV_SOURCES_DIR)

if [[ ! -f "$_DEV_CONFIG_FILE" ]]; then
    cat > "$_DEV_CONFIG_FILE" <<'CONF'
# Dev sandbox configuration — machine-specific values.
# Fill in all values, then re-run 'dev install'.

# GitHub account used by the automation agent (for pushing branches, PRs)
DEV_AUTOMATION_USER=""

# Git identity for commits made inside containers
DEV_AUTOMATION_EMAIL=""
DEV_AUTOMATION_NAME=""

# GitHub username for GHCR authentication (repo owner)
DEV_GHCR_USER=""

# Container image base name (lang suffix added automatically from templates)
DEV_IMAGE=""

# Parent directory for project source checkouts (used by project-templates.conf)
DEV_SOURCES_DIR="${HOME}/sources"
CONF
    echo "Created ${_DEV_CONFIG_FILE} with empty values."
    echo "Fill it in and re-run: $0"
    exit 1
fi

source "$_DEV_CONFIG_FILE"

_dev_missing=()
for _dev_var in "${_DEV_REQUIRED_VARS[@]}"; do
    if [[ -z "${!_dev_var:-}" ]]; then
        _dev_missing+=("$_dev_var")
    fi
done

if [[ ${#_dev_missing[@]} -gt 0 ]]; then
    echo "Error: ${_DEV_CONFIG_FILE} is missing values for: ${_dev_missing[*]}" >&2
    echo "Fill them in and re-run: $0" >&2
    exit 1
fi

echo "Config loaded: ${_DEV_CONFIG_FILE}"

# --------------------------------------------------------------------------
# Step 1/10: SSH keys
# --------------------------------------------------------------------------
_dev_step_header 1 10 "SSH keys for ${DEV_AUTOMATION_USER}"

mkdir -p "$_DEV_KEYS_DIR"
chmod 700 "$_DEV_KEYS_DIR"

readonly _DEV_SSH_KEY="${_DEV_KEYS_DIR}/id_ed25519_dev_automation"

if [[ -f "$_DEV_SSH_KEY" ]]; then
    echo "SSH key already exists: ${_DEV_SSH_KEY}"
else
    ssh-keygen -t ed25519 -C "$DEV_AUTOMATION_EMAIL" -f "$_DEV_SSH_KEY" -N ""
    echo "SSH key generated."
fi

# Verify SSH access — if not working, guide the user
_dev_ssh_output=$(ssh -i "$_DEV_SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1) || true
if echo "$_dev_ssh_output" | grep -q "$DEV_AUTOMATION_USER"; then
    echo "SSH key already registered and working."
else
    echo "SSH key is not yet registered on GitHub. Add it now:"
    echo ""
    echo "  1. Log in to GitHub as: ${DEV_AUTOMATION_USER}"
    echo "  2. Go to: https://github.com/settings/ssh/new"
    echo "  3. Title: dev-sandbox"
    echo "  4. Key type: Authentication key"
    echo "  5. Paste this public key:"
    echo ""
    cat "${_DEV_SSH_KEY}.pub"
    echo ""
    read -rp "Press Enter after adding the key..."

    _dev_ssh_output=$(ssh -i "$_DEV_SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1) || true
    if echo "$_dev_ssh_output" | grep -q "$DEV_AUTOMATION_USER"; then
        echo "SSH verification passed."
    else
        echo "Error: SSH key not recognized as ${DEV_AUTOMATION_USER}." >&2
        echo "Response: ${_dev_ssh_output}" >&2
        echo "Fix this before continuing." >&2
        exit 1
    fi
fi

# Container-only SSH key (for sshd access, NOT on GitHub)
readonly _DEV_CONTAINER_SSH_KEY="${_DEV_KEYS_DIR}/id_ed25519_container"
if [[ -f "$_DEV_CONTAINER_SSH_KEY" ]]; then
    echo "Container SSH key already exists."
else
    ssh-keygen -t ed25519 -C "dev-sandbox-container" -f "$_DEV_CONTAINER_SSH_KEY" -N ""
    echo "Container SSH key generated (not for GitHub — sshd access only)."
fi

# --------------------------------------------------------------------------
# Step 2/10: Fine-grained PAT for containers
# --------------------------------------------------------------------------
_dev_step_header 2 10 "Fine-grained PAT for containers"

readonly _DEV_CONTAINER_PAT_FILE="${_DEV_KEYS_DIR}/gh-pat-container"

if [[ -f "$_DEV_CONTAINER_PAT_FILE" ]]; then
    echo "Container PAT already stored: ${_DEV_CONTAINER_PAT_FILE}"
else
    echo "Create a fine-grained PAT for use INSIDE containers:"
    echo ""
    echo "  1. Log in to GitHub as: ${DEV_AUTOMATION_USER}"
    echo "  2. Go to: https://github.com/settings/personal-access-tokens/new"
    echo ""
    echo "  Settings:"
    echo "    Name:              dev-container-readonly"
    echo "    Expiration:        30 days (rotate periodically)"
    echo "    Repository access: Public repositories (read-only)"
    echo "    Permissions:"
    echo "      (none needed — public repo read is default)"
    echo ""
    read -rs -p "Paste the token here: " _dev_container_token
    echo ""

    if [[ -z "$_dev_container_token" ]]; then
        echo "Error: empty token" >&2
        exit 1
    fi

    echo "$_dev_container_token" > "$_DEV_CONTAINER_PAT_FILE"
    chmod 600 "$_DEV_CONTAINER_PAT_FILE"
    echo "Container PAT saved."
fi

echo "To rotate: replace ${_DEV_CONTAINER_PAT_FILE} with a new token."
echo "New containers will use the new token automatically."

# --------------------------------------------------------------------------
# Step 3/10: Bob Shell API key
# --------------------------------------------------------------------------
_dev_step_header 3 10 "Bob Shell API key"

readonly _DEV_BOB_KEY_FILE="${_DEV_KEYS_DIR}/ibm_bob_shell_api.key"

if podman secret inspect bob-api-key &>/dev/null; then
    echo "Podman secret 'bob-api-key' already exists."
    echo "To rotate: podman secret rm bob-api-key, replace ${_DEV_BOB_KEY_FILE}, re-run install."
else
    if [[ -f "$_DEV_BOB_KEY_FILE" ]]; then
        echo "Found existing key file: ${_DEV_BOB_KEY_FILE}"
    else
        echo "Create a Bob Shell API key:"
        echo ""
        echo "  1. Go to: https://bob.ibm.com"
        echo "  2. Open your subscription instance"
        echo "  3. Create an API key with scope: Inference"
        echo "  4. Copy the key value (you won't see it again)"
        echo ""
        read -rs -p "Paste the API key here: " _dev_bob_key
        echo ""

        if [[ -z "$_dev_bob_key" ]]; then
            echo "Error: empty key" >&2
            exit 1
        fi

        echo "$_dev_bob_key" > "$_DEV_BOB_KEY_FILE"
        sudo chown root:root "$_DEV_BOB_KEY_FILE"
        sudo chmod 600 "$_DEV_BOB_KEY_FILE"
        echo "Key saved to ${_DEV_BOB_KEY_FILE} (root-only)."
    fi

    sudo cat "$_DEV_BOB_KEY_FILE" | podman secret create bob-api-key -
    echo "Podman secret 'bob-api-key' created."
fi

# --------------------------------------------------------------------------
# Step 4/10: System packages
# --------------------------------------------------------------------------
_dev_step_header 4 10 "System packages"

_dev_pkgs_needed=()
for _dev_pkg in libkrun crun-krun python3-google-auth python3-requests passt; do
    if ! rpm -q "$_dev_pkg" &>/dev/null; then
        _dev_pkgs_needed+=("$_dev_pkg")
    fi
done

if [[ ${#_dev_pkgs_needed[@]} -eq 0 ]]; then
    echo "All required packages already installed."
else
    echo "Installing: ${_dev_pkgs_needed[*]}"
    sudo dnf install -y "${_dev_pkgs_needed[@]}"
fi

# --------------------------------------------------------------------------
# Step 5/10: Firewall — block proxy port from external network
# --------------------------------------------------------------------------
_dev_step_header 5 10 "Firewall rule for proxy port"

readonly _DEV_FW_RULE_V4='rule priority="-1" family="ipv4" port port="9222" protocol="tcp" reject'
readonly _DEV_FW_RULE_V6='rule priority="-1" family="ipv6" port port="9222" protocol="tcp" reject'

for _dev_fw_rule in "$_DEV_FW_RULE_V4" "$_DEV_FW_RULE_V6"; do
    if ! firewall-cmd --query-rich-rule="$_dev_fw_rule" --permanent &>/dev/null; then
        sudo firewall-cmd --add-rich-rule="$_dev_fw_rule" --permanent
    fi
done
sudo firewall-cmd --reload

if ! firewall-cmd --query-rich-rule="$_DEV_FW_RULE_V4" --permanent &>/dev/null; then
    echo "Error: firewall rule not active. Proxy port 9222 is exposed to the local network." >&2
    exit 1
fi
echo "Firewall rules verified (IPv4 + IPv6)."

# --------------------------------------------------------------------------
# Step 6/10: Register krun runtime
# --------------------------------------------------------------------------
_dev_step_header 6 10 "Register krun runtime"

readonly _DEV_CONTAINERS_CONF="${HOME}/.config/containers/containers.conf"

if [[ -f "$_DEV_CONTAINERS_CONF" ]] && grep -q 'krun' "$_DEV_CONTAINERS_CONF"; then
    echo "krun runtime already registered."
else
    mkdir -p "$(dirname "$_DEV_CONTAINERS_CONF")"
    if [[ -f "$_DEV_CONTAINERS_CONF" ]]; then
        if ! grep -q '\[engine\.runtimes\]' "$_DEV_CONTAINERS_CONF" 2>/dev/null; then
            printf '\n[engine.runtimes]\nkrun = ["/usr/bin/crun-krun"]\n' >> "$_DEV_CONTAINERS_CONF"
        else
            sed -i '/\[engine\.runtimes\]/a krun = ["/usr/bin/crun-krun"]' "$_DEV_CONTAINERS_CONF"
        fi
    else
        cat > "$_DEV_CONTAINERS_CONF" <<'CONF'
[engine.runtimes]
krun = ["/usr/bin/crun-krun"]
CONF
    fi
    echo "Registered krun runtime."
fi

echo "Verifying krun runtime..."
if podman run --runtime=krun --rm fedora:44 echo "krun: OK" 2>/dev/null; then
    echo "krun verification passed."
else
    echo "WARNING: krun verification failed. You may need to reboot or check /dev/kvm permissions."
fi

# --------------------------------------------------------------------------
# Step 7/10: GHCR auth + image pull
# --------------------------------------------------------------------------
_dev_step_header 7 10 "GHCR authentication and image pull"

source "$(dirname "$0")/dev-common.sh"
_dev_ensure_ghcr_auth
echo "GHCR authentication OK."

_dev_image_base="${DEV_IMAGE%:*}"
_dev_conf="${DEV_CONFIGS_DIR}/project-templates.conf"
_dev_seen=""
while IFS= read -r _dev_line; do
    [[ "$_dev_line" =~ ^[[:space:]]*# || -z "$_dev_line" ]] && continue
    _dev_lang=$(echo "$_dev_line" | awk -F'|' '{print $NF}')
    _dev_lang="${_dev_lang:-java}"
    [[ "$_dev_seen" == *"|${_dev_lang}|"* ]] && continue
    _dev_seen="${_dev_seen}|${_dev_lang}|"
    _dev_img="${_dev_image_base}-${_dev_lang}:latest"
    echo "Pulling ${_dev_img} (first time may take a few minutes)..."
    podman pull --policy missing "$_dev_img"
done < "$_dev_conf"
echo "Dev images ready."

# --------------------------------------------------------------------------
# Step 8/10: Shell alias
# --------------------------------------------------------------------------
_dev_step_header 8 10 "Shell alias"

readonly _DEV_ALIAS="alias dev=\"source ${_DEV_BASE_DIR}/scripts/dev.sh\""

if grep -qF 'alias dev=' "${HOME}/.bashrc" 2>/dev/null; then
    echo "Shell alias already present in ~/.bashrc."
else
    echo "" >> "${HOME}/.bashrc"
    echo "# Dev sandbox CLI" >> "${HOME}/.bashrc"
    echo "$_DEV_ALIAS" >> "${HOME}/.bashrc"
    echo "Alias added to ~/.bashrc."
fi


# SSH config Include for container access (Gateway, dev enter, dev see, dev cp)
# Uses wildcard in tmpfs — silently ignored when no containers exist, wiped on reboot
if ! grep -qF 'dev-sandbox-ssh' "${HOME}/.ssh/config" 2>/dev/null; then
    sed -i "1i Include /run/user/$(id -u)/dev-sandbox-ssh*.conf" "${HOME}/.ssh/config"
    echo "SSH config Include added."
else
    echo "SSH config Include already present."
fi


if ! grep -qF '_dev_completion' "${HOME}/.bashrc" 2>/dev/null; then
    cat >> "${HOME}/.bashrc" <<COMP
_dev_completion() {
    local cur="\${COMP_WORDS[COMP_CWORD]}"
    local prev="\${COMP_WORDS[COMP_CWORD-1]}"
    if [[ "\${COMP_WORDS[1]}" == "cp" && \$COMP_CWORD -ge 2 ]]; then
        compopt -o filenames
        COMPREPLY=(\$(compgen -f -- "\$cur"))
    else
        [[ "\$prev" == "cpout" ]] && compopt -o nospace
        COMPREPLY=(\$(${_DEV_BASE_DIR}/scripts/dev-complete.sh "\$COMP_CWORD" "\$prev" "\$cur"))
    fi
}
complete -F _dev_completion dev
COMP
    echo "Tab completion added to ~/.bashrc."
fi

# --------------------------------------------------------------------------
# Step 9/10: Sources directory
# --------------------------------------------------------------------------
_dev_step_header 9 10 "Sources directory"

if [[ ! -d "$DEV_SOURCES_DIR" ]]; then
    mkdir -p "$DEV_SOURCES_DIR"
    echo "Created ${DEV_SOURCES_DIR}"
else
    echo "Sources directory exists: ${DEV_SOURCES_DIR}"
fi

# --------------------------------------------------------------------------
# Step 10/10: Systemd user service for login-time image pull
# --------------------------------------------------------------------------
_dev_step_header 10 10 "Systemd user service for login-time image pull"

readonly _DEV_SERVICE_DIR="${HOME}/.config/systemd/user"
readonly _DEV_SERVICE_FILE="${_DEV_SERVICE_DIR}/dev-pull.service"

mkdir -p "$_DEV_SERVICE_DIR"
cat > "$_DEV_SERVICE_FILE" <<UNIT
[Unit]
Description=Pull dev sandbox image
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${_DEV_BASE_DIR}/scripts/dev-pull.sh

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable dev-pull.service
echo "Enabled dev-pull.service (runs on graphical login)."
echo "Logs: journalctl --user -u dev-pull"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. source ~/.bashrc   (or open a new terminal)"
echo "  2. dev list            (should show no containers)"
echo "  3. dev new my-sandbox  (create your first container)"
echo ""
