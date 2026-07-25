# Dev Sandbox

This is imperfect AI sandboxing CLI tool good enough for my use cases. It is fast enough so that using it doesn't slow me down, but it is not intended for general use.

I know or guess (most) of its security limitations or false senses of safety and avoid taking risks in that areas. The idea here is that I don't have to learn better tools (like https://github.com/NVIDIA/OpenShell/, https://github.com/Sanne/incus-spawn) and I still get 99 % of what I do daily without risking my agents will affect my host environment.

This tool is (and will be even more) customized to automate my workflow and limit any repeated tasks.

## About this tool

Ephemeral, microVM-isolated dev containers for AI-assisted Java development. Each container runs in a krun microVM (KVM-backed), gets its own kernel, and has no access to your host filesystem or services.

## Security model

- **krun microVM** — hardware-isolated guest kernel
- **Non-root agent** — Claude Code and Bob Shell run as unprivileged `dev` user, cannot modify iptables or escalate
- **Host-side proxy** — Google Vertex AI credentials stay on the host; git push is bridged from container HTTP to GitHub SSH using the host's SSH key
- **Credential-free image** — only a read-only GitHub token, a container-only SSH key, and a Bob Shell API key are injected at runtime
- **No write credentials in container** — git push goes through the host proxy which adds auth; container has zero GitHub write access
- **Read-only GitHub token** — for `gh` CLI rate limits on public repos; cannot write to any repo
- **Bob Shell API key isolation** — the API key is never in the `dev` user's environment; a setuid launcher reads it from a protected file, `LD_PRELOAD` strips it from subprocess environments, and `PR_SET_DUMPABLE=0` blocks `/proc` inspection
- **Proxy firewall** — the host proxy binds to `0.0.0.0` (required by krun — `127.0.0.1` is unreachable from microVMs). A firewalld rule blocks external access to the proxy port (configured by install script)
- **MCP whitelist** — only explicitly whitelisted MCP servers are proxied into containers (see `MCP_WHITELIST` in `scripts/dev-proxy.py`)
- **Selective key mounting** — only specific key files are mounted into containers (container SSH pubkey, read-only GitHub PAT); host-only keys like `id_ed25519_dev_automation` never enter containers. The Bob API key is injected via `podman secret` (never volume-mounted)
- **Known limitation** — krun's minimal kernel has no firewall (iptables/nftables), so the container can reach host services

## Prerequisites

- Clone this repo to `~/sandboxing`: `git clone git@github.com:michalvavrik/ai-sandboxing.git ~/sandboxing`
- JetBrains features require IntelliJ IDEA and Gateway installed via Toolbox

## Setup

```bash
/home/mvavrik/sandboxing/scripts/dev-install.sh
source ~/.bashrc
```

The install script walks you through each step. Manual actions required (browser):
1. Add SSH key to GitHub (must be a different GitHub account than you use for your own work)
2. Create a short-lived fine-grained read-only PAT for public repos (used inside containers for `gh` CLI rate limits)
3. Create a Bob Shell API key at [bob.ibm.com](https://bob.ibm.com) with scope: Inference

The install script also configures a firewall rule to block external access to the proxy port (krun requires `0.0.0.0` binding — `127.0.0.1` is unreachable from microVMs).

## Usage

```bash
dev new fix-auth           # create container, enter it (detects project from cwd)
dev enter fix-auth         # re-enter an existing container
dev stop fix-auth          # stop (preserves state)
dev start fix-auth         # resume stopped container
dev delete fix-auth        # remove permanently
dev see fix-auth           # push from container, pull to host, show diff
dev cp ~/docs/analysis.md  # copy files/dirs into container's /tmp/workspace
dev cpout pom.xml          # copy from container (relative to /workspace)
dev cpout /tmp/file.txt    # copy from container (absolute path)
dev use fix-auth           # set current container without entering
dev idea                   # open container in IntelliJ IDEA via Gateway
dev list                   # show all dev containers

# From a GitHub issue or PR URL:
dev https://github.com/keycloak/keycloak/issues/50167
dev https://github.com/keycloak/keycloak/pull/50801

# Inside the container:
claude                     # start Claude Code (connects via host proxy)
bob                        # start Bob Shell (API key injected securely)
```

Container name is remembered — after `dev new foo`, just `dev enter`, `dev see`, `dev cp`, etc.
Use `dev use <name>` to set the current container from a different terminal.

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

## MCP server proxy

The host proxy can reverse-proxy MCP SSE servers running on the host into containers. Only whitelisted servers are proxied (see `MCP_WHITELIST` in `scripts/dev-proxy.py`). The entrypoint auto-discovers available servers and injects the `mcpServers` config into the container's Claude Code settings at startup.

## IntelliJ IDEA (via Gateway)

If you want to connect your IDE directly to a container (for interactive editing), `dev idea` opens JetBrains Gateway:

1. `dev idea` — opens Gateway, prints host name
2. In Gateway: **SSH Connection** → enter the host name shown, user `dev`, leave password empty
3. Select `/workspace` as the project directory
4. Gateway installs the backend and opens IntelliJ

## Projects

`configs/project-templates.conf` maps repos to source dirs and resources. Auto-detected from your current directory:

```bash
cd ~/sources/keycloak && dev new fix-auth   # → keycloak template (12GB RAM, 6 CPUs)
cd ~/sources/quarkus && dev new my-fix      # → quarkus template (16GB RAM, 8 CPUs)
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
│   ├── ADC stays here            ├── JDK 21 / Maven / Git / Claude Code / Bob Shell
│   ├── git push (HTTP→SSH) ◄──── git push (container HTTP, proxy bridges to GitHub SSH)
│   └── MCP SSE relay ◄────────── Claude Code (whitelisted host MCP servers)
├── ~/.m2/repository ──ro mount── ├── overlayfs .m2 (reads host, writes local)
└── keys/ (individual files)      ├── credentials (mounted per-file, not whole dir)
    ├── id_ed25519_dev_automation │   ├── id_ed25519_container.pub  (sshd authorized_keys)
    ├── id_ed25519_container      │   └── gh-pat-container          (read-only gh token)
    ├── gh-pat-container          └── podman secret
    └── ibm_bob_shell_api.key         └── bob-api-key → /run/bob-secrets/api.key (bobrunner:400)
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
