#!/bin/bash
set -euo pipefail

ulimit -Hn 65536
ulimit -Sn 32768
echo "* soft nofile 32768" > /etc/security/limits.d/90-nofile.conf
echo "* hard nofile 65536" >> /etc/security/limits.d/90-nofile.conf

# ── Git identity (from host config.local, passed as env vars) ──────────────
printf '[user]\n\temail = %s\n\tname = %s\n' \
    "${DEV_AUTOMATION_EMAIL:-dev@sandbox.local}" \
    "${DEV_AUTOMATION_NAME:-Dev Automation}" \
    > /etc/gitconfig

# ── Guest firewall (nft — kernel has NF_TABLES but not XTABLES) ─────────────
HOST_IP=$(getent hosts host.internal | awk '{print $1}')
HOST_IP="${HOST_IP:-$(getent hosts host.containers.internal | awk '{print $1}')}"
PROXY_PORT="${PROXY_PORT:-9222}"

if [[ -n "$HOST_IP" ]] && nft list ruleset &>/dev/null; then
    nft add table inet filter
    nft add chain inet filter output '{ type filter hook output priority 0; policy drop; }'
    nft add rule inet filter output oifname "lo" accept
    nft add rule inet filter output ip daddr "$HOST_IP" tcp dport "$PROXY_PORT" accept
    nft add rule inet filter output udp dport 53 accept
    nft add rule inet filter output tcp dport 443 accept
    nft add rule inet filter output ct state established,related accept
else
    echo "WARNING: nft not available or host IP unknown, skipping guest firewall" >&2
fi

# ── Persist container env vars for all sessions (main + SSH) ─────────────────
cat > /etc/profile.d/dev-sandbox.sh <<DEVENV
export CLAUDE_CODE_USE_VERTEX="${CLAUDE_CODE_USE_VERTEX:-}"
export CLAUDE_CODE_SKIP_VERTEX_AUTH="${CLAUDE_CODE_SKIP_VERTEX_AUTH:-}"
export ANTHROPIC_VERTEX_BASE_URL="${ANTHROPIC_VERTEX_BASE_URL:-}"
export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-}"
export CLOUD_ML_REGION="${CLOUD_ML_REGION:-}"
export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL:-max}"
export XDG_RUNTIME_DIR=/run/user/1000
export DOCKER_HOST=unix:///run/user/1000/podman/podman.sock
export HISTFILE=/dev/null
DEVENV

# ── Allow dev user to use FUSE ───────────────────────────────────────────────
chmod 666 /dev/fuse 2>/dev/null || true

# ── Bounded disk (caps host disk usage per container) ───────────────────────
if [[ -f /opt/bounded-disk.img ]]; then
    if ! blkid /opt/bounded-disk.img 2>/dev/null | grep -q ext4; then
        mkfs.ext4 -m 0 -q /opt/bounded-disk.img
    fi
    mkdir -p /mnt/bounded
    mount -o loop /opt/bounded-disk.img /mnt/bounded

    chown root:root /opt/bounded-disk.img
    chmod 600 /opt/bounded-disk.img

    mkdir -p /mnt/bounded/home-upper /mnt/bounded/home-work /mnt/bounded/tmp-data
    chown dev:dev /mnt/bounded/home-upper /mnt/bounded/home-work /mnt/bounded/tmp-data

    fuse-overlayfs \
        -o "lowerdir=/home/dev,upperdir=/mnt/bounded/home-upper,workdir=/mnt/bounded/home-work,squash_to_uid=1000,squash_to_gid=1000" \
        /home/dev

    mount --bind /mnt/bounded/tmp-data /tmp
    chmod 1777 /tmp

fi

# ── Inner podman storage (separate loopback, independent of bounded disk) ───
if [[ -f /opt/podman-disk.img ]]; then
    if ! blkid /opt/podman-disk.img 2>/dev/null | grep -q ext4; then
        mkfs.ext4 -m 0 -q /opt/podman-disk.img
    fi
    mkdir -p /mnt/podman
    mount -o loop /opt/podman-disk.img /mnt/podman
    chown root:root /opt/podman-disk.img
    chmod 600 /opt/podman-disk.img
    mkdir -p /mnt/podman/storage /mnt/podman/run
    chown dev:dev /mnt/podman/storage /mnt/podman/run
fi

