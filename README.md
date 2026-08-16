# Dev Sandbox

This is imperfect AI sandboxing CLI tool good enough for my use cases. It is fast enough so that using it doesn't slow me down, but it is not intended for general use.

I know or guess (most) of its security limitations or false senses of safety and avoid taking risks in that areas. The idea here is that I don't have to learn better tools (like https://github.com/NVIDIA/OpenShell/, https://github.com/Sanne/incus-spawn) and I still get 99 % of what I do daily without risking my agents will affect my host environment.

This tool is (and will be even more) customized to automate my workflow and limit any repeated tasks.

## About this tool

Ephemeral, microVM-isolated dev containers for AI-assisted development. Each container runs in a krun microVM (KVM-backed), gets its own kernel, and has no access to your host filesystem or services. A single container image ships both Java and Go toolchains; the template's `profiles` field controls runtime behavior (Kind cluster, Maven cache, environment).

## Security model

- **krun microVM** — hardware-isolated guest kernel
- **Non-root agent** — Claude Code, Bob Shell, and Antigravity CLI run as unprivileged `dev` user, cannot modify iptables or escalate
- **Host-side proxy** — Google Vertex AI credentials stay on the host; git push is bridged from container HTTP to GitHub SSH using the host's SSH key
- **Credential-free image** — only a read-only GitHub token, a container-only SSH key, and a Bob Shell API key are injected at runtime
- **No write credentials in container** — git push goes through the host proxy which adds auth; container has zero GitHub write access
- **Antigravity CLI OAuth tokens are exposed to the agent** — stored in plaintext on the container filesystem, readable by model-invoked tool calls. `dev delete` revokes the token automatically via Google's revocation endpoint. A setuid `agy-mark` binary writes a root-owned flag (`/mnt/bounded/agy-used`) on first launch — the agent cannot delete it, so `dev delete` reliably detects usage even if the agent deleted the token file (warns with manual revocation URL). The token is read from the bounded disk image via `debugfs` on the host — no VM restart needed
- **Per-container branch isolation** — each container gets a unique proxy port (9223+), locked by nftables. The proxy only allows `git push` to `dev-auto/<container-name>` and sub-branches. The agent cannot push to other containers' branches or upstream branches. Port assignment survives container stop/start; released on `dev delete`
- **Read-only GitHub token** — for `gh` CLI rate limits on public repos; cannot write to any repo
- **Bob Shell API key isolation** — the API key is never in the `dev` user's environment; a setuid launcher reads it from a protected file, `LD_PRELOAD` strips it from subprocess environments, and `PR_SET_DUMPABLE=0` blocks `/proc` inspection
- **Per-container disk caps** — each container gets two bounded ext4 loopback files on the host: one for workspace/builds (default 15–30 GiB), one for inner Testcontainers images (6 GiB). Both are locked (`root:600`) inside the VM so the agent can't extend them. Filling one doesn't corrupt the other. The container refuses to start if either disk image is missing. Cleaned up automatically by `dev delete`; orphans from raw `podman rm` are pruned on the next delete. **Caveats:** (1) caps cover `/workspace`, `/home/dev`, `/tmp`, `/var`, and inner podman storage — remaining system paths (`/etc`, `/opt`) are `root:755` so the `dev` user cannot write there without root escalation; (2) caps rely on the agent not escalating to real VM root — the attack surface is three setuid binaries (`newuidmap`, `newgidmap`, `fusermount3`); a CVE in any would let the agent unlock the files. Even then, the KVM boundary still contains the agent
- **Rootless inner Podman** — Testcontainers runs via rootless Podman inside the VM. User-namespace isolation prevents the agent from reading root-owned files, modifying nftables, or escalating privileges — even with `--privileged --net=host` on inner containers
- **Host-side FD limit** — `dev install` raises the host user's nofile limit to 4M and each container sets `--ulimit nofile=4194304` on the krun host process, because virtiofsd holds a host FD per cached guest inode. This affects all processes of the host user, not just containers. At worst case (~1-2 GB host kernel memory per container), running many containers simultaneously could pressure the host's system-wide file table. A dedicated system user for running containers would isolate this (planned for future)
- **Guest firewall** — nftables rules restrict outbound traffic to DNS, the auth proxy, and HTTPS (port 443). All other outbound is dropped. Loopback is fully open for test servers
- **Proxy firewall** — the host proxy binds to `0.0.0.0` (required — `127.0.0.1` is unreachable from krun/passt microVMs). A firewalld rule blocks external access to the proxy port (configured by install script)
- **MCP whitelist** — only explicitly whitelisted MCP servers are proxied into containers (see `MCP_WHITELIST` in `scripts/dev-proxy.py`)
- **Selective key mounting** — only specific key files are mounted into containers (container SSH pubkey, read-only GitHub PAT); host-only keys like `id_ed25519_dev_automation` never enter containers. The Bob API key is injected via `podman secret` (never volume-mounted)

