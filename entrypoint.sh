#!/bin/bash
set -euo pipefail

# ── Firewall (krun kernel may not support iptables) ─────────────────────────
GATEWAY=$(getent hosts host.internal | awk '{print $1}')
GATEWAY="${GATEWAY:-$(getent hosts host.containers.internal | awk '{print $1}')}"
PROXY_PORT="${PROXY_PORT:-9222}"

if [[ -n "$GATEWAY" ]] && iptables -L -n &>/dev/null; then
    iptables -A OUTPUT -d "$GATEWAY" -p tcp --dport "$PROXY_PORT" -j ACCEPT
    iptables -A OUTPUT -d "$GATEWAY" -j DROP
else
    echo "WARNING: iptables not available, skipping host firewall" >&2
fi

# ── Allow dev user to use FUSE ───────────────────────────────────────────────
chmod 666 /dev/fuse 2>/dev/null || true

# ── Maven cache (fuse-overlayfs as dev user) ────────────────────────────────
if [ -d /opt/m2-base ] && [ "$(ls -A /opt/m2-base 2>/dev/null)" ]; then
    M2_UPPER="/tmp/m2-upper"
    M2_WORK="/tmp/m2-work"
    M2_MERGED="/home/dev/.m2/repository"
    mkdir -p "$M2_UPPER" "$M2_WORK" "$M2_MERGED"
    chown dev:dev "$M2_UPPER" "$M2_WORK" "$M2_MERGED"
    if ! mountpoint -q "$M2_MERGED" 2>/dev/null; then
        runuser -u dev -- fuse-overlayfs \
            -o "lowerdir=/opt/m2-base,upperdir=${M2_UPPER},workdir=${M2_WORK},allow_root" \
            "$M2_MERGED"
    fi
fi

# ── Credentials (from mounted /opt/dev-keys) ────────────────────────────────
if [ -d /opt/dev-keys ]; then
    if [ -f /opt/dev-keys/id_ed25519_dev_automation ]; then
        cp -f /opt/dev-keys/id_ed25519_dev_automation /home/dev/.ssh/id_ed25519
        chown dev:dev /home/dev/.ssh/id_ed25519
        chmod 600 /home/dev/.ssh/id_ed25519

        cp -f /opt/dev-keys/id_ed25519_dev_automation.pub /home/dev/.ssh/authorized_keys
        chown dev:dev /home/dev/.ssh/authorized_keys
        chmod 600 /home/dev/.ssh/authorized_keys
    fi

    if [ -f /opt/dev-keys/gh-pat-container ]; then
        if ! cat /opt/dev-keys/gh-pat-container | runuser -u dev -- gh auth login --with-token; then
            echo "ERROR: gh auth login failed — check gh-pat-container token" >&2
        fi
    fi
fi

# ── Project files (fuse-overlayfs as dev user) ──────────────────────────────
if [ -d /opt/project-src ] && [ "$(ls -A /opt/project-src 2>/dev/null)" ]; then
    WS_UPPER="/tmp/ws-upper"
    WS_WORK="/tmp/ws-work"
    mkdir -p "$WS_UPPER" "$WS_WORK"
    chown dev:dev "$WS_UPPER" "$WS_WORK" /workspace
    if ! mountpoint -q /workspace 2>/dev/null; then
        runuser -u dev -- fuse-overlayfs \
            -o "lowerdir=/opt/project-src,upperdir=${WS_UPPER},workdir=${WS_WORK},allow_root" \
            /workspace
    fi

    # Remove host-specific files (as root — allow_root lets us access the mount)
    rm -rf /workspace/.claude /workspace/.idea /workspace/.git/config 2>/dev/null || true

    # Set up clean git config
    if [ -n "${DEV_TEMPLATE_KEY:-}" ]; then
        _repo="${DEV_TEMPLATE_KEY#*/}"
        _org="${DEV_TEMPLATE_KEY%%/*}"
        cd /workspace
        git init 2>/dev/null
        git remote add origin "git@github.com:michalvavrik-dev-automation/${_repo}.git" 2>/dev/null || true
        git remote add upstream "git@github.com:${_org}/${_repo}.git" 2>/dev/null || true
        git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
        chown -R dev:dev /workspace/.git
    fi

    runuser -u dev -- git config --global --add safe.directory /workspace

    # PR checkout and details
    if [ -n "${DEV_PR_NUMBER:-}" ] && [ -n "${DEV_TEMPLATE_KEY:-}" ]; then
        echo "Checking out PR #${DEV_PR_NUMBER}..."
        runuser -u dev -- bash -c \
            "cd /workspace && gh pr checkout -f ${DEV_PR_NUMBER} --repo ${DEV_TEMPLATE_KEY}" || true
        runuser -u dev -- bash -c \
            "gh pr view ${DEV_PR_NUMBER} --repo ${DEV_TEMPLATE_KEY}" > /workspace/.pr 2>/dev/null || true
        chown dev:dev /workspace/.pr 2>/dev/null || true
    fi

    # Issue details
    if [ -n "${DEV_ISSUE_NUMBER:-}" ] && [ -n "${DEV_TEMPLATE_KEY:-}" ]; then
        runuser -u dev -- bash -c \
            "gh issue view ${DEV_ISSUE_NUMBER} --repo ${DEV_TEMPLATE_KEY}" > /workspace/.issue 2>/dev/null || true
        chown dev:dev /workspace/.issue 2>/dev/null || true
    fi
fi

# ── Start sshd (for additional terminals via dev enter) ─────────────────────
ssh-keygen -A 2>/dev/null || true
/usr/sbin/sshd 2>/dev/null || true

# ── Drop to dev user ────────────────────────────────────────────────────────
cd /workspace
exec runuser -u dev -- ${*:-bash --login}
