FROM registry.fedoraproject.org/fedora:44

# ── System packages ──────────────────────────────────────────────────────────
RUN dnf install -y \
        git git-lfs curl wget jq zip unzip findutils procps-ng hostname \
        diffutils less iproute iptables openssh-server \
        podman fuse-overlayfs e2fsprogs maven nodejs npm gh \
    && dnf clean all

# ── Non-root users with rootless-Podman support ──────────────────────────────
RUN useradd -m -u 1000 -s /bin/bash dev \
    && useradd -r -s /usr/sbin/nologin bobrunner \
    && echo "dev:100000:65536" >> /etc/subuid \
    && echo "dev:100000:65536" >> /etc/subgid

# ── Lock root, strip ALL setuid/setgid except newuidmap/newgidmap ───────────
# (newuidmap/newgidmap must keep setuid for rootless Podman / Testcontainers)
# Without this, the dev user could e.g. run "passwd root" to re-enable root.
RUN passwd -l root \
    && dnf remove -y sudo 2>/dev/null || true \
    && find / -xdev -perm /6000 -type f \
         ! -name newuidmap ! -name newgidmap ! -name fusermount3 \
         ! -name bob-run \
         -exec chmod ug-s {} + 2>/dev/null || true \
    && chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap

# ── Inner Podman configuration ───────────────────────────────────────────────
COPY configs/containers-storage.conf   /etc/containers/storage.conf
COPY configs/containers-registries.conf /etc/containers/registries.conf

# ── Allow non-root fuse-overlayfs with allow_root ────────────────────────────
RUN echo "user_allow_other" >> /etc/fuse.conf

# ── Claude Code (via official dnf repo) ──────────────────────────────────────
RUN printf '[claude-code]\nname=Claude Code\nbaseurl=https://downloads.claude.ai/claude-code/rpm/stable\nenabled=1\ngpgcheck=1\ngpgkey=https://downloads.claude.ai/keys/claude-code.asc\n' \
        > /etc/yum.repos.d/claude-code.repo \
    && dnf install -y claude-code && dnf clean all

# ── Bob Shell (npm — no dnf package available) ───────────────────────────────
RUN curl -fsSL https://bob.ibm.com/download/bobshell.sh | bash -s -- --pm npm

# ── Bob Shell secure launcher ────────────────────────────────────────────────
COPY bob-env-filter.c bob-run.c /tmp/build/
RUN dnf install -y gcc && \
    gcc -shared -fPIC -O2 -o /usr/local/lib/bob-env-filter.so /tmp/build/bob-env-filter.c -ldl \
    && gcc -O2 -o /usr/local/bin/bob-run /tmp/build/bob-run.c \
    && chown bobrunner:bobrunner /usr/local/bin/bob-run \
    && chmod 4711 /usr/local/bin/bob-run \
    && rm -rf /tmp/build \
    && dnf remove -y gcc && dnf clean all \
    && mv /usr/local/bin/bob /usr/local/bin/bob-real \
    && ln -s /usr/local/bin/bob-run /usr/local/bin/bob

# ── Bob Shell settings for dev ────────────────────────────────────────────────
COPY --chown=dev:dev configs/bob-settings.json /home/dev/.bob/settings.json
COPY --chown=dev:dev configs/bob-trusted-folders.json /home/dev/.bob/trustedFolders.json

# ── SDKMAN + JDK 21 Temurin (installed as dev) ──────────────────────────────
USER dev
RUN curl -s "https://get.sdkman.io" | bash \
    && bash -c "source /home/dev/.sdkman/bin/sdkman-init.sh && sdk install java 21-tem"
USER root

# ── SSH directory (keys injected at runtime, NEVER baked in) ─────────────────
RUN mkdir -p /home/dev/.ssh \
    && chmod 700 /home/dev/.ssh \
    && ssh-keyscan github.com >> /home/dev/.ssh/known_hosts 2>/dev/null \
    && chown -R dev:dev /home/dev/.ssh

# ── Fix tty error in krun (gnupg2.sh calls tty unconditionally) ──────────────
RUN sed -i 's|export GPG_TTY=$(tty)|export GPG_TTY=$(tty 2>/dev/null)|' /etc/profile.d/gnupg2.sh

# ── Claude Code sandbox settings ─────────────────────────────────────────────
COPY --chown=dev:dev configs/claude-settings.json /home/dev/.claude/settings.json
RUN echo '{"hasCompletedOnboarding":true,"hasAcceptedTerms":true,"hasSeenTasksHint":true,"numStartups":1,"autoUpdates":false,"effortLevel":"max","projects":{"/workspace":{"allowedTools":[],"hasTrustDialogAccepted":true},"/opt/workspace/keycloak":{"allowedTools":[],"hasTrustDialogAccepted":true},"/opt/workspace/quarkus":{"allowedTools":[],"hasTrustDialogAccepted":true}}}' > /home/dev/.claude.json \
    && chown dev:dev /home/dev/.claude.json

# ── Pre-baked project repos (shallow clone — workspace-ready) ────────────────
RUN mkdir -p /opt/workspace && chown dev:dev /opt/workspace
USER dev
RUN git clone --depth 1 --single-branch --branch main \
        https://github.com/keycloak/keycloak.git /opt/workspace/keycloak \
    && git clone --depth 1 --single-branch --branch main \
        https://github.com/quarkusio/quarkus.git /opt/workspace/quarkus
USER root

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY --chmod=755 entrypoint.sh /opt/dev/entrypoint.sh
ENTRYPOINT ["/opt/dev/entrypoint.sh"]

# ── Runtime defaults ─────────────────────────────────────────────────────────
ENV ANTHROPIC_API_KEY=sk-ant-api03-proxy-placeholder
ENV HISTFILE=/dev/null
RUN mkdir -p /workspace && chown dev:dev /workspace
WORKDIR /workspace
CMD ["bash", "--login"]