# ── Rootless podman (for Testcontainers) ────────────────────────────────────
chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap 2>/dev/null || true

mkdir -p /dev/net
mknod /dev/net/tun c 10 200 2>/dev/null || true
chmod 666 /dev/net/tun

mkdir -p /run/user/1000
chown dev:dev /run/user/1000

if [[ -d /mnt/podman ]]; then
    runuser -u dev -- mkdir -p /home/dev/.config/containers
    cat > /home/dev/.config/containers/storage.conf <<STCONF
[storage]
driver = "overlay"
graphroot = "/mnt/podman/storage"
runroot = "/mnt/podman/run"
STCONF
    chown dev:dev /home/dev/.config/containers/storage.conf

    runuser -u dev -- bash -c 'XDG_RUNTIME_DIR=/run/user/1000 podman system service --time=0 &'
fi

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
    # Container SSH key (sshd access only — NOT the GitHub key)
    if [ -f /opt/dev-keys/id_ed25519_container.pub ]; then
        cp -f /opt/dev-keys/id_ed25519_container.pub /home/dev/.ssh/authorized_keys
        chown dev:dev /home/dev/.ssh/authorized_keys
        chmod 600 /home/dev/.ssh/authorized_keys
    fi

    _gh_auth_pid=""
    if [ -f /opt/dev-keys/gh-pat-container ]; then
        (cat /opt/dev-keys/gh-pat-container | runuser -u dev -- gh auth login --with-token || \
            echo "ERROR: gh auth login failed — check gh-pat-container token" >&2) &
        _gh_auth_pid=$!
    fi

    # Bob Shell API key (injected via podman secret, readable only by bobrunner)
    if [ -f /run/secrets/bob-api-key ]; then
        mkdir -p /run/bob-secrets
        cp -f /run/secrets/bob-api-key /run/bob-secrets/api.key
        chown bobrunner:bobrunner /run/bob-secrets/api.key
        chmod 400 /run/bob-secrets/api.key
    fi
fi

# ── Project workspace (from baked-in shallow clone) ─────────────────────────
if [ -n "${DEV_TEMPLATE_KEY:-}" ]; then
    _repo="${DEV_TEMPLATE_KEY#*/}"
    _org="${DEV_TEMPLATE_KEY%%/*}"
    chown dev:dev /workspace

    # Set up workspace from the baked-in repo
    if [ ! -d /workspace/.git ] && [ -d "/opt/workspace/${_repo}" ]; then
        cd /
        rm -rf /workspace
        mkdir -p /workspace
        chown dev:dev /workspace
        if [[ -d /mnt/bounded ]]; then
            mkdir -p /mnt/bounded/ws-upper /mnt/bounded/ws-work
            chown dev:dev /mnt/bounded/ws-upper /mnt/bounded/ws-work
            runuser -u dev -- fuse-overlayfs \
                -o "lowerdir=/opt/workspace/${_repo},upperdir=/mnt/bounded/ws-upper,workdir=/mnt/bounded/ws-work,squash_to_uid=1000,squash_to_gid=1000" \
                /workspace
        else
            ln -s "/opt/workspace/${_repo}" /workspace
        fi
        runuser -u dev -- git -C /workspace remote set-url origin \
            "http://host.internal:${PROXY_PORT}/git/${DEV_AUTOMATION_USER:-dev-automation}/${_repo}.git"
        runuser -u dev -- git -C /workspace remote add upstream \
            "https://github.com/${_org}/${_repo}.git" 2>/dev/null || true
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
- Push to origin (${DEV_AUTOMATION_USER:-dev-automation}/${_repo}), fetch from upstream (${_org}/${_repo}).

