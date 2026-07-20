FROM registry.fedoraproject.org/fedora:44

# ── System packages ──────────────────────────────────────────────────────────
RUN dnf install -y \
        git git-lfs curl wget jq zip unzip findutils procps-ng hostname \
        diffutils less iproute iptables openssh-server \
        podman fuse-overlayfs maven nodejs npm gh \
    && dnf clean all

# ── Non-root user with rootless-Podman support ───────────────────────────────
RUN useradd -m -u 1000 -s /bin/bash dev \
    && echo "dev:100000:65536" >> /etc/subuid \
    && echo "dev:100000:65536" >> /etc/subgid

# ── Lock root, strip ALL setuid/setgid except newuidmap/newgidmap ───────────
# (newuidmap/newgidmap must keep setuid for rootless Podman / Testcontainers)
# Without this, the dev user could e.g. run "passwd root" to re-enable root.
RUN passwd -l root \
    && dnf remove -y sudo 2>/dev/null || true \
    && find / -xdev -perm /6000 -type f \
         ! -name newuidmap ! -name newgidmap ! -name fusermount3 \
         -exec chmod ug-s {} + 2>/dev/null || true

# ── Inner Podman configuration ───────────────────────────────────────────────
COPY configs/containers-storage.conf   /etc/containers/storage.conf
COPY configs/containers-registries.conf /etc/containers/registries.conf

# ── Allow non-root fuse-overlayfs with allow_root ────────────────────────────
RUN echo "user_allow_other" >> /etc/fuse.conf

# ── Claude Code (installed globally as root) ─────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code

# ── SDKMAN + JDK 21 Temurin (installed as dev) ──────────────────────────────
USER dev
RUN curl -s "https://get.sdkman.io" | bash \
    && bash -c "source /home/dev/.sdkman/bin/sdkman-init.sh && sdk install java 21-tem"
USER root

# ── Git identity for dev ─────────────────────────────────────────────────────
RUN git config --system user.email "dev-automation@michalvavrik.net" \
    && git config --system user.name  "Michal Vavřík Dev Automation"

# ── SSH directory (keys injected at runtime, NEVER baked in) ─────────────────
RUN mkdir -p /home/dev/.ssh \
    && chmod 700 /home/dev/.ssh \
    && ssh-keyscan github.com >> /home/dev/.ssh/known_hosts 2>/dev/null \
    && chown -R dev:dev /home/dev/.ssh

# ── Claude Code sandbox settings ─────────────────────────────────────────────
COPY --chown=dev:dev configs/claude-settings.json /home/dev/.claude/settings.json

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY --chmod=755 entrypoint.sh /opt/dev/entrypoint.sh
ENTRYPOINT ["/opt/dev/entrypoint.sh"]

# ── Runtime defaults ─────────────────────────────────────────────────────────
ENV ANTHROPIC_API_KEY=not-used
ENV HISTFILE=/dev/null
RUN mkdir -p /workspace && chown dev:dev /workspace
WORKDIR /workspace
CMD ["bash", "--login"]
