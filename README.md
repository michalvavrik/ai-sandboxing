# Dev Sandbox

This is imperfect AI sandboxing CLI tool good enough for my use cases. It is fast enough so that using it doesn't slow me down, but it is not intended for general use.

I know or guess (most) of its security limitations or false senses of safety and avoid taking risks in that areas. The idea here is that I don't have to learn better tools (like https://github.com/NVIDIA/OpenShell/, https://github.com/Sanne/incus-spawn) and I still get 99 % of what I do daily without risking my agents will affect my host environment.

This tool is (and will be even more) customized to automate my workflow and limit any repeated tasks.

## About this tool

Ephemeral, microVM-isolated dev containers for AI-assisted Java development. Each container runs in a krun microVM (KVM-backed), gets its own kernel, and has no access to your host filesystem or services.

## Security model

- **krun microVM** — hardware-isolated guest kernel
- **Non-root agent** — Claude runs as unprivileged `dev` user, cannot modify iptables or escalate
- **Vertex AI proxy** — Google credentials stay on the host, only API responses cross the boundary
- **Credential-free image** — SSH key and GitHub token injected at runtime, not baked in
- **Fine-grained GitHub token** — full access on agent's own forks, read-only on public repos, cannot create issues/PRs/comments on upstream projects, rotated periodically
- **Known limitation** — krun's minimal kernel has no firewall (iptables/nftables), so the container can reach host services (e.g., Proton Mail Bridge)

## Prerequisities

- features linked to Jetbrains only work if you have installed their Intellij Idea and Gateway apps, use Toolbox

## Setup

```bash
/home/mvavrik/sandboxing/scripts/dev-install.sh
source ~/.bashrc
```

The install script walks you through each step. Two manual actions required (browser):
1. Add SSH key to GitHub
2. Create two PATs (classic for install, fine-grained for containers)

IMPORTANT: must be a different GitHub account than you use for your own work

## Usage

```bash
dev new fix-auth           # create container, enter it (detects project from cwd)
dev enter fix-auth         # re-enter an existing container
dev stop fix-auth          # stop (preserves state)
dev start fix-auth         # resume stopped container
dev delete fix-auth        # remove permanently
dev see fix-auth           # push from container, pull to host, show diff
dev cp ~/docs/analysis.md  # copy files/dirs into container's /tmp/workspace
dev use fix-auth           # set current container without entering
dev idea                   # open container in IntelliJ IDEA via Gateway
dev list                   # show all dev containers

# From a GitHub issue or PR URL:
dev https://github.com/keycloak/keycloak/issues/50167
dev https://github.com/keycloak/keycloak/pull/50801

# Inside the container:
claude                     # start Claude Code (connects via host proxy)
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

## IntelliJ IDEA (via Gateway)

If you need to just review changes in your IDEA, for now it is much easier and quicker just do "dev see" in your project and then open your IDE in that directory.
However, if you require using MCP server or you want to connect your IDE to the container, you can follow this manual process:

`dev idea` opens JetBrains Gateway and prints the SSH connection details. Gateway auto-connect via URL doesn't work reliably, so the first connection per container is manual:

1. `dev idea` — opens Gateway, prints host name
2. In Gateway: **SSH Connection** → enter the host name shown, user `dev`, leave password empty
3. Select `/workspace` as the project directory
4. Gateway installs the backend and opens IntelliJ

Once connected, Claude Code inside the container auto-discovers the JetBrains MCP server.

## Projects

`configs/project-templates.conf` maps repos to source dirs and resources. Auto-detected from your current directory:

```bash
cd ~/sources/keycloak && dev new fix-auth   # → keycloak template (12GB RAM, 6 CPUs)
cd ~/sources/quarkus && dev new my-fix      # → quarkus template (16GB RAM, 8 CPUs)
```

## Keys

`keys/` is `.gitignored`. Contains:
- `id_ed25519_dev_automation` — SSH key for `michalvavrik-dev-automation`
- `gh-pat` — classic PAT (used by `dev install` only, never enters containers)
- `gh-pat-container` — fine-grained PAT (injected into containers, rotate periodically)

Token expiry warnings appear automatically when using `dev` commands.

## How it works

```
Host                              krun MicroVM
├── vertex-proxy.py ◄──────────── Claude Code (ANTHROPIC_BASE_URL)
│   └── ADC stays here            ├── JDK 21 / Maven / Git
├── ~/.m2/repository ──ro mount── ├── overlayfs .m2 (reads host, writes local)
└── keys/ ──────────── injected── └── SSH key + gh auth (ephemeral)
```