## Prerequisites

- Clone this repo to `~/sandboxing`: `git clone git@github.com:michalvavrik/ai-sandboxing.git ~/sandboxing`

## Configuration

All machine-specific values live in `config.local` (gitignored). The install script creates a template on first run — fill it in before proceeding:

| Variable               | Purpose                                       |
|------------------------|-----------------------------------------------|
| `DEV_AUTOMATION_USER`  | GitHub account for the automation agent       |
| `DEV_AUTOMATION_EMAIL` | Git commit email inside containers            |
| `DEV_AUTOMATION_NAME`  | Git commit author name inside containers      |
| `DEV_GHCR_USER`        | GitHub username for GHCR image pulls          |
| `DEV_IMAGE`            | Container image to pull and run               |
| `DEV_SOURCES_DIR`      | Parent directory for project source checkouts |
| `DEV_PROXY_PORTS`      | Number of proxy ports (default 5, = 4 container slots). Re-run `dev install` after changing to update firewall rules |

Project-specific source dirs in `configs/project-templates.conf` are relative to `DEV_SOURCES_DIR`.

### Background image pull and source fetch

A systemd user service (`dev-pull.service`) runs on graphical login and:
1. Pulls newer container images for all language variants
2. Fetches latest sources for all template projects under `DEV_SOURCES_DIR` — if the default branch is checked out, it stashes local changes, rebases, and pops the stash; otherwise it fast-forwards the local main ref without touching the worktree

This means `dev new` never waits for a pull — it uses whatever image and source are already local.
Run `dev pull` manually after pushing Containerfile changes to force an immediate update.

## Setup

```bash
~/sandboxing/scripts/dev-install.sh
source ~/.bashrc
```