## Reference codebases (read-only)
- /opt/project-src — ${_org}/${_repo} (keycloak/quarkus) with full commit history (host mount). Use for \`git log\`, \`git blame\`, \`git show\`.
- /opt/workspace/keycloak — latest keycloak main (shallow, for browsing source)
- /opt/workspace/quarkus — latest quarkus main (shallow, for browsing source)
- /tmp/workspace — additional documents copied in by the user (if any)

## Task context
- .pr — PR details (\`gh pr view\` output), present when working on a pull request
- .issue — issue details (\`gh issue view\` output), present when working on an issue
CLAUDEMD
        runuser -u dev -- git -C /workspace update-index --assume-unchanged CLAUDE.md 2>/dev/null || true
        runuser -u dev -- git -C /workspace config core.untrackedCache true 2>/dev/null || true
        # Warm virtio-fs dentry cache for workspace + Claude Code binary (async)
        (runuser -u dev -- git -C /workspace status; cat /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe) &>/dev/null &
    fi

    _target_branch="dev-auto/$(hostname)"

    # PR checkout and details (first run only — subsequent starts reuse the working branch)
    if [ -n "${DEV_PR_NUMBER:-}" ]; then
        if ! runuser -u dev -- git -C /workspace rev-parse --verify "$_target_branch" &>/dev/null 2>&1; then
            [ -n "$_gh_auth_pid" ] && wait "$_gh_auth_pid" 2>/dev/null
            # Copy host refs so git can negotiate efficiently with GitHub
            # Without this, the depth-1 clone sends 1 "have" and GitHub sends ~1M objects
            # Objects are available via alternates; refs tell git what commits exist
            if [ -f /opt/project-src/.git/packed-refs ]; then
                cp /opt/project-src/.git/packed-refs /workspace/.git/packed-refs 2>/dev/null || true
            fi
            echo "Checking out PR #${DEV_PR_NUMBER}..."
            runuser -u dev -- bash -c \
                "cd /workspace && gh pr checkout -f ${DEV_PR_NUMBER} --repo ${DEV_TEMPLATE_KEY}" || true
            runuser -u dev -- bash -c \
                "gh pr view ${DEV_PR_NUMBER} --repo ${DEV_TEMPLATE_KEY} > /workspace/.pr 2>/dev/null" || true
        fi
    fi

    # Issue details (first run only)
    if [ -n "${DEV_ISSUE_NUMBER:-}" ]; then
        if ! [ -f /workspace/.issue ]; then
            runuser -u dev -- bash -c \
                "gh issue view ${DEV_ISSUE_NUMBER} --repo ${DEV_TEMPLATE_KEY} > /workspace/.issue 2>/dev/null" || true
        fi
    fi

    # Set up working branch (first run only — rename whatever PR/main branch to dev-auto/...)
    if ! runuser -u dev -- git -C /workspace rev-parse --verify "$_target_branch" &>/dev/null 2>&1; then
        runuser -u dev -- git -C /workspace branch -m "$_target_branch" 2>/dev/null || true
    fi
fi

# ── MCP server discovery (inject host IDE tools into container) ─────────────
if [[ -n "$HOST_IP" ]]; then
    _mcp_names=$(curl -sf --max-time 3 "http://${HOST_IP}:${PROXY_PORT}/mcp/config" 2>/dev/null) || true
    if [[ -n "$_mcp_names" && "$_mcp_names" != "[]" ]]; then
        _mcp_json=$(echo "$_mcp_names" | jq -r \
            --arg gw "host.internal" --arg port "$PROXY_PORT" \
            'reduce .[] as $name ({};
                . + {($name): {type: "sse", url: "http://\($gw):\($port)/mcp/\($name)/sse"}}
            )')

        _claude_json="/home/dev/.claude.json"
        jq --argjson mcp "$_mcp_json" '. + {mcpServers: $mcp}' "$_claude_json" \
            > "${_claude_json}.tmp" && mv "${_claude_json}.tmp" "$_claude_json"
        chown dev:dev "$_claude_json"

        _settings="/home/dev/.claude/settings.json"
        _perms=$(echo "$_mcp_names" | jq '[.[] | "mcp__\(.)__*(*)"]')
        jq --argjson p "$_perms" '.permissions.allow += $p' "$_settings" \
            > "${_settings}.tmp" && mv "${_settings}.tmp" "$_settings"
        chown dev:dev "$_settings"

        echo "MCP servers: $(echo "$_mcp_names" | jq -r 'join(", ")')"
    fi
fi

# ── Start sshd (for additional terminals via dev enter) ─────────────────────
# Port 2222: passt runs unprivileged and cannot bind ports below 1024,
# so sshd must use a non-privileged port for port forwarding to work.
(ssh-keygen -A &>/dev/null && /usr/sbin/sshd -p 2222 &>/dev/null) &

# ── Drop to dev user ────────────────────────────────────────────────────────
exec runuser -u dev -- sh -c 'cd /workspace 2>/dev/null; exec "$@"' _ "${@:-bash --login}"
