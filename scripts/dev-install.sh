#!/bin/bash
set -euo pipefail

readonly _DEV_BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly _DEV_KEYS_DIR="${_DEV_BASE_DIR}/keys"
readonly _DEV_AUTOMATION_USER="michalvavrik-dev-automation"

_dev_step_header() {
    local _dev_step="$1"
    local _dev_total="$2"
    local _dev_title="$3"
    echo ""
    echo "=== Step ${_dev_step}/${_dev_total}: ${_dev_title} ==="
    echo ""
}

# --------------------------------------------------------------------------
# Step 1/6: SSH keys
# --------------------------------------------------------------------------
_dev_step_header 1 7 "SSH keys for ${_DEV_AUTOMATION_USER}"

mkdir -p "$_DEV_KEYS_DIR"
chmod 700 "$_DEV_KEYS_DIR"

readonly _DEV_SSH_KEY="${_DEV_KEYS_DIR}/id_ed25519_dev_automation"

if [[ -f "$_DEV_SSH_KEY" ]]; then
    echo "SSH key already exists: ${_DEV_SSH_KEY}"
else
    ssh-keygen -t ed25519 -C "dev-automation@michalvavrik.net" -f "$_DEV_SSH_KEY" -N ""
    echo "SSH key generated."
fi

# Verify SSH access — if not working, guide the user
_dev_ssh_output=$(ssh -i "$_DEV_SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1) || true
if echo "$_dev_ssh_output" | grep -q "$_DEV_AUTOMATION_USER"; then
    echo "SSH key already registered and working."
else
    echo "SSH key is not yet registered on GitHub. Add it now:"
    echo ""
    echo "  1. Log in to GitHub as: ${_DEV_AUTOMATION_USER}"
    echo "  2. Go to: https://github.com/settings/ssh/new"
    echo "  3. Title: dev-sandbox"
    echo "  4. Key type: Authentication key"
    echo "  5. Paste this public key:"
    echo ""
    cat "${_DEV_SSH_KEY}.pub"
    echo ""
    read -rp "Press Enter after adding the key..."

    _dev_ssh_output=$(ssh -i "$_DEV_SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1) || true
    if echo "$_dev_ssh_output" | grep -q "$_DEV_AUTOMATION_USER"; then
        echo "SSH verification passed."
    else
        echo "Error: SSH key not recognized as ${_DEV_AUTOMATION_USER}." >&2
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
# Step 2/6: Fine-grained PAT for containers
# --------------------------------------------------------------------------
_dev_step_header 2 7 "Fine-grained PAT for containers"

readonly _DEV_CONTAINER_PAT_FILE="${_DEV_KEYS_DIR}/gh-pat-container"

if [[ -f "$_DEV_CONTAINER_PAT_FILE" ]]; then
    echo "Container PAT already stored: ${_DEV_CONTAINER_PAT_FILE}"
else
    echo "Create a fine-grained PAT for use INSIDE containers:"
    echo ""
    echo "  1. Log in to GitHub as: ${_DEV_AUTOMATION_USER}"
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
# Step 3/6: System packages
# --------------------------------------------------------------------------
_dev_step_header 3 7 "System packages"

_dev_pkgs_needed=()
for _dev_pkg in libkrun crun-krun python3-google-auth python3-requests; do
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
# Step 4/7: Firewall — block proxy port from external network
# --------------------------------------------------------------------------
_dev_step_header 4 7 "Firewall rule for proxy port"

readonly _DEV_FW_RULE='rule priority="-1" family="ipv4" port port="9222" protocol="tcp" reject'

if firewall-cmd --query-rich-rule="$_DEV_FW_RULE" --permanent &>/dev/null; then
    echo "Firewall rule already configured."
else
    sudo firewall-cmd --add-rich-rule="$_DEV_FW_RULE" --permanent
    sudo firewall-cmd --reload
fi

if ! firewall-cmd --query-rich-rule="$_DEV_FW_RULE" --permanent &>/dev/null; then
    echo "Error: firewall rule not active. Proxy port 9222 is exposed to the local network." >&2
    exit 1
fi
echo "Firewall rule verified."

# --------------------------------------------------------------------------
# Step 5/7: Register krun runtime
# --------------------------------------------------------------------------
_dev_step_header 5 7 "Register krun runtime"

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
# Step 5/6: GHCR auth
# --------------------------------------------------------------------------
_dev_step_header 6 7 "GHCR authentication"

source "$(dirname "$0")/dev-common.sh"
_dev_ensure_ghcr_auth
echo "GHCR authentication OK."

# --------------------------------------------------------------------------
# Step 6/6: Shell alias
# --------------------------------------------------------------------------
_dev_step_header 7 7 "Shell alias"

readonly _DEV_ALIAS="alias dev=\"source ${_DEV_BASE_DIR}/scripts/dev.sh\""

readonly _DEV_BG_PULL='(flock -n /tmp/dev-pull.lock -c '\''{ podman login --get-login ghcr.io &>/dev/null || gh auth token | podman login ghcr.io -u michalvavrik --password-stdin &>/dev/null; podman pull --policy newer ghcr.io/michalvavrik/ai-sandboxing/dev-sandbox:latest; podman pull --policy newer ghcr.io/michalvavrik/ai-sandboxing/dev-sandbox:latest-next; }'\'' &>/dev/null &)'

if grep -qF 'alias dev=' "${HOME}/.bashrc" 2>/dev/null; then
    echo "Shell alias already present in ~/.bashrc."
else
    echo "" >> "${HOME}/.bashrc"
    echo "# Dev sandbox CLI" >> "${HOME}/.bashrc"
    echo "$_DEV_ALIAS" >> "${HOME}/.bashrc"
    echo "Alias added to ~/.bashrc."
fi

if ! grep -qF 'dev-sandbox:latest' "${HOME}/.bashrc" 2>/dev/null; then
    echo "$_DEV_BG_PULL" >> "${HOME}/.bashrc"
    echo "Background image pull added to ~/.bashrc."
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
    cat >> "${HOME}/.bashrc" <<'COMP'
_dev_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=($(compgen -W "new enter delete stop start see cp cpout use idea list install" -- "$cur"))
    elif [[ $COMP_CWORD -eq 2 && "$prev" =~ ^(enter|delete|stop|start|see|use)$ ]]; then
        COMPREPLY=($(compgen -W "$(podman ps -a --filter=label=dev-sandbox --format '{{.Names}}' 2>/dev/null)" -- "$cur"))
    elif [[ "$prev" == "cpout" ]]; then
        local name="${DEV_LAST_CONTAINER:-}"
        if [[ -n "$name" ]]; then
            local prefix="/workspace/"
            [[ "$cur" == /* ]] && prefix=""
            COMPREPLY=($(ssh -q "$name" "ls -d ${prefix}${cur}* 2>/dev/null" | sed "s|^${prefix}||"))
        fi
    fi
}
complete -F _dev_completion dev
COMP
    echo "Tab completion added to ~/.bashrc."
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. source ~/.bashrc   (or open a new terminal)"
echo "  2. dev list            (should show no containers)"
echo "  3. dev new my-sandbox  (create your first container)"
echo ""
