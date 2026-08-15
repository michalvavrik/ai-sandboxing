FROM registry.fedoraproject.org/fedora:44

# ── System packages ──────────────────────────────────────────────────────────
RUN dnf install -y --setopt=retries=5 \
        git git-lfs curl wget jq zip unzip findutils procps-ng hostname \
        diffutils less iproute iptables openssh-server \
        podman fuse-overlayfs e2fsprogs maven nodejs npm gh \
        gcc gcc-c++ make java-devel podman-compose golang \
    && dnf clean all

# ── Non-root users with rootless-Podman support ─────────────────────────────
RUN useradd -m -u 1000 -s /bin/bash dev \
    && useradd -r -s /usr/sbin/nologin bobrunner \
    && echo "dev:100000:65536" >> /etc/subuid \
    && echo "dev:100000:65536" >> /etc/subgid

# ── Lock root, strip ALL setuid/setgid except newuidmap/newgidmap ────────────
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
    && dnf install -y --setopt=retries=5 claude-code && dnf clean all

# ── Antigravity CLI ──────────────────────────────────────────────────────────
USER dev
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash
USER root

# ── Bob Shell (npm — no dnf package available) ───────────────────────────────
RUN curl -fsSL https://bob.ibm.com/download/bobshell.sh | bash -s -- --pm npm

# ── Antigravity CLI usage marker (setuid root — tamper-proof flag for token revocation)
COPY agy-mark.c /tmp/build/
RUN gcc -O2 -o /usr/local/bin/agy-mark /tmp/build/agy-mark.c \
    && chmod 4711 /usr/local/bin/agy-mark \
    && rm -f /tmp/build/agy-mark.c \
    && printf '#!/bin/bash\n/usr/local/bin/agy-mark 2>/dev/null\nexec /home/dev/.local/bin/agy "$@"\n' > /usr/local/bin/agy \
    && chmod 755 /usr/local/bin/agy

# ── Bob Shell secure launcher ────────────────────────────────────────────────
COPY bob-env-filter.c bob-run.c /tmp/build/
RUN gcc -shared -fPIC -O2 -o /usr/local/lib/bob-env-filter.so /tmp/build/bob-env-filter.c -ldl \
    && gcc -O2 -o /usr/local/bin/bob-run /tmp/build/bob-run.c \
    && chown bobrunner:bobrunner /usr/local/bin/bob-run \
    && chmod 4711 /usr/local/bin/bob-run \
    && rm -rf /tmp/build \
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

# ── Go development tools ─────────────────────────────────────────────────────
RUN KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt) \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && KIND_VERSION=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name) \
    && curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" -o /usr/local/bin/kind \
    && chmod +x /usr/local/bin/kind \
    && HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name) \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -C /tmp -xzf - \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm && rm -rf /tmp/linux-amd64 \
    && TF_VERSION=1.15.8 \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin && rm /tmp/terraform.zip \
    && curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b /usr/local/bin

USER dev
RUN export GOPATH=/home/dev/go \
    && go install github.com/go-delve/delve/cmd/dlv@latest \
    && go install github.com/gotesttools/gotestfmt/v2/cmd/gotestfmt@latest \
    && go install golang.org/x/vuln/cmd/govulncheck@latest
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

# ── Antigravity CLI sandbox settings ─────────────────────────────────────────
RUN mkdir -p /home/dev/.gemini/antigravity-cli/cache \
    && echo '{"trustedWorkspaces":["/workspace","/opt/workspace/keycloak","/opt/workspace/quarkus"],"toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":true,"enableTelemetry":false,"model":"Gemini 3.1 Pro (High)"}' > /home/dev/.gemini/antigravity-cli/settings.json \
    && echo '{"consumerOnboardingComplete":true,"enterpriseOnboardingComplete":false,"onboardingComplete":true}' > /home/dev/.gemini/antigravity-cli/cache/onboarding.json \
    && chown -R dev:dev /home/dev/.gemini

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
