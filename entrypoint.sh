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
export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL:-max}"
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
    chown dev:dev /home/dev/.m2 "$M2_UPPER" "$M2_WORK" "$M2_MERGED"
    if ! mountpoint -q "$M2_MERGED" 2>/dev/null; then
        runuser -u dev -- fuse-overlayfs \
            -o "lowerdir=/opt/m2-base,upperdir=${M2_UPPER},workdir=${M2_WORK},squash_to_uid=1000,squash_to_gid=1000" \
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

    _gh_auth_pid=""
    if [ -f /opt/dev-keys/gh-pat-container ]; then
        (cat /opt/dev-keys/gh-pat-container | runuser -u dev -- gh auth login --with-token || \
            echo "ERROR: gh auth login failed — check gh-pat-container token" >&2) &
        _gh_auth_pid=$!
    fi
fi

# ── Project workspace (from baked-in shallow clone) ─────────────────────────
if [ -n "${DEV_TEMPLATE_KEY:-}" ]; then
    _repo="${DEV_TEMPLATE_KEY#*/}"
    _org="${DEV_TEMPLATE_KEY%%/*}"
    chown dev:dev /workspace

    # Symlink workspace to the baked-in repo (instant — container overlay handles writes)
    if [ ! -d /workspace/.git ] && [ -d "/opt/workspace/${_repo}" ]; then
        cd /
        rm -rf /workspace
        ln -s "/opt/workspace/${_repo}" /workspace
        runuser -u dev -- git -C /workspace remote set-url origin \
            "git@github.com:michalvavrik-dev-automation/${_repo}.git"
        runuser -u dev -- git -C /workspace remote add upstream \
            "git@github.com:${_org}/${_repo}.git" 2>/dev/null || true
    fi

    # Link host's full history as git alternates (avoids re-downloading objects)
    # Overlay the objects dir so JGit/Nisse can write probe files without hitting the read-only mount
    if [ -d /opt/project-src/.git ]; then
        runuser -u dev -- git config --global --add safe.directory /opt/project-src
        mkdir -p /tmp/git-obj-upper /tmp/git-obj-work /opt/project-src-objects
        chown dev:dev /tmp/git-obj-upper /tmp/git-obj-work /opt/project-src-objects
        runuser -u dev -- fuse-overlayfs \
            -o "lowerdir=/opt/project-src/.git/objects,upperdir=/tmp/git-obj-upper,workdir=/tmp/git-obj-work,squash_to_uid=1000,squash_to_gid=1000" \
            /opt/project-src-objects 2>/dev/null || true
        runuser -u dev -- bash -c \
            'mkdir -p /workspace/.git/objects/info && echo /opt/project-src-objects >> /workspace/.git/objects/info/alternates' \
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

    # PR checkout and details (wait for gh auth if it's still running)
    if [ -n "${DEV_PR_NUMBER:-}" ]; then
        [ -n "$_gh_auth_pid" ] && wait "$_gh_auth_pid" 2>/dev/null
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
(ssh-keygen -A &>/dev/null && /usr/sbin/sshd &>/dev/null) &

# ── Drop to dev user ────────────────────────────────────────────────────────
exec runuser -u dev -- sh -c 'cd /workspace 2>/dev/null; exec "$@"' _ "${@:-bash --login}" 2> >(grep -v "ttyname" >&2)