The install script walks you through each step. Manual actions required (browser):
1. Add SSH key to GitHub (must be a different GitHub account than you use for your own work)
2. Create a short-lived fine-grained read-only PAT for public repos (used inside containers for `gh` CLI rate limits)
3. Create a Bob Shell API key at [bob.ibm.com](https://bob.ibm.com) with scope: Inference

The install script also configures a firewall rule to block external access to the proxy port (`0.0.0.0` binding is required — `127.0.0.1` is unreachable from krun/passt microVMs due to crun passing `--no-map-gw` to passt).

## Usage

```bash
dev new fix-auth           # create container, enter it (detects project from cwd)
dev enter fix-auth         # re-enter an existing container
dev stop fix-auth          # stop (preserves state)
dev start fix-auth         # resume stopped container
dev recreate fix-auth      # fresh container, preserves workspace and Claude session
dev delete fix-auth        # remove permanently
dev see fix-auth           # push from container, pull to host (squashes commits)
dev see --dont-squash      # same but keeps full commit history
dev show fix-auth          # push host changes into container
dev push fix-auth          # sync agent's work to original branch and push
dev rebase fix-auth        # rebase container workspace on latest upstream main
dev cp ~/docs/analysis.md  # copy files/dirs into container's /tmp/workspace
dev cp --to /workspace f.patch # copy into a specific container directory
dev cpout pom.xml          # copy from container (relative to /workspace)
dev cpout /tmp/file.txt    # copy from container (absolute path)
dev cpout --to ~/review src # copy from container into a specific host directory
dev review fix-auth        # run headless agent review (--agent=claude|bob|agy)
dev use fix-auth           # set current container without entering
dev list                   # show all dev containers
dev pull                   # pull newer image (runs in background on login)

# From the current git project directory:
cd ~/sources/keycloak && dev .   # detect template, push local HEAD to container

# From a GitHub issue, PR, or branch URL:
dev https://github.com/keycloak/keycloak/issues/50167
dev https://github.com/keycloak/keycloak/pull/50801
dev https://github.com/your-user/keycloak-client/tree/my-branch

# Inside the container:
claude                     # start Claude Code (permissions bypassed via env var)
bob                        # start Bob Shell (API key injected securely)
agy                        # start Antigravity CLI (Google Gemini models)
```

Container name is remembered — after `dev new foo`, just `dev enter`, `dev see`, `dev cp`, etc.
Use `dev use <name>` to set the current container from a different terminal.
When multiple containers exist, commands resolve by cwd: `cd ~/sources/quarkus && dev see` picks the quarkus container if exactly one matches.

## Antigravity CLI (Google Gemini models)

On first run inside a container, `agy` detects the SSH environment and prints an auth URL — open it in your host browser, sign in with your Google account, and paste the code back. Subsequent runs use cached tokens.

Google OAuth tokens live in plaintext inside the container — the agent can read them. `dev delete` revokes the token; always verify revocation or check `myaccount.google.com/permissions`.

## Local project workflow

```bash
# 1. Start — push your branch to an agent container
cd ~/sources/keycloak && git checkout my-feature
dev .
# → creates container keycloak-my-feature, you're inside it
# → uncommitted changes included (temporary WIP commit, reset after push)

# 2. Work with the agent
claude

# 3. Review — pull agent's changes to host
dev see                    # syncs to dev-auto/keycloak-my-feature/main

# 4. Edit locally, then push back to the container
dev show                   # pushes host edits into the container
dev .                      # alternative: re-syncs and re-enters

# Repeat steps 2–4 as needed

# If upstream main has advanced:
dev rebase                 # fetch upstream main and rebase workspace on top of it

# 5. Finish — land on your branch and push
dev push                   # squashes to one commit on my-feature, pushes to your remote
dev push --local           # same but skip the push
```

`dev push` creates a single commit on the original branch using the original commit message, your git identity, and signoff. If the agent branch has uncommitted changes or multiple commits, they are squashed first. Works from any directory — resolves the source directory from container metadata.

`dev-auto/` branches from `dev see` reuse the original container name when passed to `dev .`. Before `dev see` or `dev show` replaces a branch, its state is backed up to a timestamped branch. All agent branches are cleaned up by `dev delete`.

Works with PRs — `dev push` lands on the PR's head branch:

```bash
dev https://github.com/keycloak/keycloak/pull/50801
# ... agent work, dev see/show cycle ...
dev push                   # pushes to the PR's head branch
```

## PR review workflow

```bash
dev https://github.com/keycloak/keycloak/pull/50801
# → creates keycloak-pr-50801, checks out the PR branch, saves PR details to .pr
# → you're inside the container

claude
# → give your prompt: "thoroughly analyze https://github.com/keycloak/keycloak/pull/50801 ..."

# PR got updated? Just re-enter — it re-checkouts automatically:
dev https://github.com/keycloak/keycloak/pull/50801
```

## Headless review

Run an AI review without entering the container — output streams to your terminal:

```bash
# Review a PR (sets up container like `dev <url>`, then runs agent)
dev review https://github.com/keycloak/keycloak/pull/50801

# Review in an existing container
dev review keycloak-pr-50801

# Review the current container
dev review

# Follow-up question (continues the review session)
dev review "what about thread safety in the token store?"

# Use a different agent
dev review --agent=bob https://github.com/keycloak/keycloak/pull/50801
dev review --agent=agy keycloak-pr-50801

# Custom prompt (replaces agent-specific template, base kept)
dev review --prompt "focus only on security issues"

# Append to the default prompt
dev review --append-to-prompt "also check for Java 21 API usage"
```

Review prompts use a two-layer system in `configs/review-prompts/`:
- `base.txt` — shared context instructions (always included)
- `claude.txt`, `bob.txt`, `agy.txt` — agent-specific personality/style

Edit these files to improve prompts over time. `--prompt` replaces only the agent-specific part; `--append-to-prompt` appends to the combined prompt.

For interactive follow-up (when headless isn't enough): `dev enter` then `claude -r <session-id>` to resume the review session. The session ID is printed at the end of each review.

## MCP server proxy

The host proxy can reverse-proxy MCP SSE servers running on the host into containers. Only whitelisted servers are proxied (see `MCP_WHITELIST` in `scripts/dev-proxy.py`). The entrypoint auto-discovers available servers and injects the `mcpServers` config into the container's Claude Code settings at startup.

## Projects

`configs/project-templates.conf` maps `org/repo` to source dir, resources, disk caps, and profiles. Template detection (first match wins):

1. **GitHub URL** — `dev https://github.com/keycloak/keycloak-client/pull/42` → exact `org/repo` from URL
2. **`dev .`** — `cd ~/sources/keycloak && dev .` → matches template whose `source_dir` contains the cwd (requires non-DEFAULT match and a git branch)
3. **cwd** — `cd ~/sources/keycloak-client && dev new fix` → matches template whose `source_dir` contains the cwd
4. **Name heuristic** — `dev new keycloak-client-fix` → longest repo name matching the container name or its prefix
5. **DEFAULT** — fallback when nothing matches

```bash
dev new keycloak-client              # → keycloak-client template (profiles: java)
dev new keycloak-client-my-feature   # → keycloak-client template (prefix match, beats shorter "keycloak")
cd ~/sources/quarkus && dev new foo  # → quarkus template (profiles: java)
cd ~/sources/camel-k && dev new bar  # → camel-k template (profiles: go,kind)
```

### Pre-installed toolchains

Every container ships both Java and Go stacks:
- **Java:** SDKMAN + JDK 21 Temurin, Maven
- **Go:** Go SDK, kubectl, Kind, Helm, Terraform, golangci-lint, Delve, gotestfmt, govulncheck
- **Shared:** Git, gcc/g++, Make, podman-compose, Claude Code, Bob Shell, Antigravity CLI

Projects pre-baked into the image (keycloak, quarkus) start instantly. Other templates clone from the host source on first start.

### Profiles

The `profiles` field in `project-templates.conf` is a comma-separated list that controls runtime behavior:

| Profile | Effect |
|---------|--------|
| `java`  | Maven cache overlay from host `~/.m2/repository` |
| `go`    | Sets GOPATH, GOBIN, adds `~/go/bin` to PATH |
| `kind`  | Auto-creates a Kind cluster with local registry (`localhost:5001`) on first start, 12 GiB podman storage |

```bash
# camel-k (profiles: go,kind):
make build                    # build everything (codegen + tests + CLI)
make images                   # build operator image
podman tag apache/camel-k:2.11.0-SNAPSHOT localhost:5001/camel-k:dev
podman push localhost:5001/camel-k:dev
make install-k8s-global       # install operator on Kind cluster
make test-smoke               # run e2e smoke tests

# terraform-provider-keycloak (profiles: go):
make local                    # start Keycloak via podman-compose
make test                     # unit tests
make testacc                  # acceptance tests
```

## Keys

`keys/` is `.gitignored`. Contains:
- `id_ed25519_dev_automation` — GitHub SSH key (host only, used by proxy for git push to agent's forks, **never enters containers**)
- `id_ed25519_container` — container-only SSH key for sshd access (not authorized on GitHub; only the `.pub` is mounted)
- `gh-pat-container` — short-lived read-only fine-grained PAT for public repos (injected into containers for `gh` CLI rate limits)
- `ibm_bob_shell_api.key` — IBM Bob Shell API key (injected via podman secret, never volume-mounted; readable only by `bobrunner` user inside containers)

Token expiry warnings appear automatically when using `dev` commands.

### Bob Shell API key setup

The Bob API key is injected via `podman secret` (never as a volume mount). Handled automatically by `dev install`.

To rotate: `podman secret rm bob-api-key`, replace `keys/ibm_bob_shell_api.key`, re-run `dev install`.

## How it works

```
Host                              krun MicroVM
├── dev-proxy.py ◄─────────────── Claude Code (Vertex AI requests)
│   ├── ADC stays here            ├── JDK 21 / Maven / Go SDK / Kind / kubectl / Terraform
│   ├── git push (HTTP→SSH) ◄──── git push (container HTTP, proxy bridges to GitHub SSH)
│   └── MCP SSE relay ◄────────── Claude Code (whitelisted host MCP servers)
├── ~/.m2/repository ──ro mount── ├── overlayfs .m2 (profile: java)
│   (profile: java only)         ├── Kind cluster (profile: kind, auto-created on first start)
├── podman storage ────ro mount── ├── additionalimagestores (host images available without pulling)
├── keys/ (individual files)      ├── credentials (mounted per-file, not whole dir)
│   ├── id_ed25519_dev_automation │   ├── id_ed25519_container.pub  (sshd authorized_keys)
│   ├── id_ed25519_container      │   └── gh-pat-container          (read-only gh token)
│   ├── gh-pat-container          ├── podman secret
│   └── ibm_bob_shell_api.key    │   └── bob-api-key → /run/bob-secrets/api.key (bobrunner:400)
└── dev-sandbox-disks/            └── bounded loopback disks (ext4, root:600 inside VM)
    ├── <name>.img (workspace)        ├── /mnt/bounded → /workspace, /home/dev, /tmp, /var
    └── <name>-podman.img             └── /mnt/podman  → rootless Podman storage
        (6 GiB java, 12 GiB go)          (Testcontainers / Kind nodes)
```

### Bob Shell credential isolation

```
dev runs: bob
  → symlink to bob-run (setuid bobrunner, mode 4711)
  → reads /run/bob-secrets/api.key (bobrunner:400)
  → sets BOBSHELL_API_KEY + LD_PRELOAD in process memory
  → drops back to dev (setresuid)
  → exec bob-real
  → LD_PRELOAD constructor restores PR_SET_DUMPABLE=0 (kernel resets it during exec)

Result:
  ├── Bob process runs as dev (full workspace access)
  ├── /proc/<pid>/environ unreadable (PR_SET_DUMPABLE=0)
  ├── Child processes don't inherit API key (LD_PRELOAD strips it)
  └── Key file unreadable by dev (owned by bobrunner)
```

## Auto-backup

Every 30 seconds, a background process snapshots the workspace (including uncommitted and untracked files) and pushes to `dev-auto/<name>/backup` on the remote without affecting the workspace.
