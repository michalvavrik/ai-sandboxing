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

# ── Persist container env vars for all sessions (main + SSH) ─────────────────
cat > /etc/profile.d/dev-sandbox.sh <<DEVENV
export CLAUDE_CODE_USE_VERTEX="${CLAUDE_CODE_USE_VERTEX:-}"
export CLAUDE_CODE_SKIP_VERTEX_AUTH="${CLAUDE_CODE_SKIP_VERTEX_AUTH:-}"
export ANTHROPIC_VERTEX_BASE_URL="${ANTHROPIC_VERTEX_BASE_URL:-}"
export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-}"
export CLOUD_ML_REGION="${CLOUD_ML_REGION:-}"
export HISTFILE=/dev/null
DEVENV

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
            -o "lowerdir=/opt/m2-base,upperdir=${M2_UPPER},workdir=${M2_WORK}" \
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

# ── Project workspace (from baked-in shallow clone) ─────────────────────────
if [ -n "${DEV_TEMPLATE_KEY:-}" ]; then
    _repo="${DEV_TEMPLATE_KEY#*/}"
    _org="${DEV_TEMPLATE_KEY%%/*}"
    chown dev:dev /workspace

    # Copy baked-in repo to workspace (local disk, fast)
    if [ ! -d /workspace/.git ] && [ -d "/opt/workspace/${_repo}" ]; then
        runuser -u dev -- cp -a "/opt/workspace/${_repo}/." /workspace/
        runuser -u dev -- git -C /workspace remote set-url origin \
            "git@github.com:michalvavrik-dev-automation/${_repo}.git"
        runuser -u dev -- git -C /workspace remote add upstream \
            "git@github.com:${_org}/${_repo}.git" 2>/dev/null || true
    fi

    # Link host's full history as git alternates (avoids re-downloading objects)
    if [ -d /opt/project-src/.git ]; then
        runuser -u dev -- git config --global --add safe.directory /opt/project-src
        runuser -u dev -- bash -c \
            'mkdir -p /workspace/.git/objects/info && echo /opt/project-src/.git/objects >> /workspace/.git/objects/info/alternates' \
            2>/dev/null || true
        runuser -u dev -- bash -c "cat > /workspace/CLAUDE.md" <<CLAUDEMD
# Sandbox environment for ${_org}/${_repo}

- /workspace is a shallow clone (depth 1). Work here.
- /opt/project-src has the full git history of ${_org}/${_repo} (read-only). Use it for \`git log\`, \`git blame\`, \`git show\`:
  \`\`\`
  git -C /opt/project-src log --oneline -20
  git -C /opt/project-src blame path/to/file
  git -C /opt/project-src show <commit>:path/to/file
  \`\`\`
- Push to origin (michalvavrik-dev-automation/${_repo}), fetch from upstream (${_org}/${_repo}).

## Reference codebases (read-only)
- /opt/project-src — ${_org}/${_repo} (keycloak/quarkus) with full commit history (host mount). Use for \`git log\`, \`git blame\`, \`git show\`.
- /opt/workspace/keycloak — latest keycloak main (shallow, for browsing source)
- /opt/workspace/quarkus — latest quarkus main (shallow, for browsing source)
- /tmp/workspace — additional documents copied in by the user (if any)
CLAUDEMD
    fi

    # PR checkout and details
    if [ -n "${DEV_PR_NUMBER:-}" ]; then
        echo "Checking out PR #${DEV_PR_NUMBER}..."
        runuser -u dev -- bash -c \
            "cd /workspace && gh pr checkout -f ${DEV_PR_NUMBER} --repo ${DEV_TEMPLATE_KEY}" || true
        runuser -u dev -- bash -c \
            "gh pr view ${DEV_PR_NUMBER} --repo ${DEV_TEMPLATE_KEY} > /workspace/.pr 2>/dev/null" || true
    fi

    # Issue details
    if [ -n "${DEV_ISSUE_NUMBER:-}" ]; then
        runuser -u dev -- bash -c \
            "gh issue view ${DEV_ISSUE_NUMBER} --repo ${DEV_TEMPLATE_KEY} > /workspace/.issue 2>/dev/null" || true
    fi
fi

# ── Start sshd (for additional terminals via dev enter) ─────────────────────
ssh-keygen -A &>/dev/null || true
/usr/sbin/sshd &>/dev/null || true

# ── Drop to dev user ────────────────────────────────────────────────────────
exec runuser -u dev -- sh -c 'cd /workspace 2>/dev/null; exec "$@"' _ "${@:-bash --login}"
