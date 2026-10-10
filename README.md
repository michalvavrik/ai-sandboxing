# Dev Sandbox

This is imperfect AI sandboxing CLI tool good enough for my use cases. It is fast enough so that using it doesn't slow me down, but it is not intended for general use.

I know or guess (most) of its security limitations or false senses of safety and avoid taking risks in that areas. The idea here is that I don't have to learn better tools (like https://github.com/NVIDIA/OpenShell/, https://github.com/Sanne/incus-spawn) and I still get 99 % of what I do daily without risking my agents will affect my host environment.

This tool is (and will be even more) customized to automate my workflow and limit any repeated tasks.

## About this tool

Ephemeral, microVM-isolated dev containers for AI-assisted development. Each container runs in a krun microVM (KVM-backed), gets its own kernel, and has no access to your host filesystem or services. A single container image ships both Java and Go toolchains; the template's `profiles` field controls runtime behavior (Kind cluster, Maven cache, environment).

## Security model

- **krun microVM** — hardware-isolated guest kernel
- **Non-root agent** — Claude Code, Bob Shell, and Antigravity CLI run as unprivileged `dev` user, cannot modify iptables or escalate
- **Host-side proxy** — the Claude subscription token and Google Vertex AI credentials stay on the host; git push is bridged from container HTTP to GitHub SSH using the host's SSH key
- **Credential-free image** — only a read-only GitHub token, a container-only SSH key, and a Bob Shell API key are injected at runtime
- **No write credentials in container** — git push goes through the host proxy which adds auth; container has zero GitHub write access
- **Antigravity CLI OAuth tokens are exposed to the agent** — stored in plaintext on the container filesystem, readable by model-invoked tool calls. `dev delete` revokes the token automatically via Google's revocation endpoint. A setuid `agy-mark` binary writes a root-owned flag (`/mnt/bounded/agy-used`) on first launch — the agent cannot delete it, so `dev delete` reliably detects usage even if the agent deleted the token file (warns with manual revocation URL). The token is read from the bounded disk image via `debugfs` on the host — no VM restart needed
- **Per-container branch + repo isolation** — each container gets a unique proxy port (9223+), locked by nftables. The proxy only allows `git push` to `dev-auto/<container-name>` and sub-branches, and only on that container's own fork repo. The agent cannot push to other containers' branches, to any other repo the automation key can reach, or to upstream branches. Port assignment survives container stop/start; released on `dev delete`
- **Read-only GitHub token** — for `gh` CLI rate limits on public repos; cannot write to any repo
- **Bob Shell API key isolation** — the API key is never in the `dev` user's environment; a setuid launcher reads it from a protected file, `LD_PRELOAD` strips it from subprocess environments, and `PR_SET_DUMPABLE=0` blocks `/proc` inspection
- **Per-container disk caps** — each container gets two bounded ext4 loopback files on the host: one for workspace/builds (default 15–30 GiB), one for inner Testcontainers images (6 GiB). Both are locked (`root:600`) inside the VM so the agent can't extend them. Filling one doesn't corrupt the other. The container refuses to start if either disk image is missing. Cleaned up automatically by `dev delete`; orphans from raw `podman rm` are pruned on the next delete. **Caveats:** (1) caps cover `/workspace`, `/home/dev`, `/tmp`, `/var`, and inner podman storage — remaining system paths (`/etc`, `/opt`) are `root:755` so the `dev` user cannot write there without root escalation; (2) caps rely on the agent not escalating to real VM root — the attack surface is three setuid binaries (`newuidmap`, `newgidmap`, `fusermount3`); a CVE in any would let the agent unlock the files. Even then, the KVM boundary still contains the agent
- **Rootless inner Podman** — Testcontainers runs via rootless Podman inside the VM. User-namespace isolation prevents the agent from reading root-owned files, modifying nftables, or escalating privileges — even with `--privileged --net=host` on inner containers
- **Host-side FD limit** — `dev install` raises the host user's nofile limit to 4M and each container sets `--ulimit nofile=4194304` on the krun host process, because virtiofsd holds a host FD per cached guest inode. This affects all processes of the host user, not just containers. At worst case (~1-2 GB host kernel memory per container), running many containers simultaneously could pressure the host's system-wide file table. A dedicated system user for running containers would isolate this (planned for future)
- **Guest firewall (fail-closed)** — nftables rules restrict outbound traffic to DNS, the auth proxy, and HTTPS (port 443); all other outbound is dropped, loopback is open for test servers. The firewall only works with passt (a real interface — under TSI egress bypasses netfilter), so the container **refuses to start** unless passt's default route is up and the ruleset applies atomically; it never runs the agent believing it is confined when it is not
- **Proxy firewall** — the host proxy binds to `0.0.0.0` (required — `127.0.0.1` is unreachable from krun/passt microVMs). A firewalld rule blocks external access to the proxy port (configured by install script)
- **Sandboxed proxy** — `dev-proxy.py` holds the real credentials and parses untrusted guest traffic, so it runs in a bubblewrap jail (tmpfs `$HOME`) that exposes only its script, the two keys it uses (not the rest of `keys/`), the gcloud ADC and `~/.claude.json`, the runtime dir, and the network — a compromise can't read the rest of `$HOME` or the other keys. Fail-closed: without `bwrap` the proxy refuses to start (it is installed by `dev install`)
- **MCP whitelist** — only explicitly whitelisted MCP servers are proxied into containers (see `MCP_WHITELIST` in `scripts/dev-proxy.py`)
- **Selective key mounting** — only specific key files are mounted into containers (container SSH pubkey, read-only GitHub PAT); host-only keys like `id_ed25519_dev_automation` never enter containers. The Bob API key is injected via `podman secret` (never volume-mounted)

### The `kind` profile weakens in-VM isolation

Containers using the `kind` profile (no bundled template currently uses it) auto-create a Kubernetes cluster with **rootful podman inside the VM**. This is required, not a shortcut: the `kindest/node` image runs systemd, which needs a root-owned cgroup that the unprivileged `dev` user cannot create — this microVM has no systemd/cgroup delegation, so rootless Kind cannot boot here. (Also, the node's kubelet needs a real block device for its rootfs, so Kind/registry storage is pinned to the bounded podman disk rather than the virtiofs root.)

**Consequence — for these containers, treat the `dev`-vs-root boundary *inside the VM* as gone.** Kind's kubeconfig is cluster-admin, so the agent has a practical, non-exploit path to VM-root (cluster-admin → privileged pod → node container, which runs as VM-root). That means:

- The per-container disk caps and root-owned config (guest nftables firewall, `/etc`, `/opt`, the Bob API key file) are no longer protected from the agent.
- **Residual host risk:** a VM-root agent can write to the container's *uncapped* writable rootfs layer on the host, which could fill the host disk (DoS). Kind/registry image storage itself stays capped (pinned to the bounded podman disk).

**What is _not_ affected:** the KVM boundary still fully contains the VM. Your host filesystem, Google Vertex credentials, and the GitHub-write SSH key never enter the VM, so they remain protected even against a VM-root agent. Non-`kind` containers keep the full rootless posture described above.

**Functional limits (libkrun kernel ceiling).** The cluster runs on the microVM's libkrun kernel, which lacks netfilter features kube-proxy needs. iptables mode is fully broken (missing `xt_comment`/`xt_conntrack`); the entrypoint uses `nftables` mode, which is better — the control plane is healthy and CoreDNS pods reach the API server — but it still **cannot program multi-endpoint Services** (kernel lacks `numgen`), and since kube-proxy applies its ruleset atomically per sync, ClusterIP Services with more than one backing pod never program. In testing, pod → cluster-DNS (the default two-replica service) resolution failed 8/8. So **in-cluster Service networking / DNS is effectively non-functional out of the box.** Treat the `kind` profile as a **control-plane / manifest-testing** environment — `kubectl`, CRDs, applying resources, the local registry — **not** a place to run pod-to-pod Service networking or e2e. Run real e2e in CI or a real cluster.

## Prerequisites

- Clone this repo to `~/sandboxing`: `git clone git@github.com:michalvavrik/ai-sandboxing.git ~/sandboxing`

## Configuration

All machine-specific values live in `config.local` (gitignored). The install script creates a template on first run — fill it in before proceeding:

| Variable               | Purpose                                       |
|------------------------|-----------------------------------------------|
| `DEV_AUTOMATION_USER`  | GitHub account for the automation agent       |
| `DEV_AUTOMATION_EMAIL` | Git commit email inside containers            |
| `DEV_AUTOMATION_NAME`  | Git commit author name inside containers      |
| `DEV_GHCR_USER`        | GitHub username for GHCR image pulls and branch backups |
| `DEV_IMAGE`            | Container image to pull and run               |
| `DEV_SOURCES_DIR`      | Parent directory for project source checkouts |
| `DEV_PROXY_PORTS`      | Number of proxy ports (default 5, = 4 container slots). Re-run `dev install` after changing to update firewall rules |
| `DEV_AUTH_METHOD`      | Claude Code auth for new containers: `api-key` (default, Claude subscription) or `vertex`. See [Claude auth and models](#claude-auth-and-models) |
| `DEV_SUBSCRIPTION_MODEL` | Default Claude model in `api-key` containers (default `opus` = latest Opus) |
| `DEV_VERTEX_OPUS_MODEL`, `DEV_VERTEX_FABLE_MODEL` | What `opus` / `fable` mean in `vertex` containers (opus defaults to the model in `configs/claude-settings.json`; fable has no default, so Fable is skipped on Vertex unless set) |
| `DEV_AGY_FLASH_MODEL`, `DEV_AGY_PRO_MODEL` | Pin the Antigravity models behind `flash` / `pro` (default: newest `*-flash-high` / `*-pro-high` from `agy models`) |
| `DEV_LOOP_NORMAL`, `DEV_LOOP_BEST`, `DEV_LOOP_ALL` | Override the review loop profiles (comma-separated reviewer lists) |

Project-specific source dirs in `configs/project-templates.conf` are relative to `DEV_SOURCES_DIR`.

### Background sync

A systemd user service (`dev-pull.service`) runs on graphical login and executes `dev sync`, which:
1. Pulls newer container images for all language variants
2. Fetches latest sources for all template projects under `DEV_SOURCES_DIR`
3. Prunes dead branches on the host and on the automation fork (see [Branch lifecycle](#branch-lifecycle) below)

This means `dev new` never waits for a pull — it uses whatever image and source are already local.
Run `dev sync` manually to force an immediate update and branch cleanup.

## Setup

```bash
~/sandboxing/scripts/dev-install.sh
source ~/.bashrc
```

The install script adds one line to `~/.bashrc` — `source ~/sandboxing/scripts/dev-shell-init.sh` — which defines the `dev` command and its tab completion. Both live in the repo, so `git pull` updates them; `~/.bashrc` never needs editing again.

The install script walks you through each step. Manual actions required (browser):
1. Add SSH key to GitHub (must be a different GitHub account than you use for your own work)
2. Create a short-lived fine-grained read-only PAT for public repos (used inside containers for `gh` CLI rate limits)
3. Create a Bob Shell API key at [bob.ibm.com](https://bob.ibm.com) with scope: Inference

The install script also configures a firewall rule to block external access to the proxy port (`0.0.0.0` binding is required — `127.0.0.1` is unreachable from krun/passt microVMs due to crun passing `--no-map-gw` to passt).

## Usage

```bash
dev new fix-auth           # create container, enter it (detects project from cwd)
dev enter fix-auth         # (re-)enter an existing container, starting it if stopped
dev recreate fix-auth      # fresh container, preserves workspace and Claude session
dev delete fix-auth        # save workspace to dev-auto/<name>/main, then remove (--dont-sync to skip)
dev see fix-auth           # fetch the container's workspace, check out dev-auto/<name>/main on the host
dev show fix-auth          # push the host's current branch into the container (dev-auto/*, in-review/*, wip/*)
dev merge                  # one new commit by you on in-review/<feature> from the last dev see (asks for the message)
dev merge -m "message"     # same, message given
dev squash                 # fold the last dev see into the HEAD commit of in-review/<feature>
dev rebase fix-auth        # rebase container workspace on latest upstream main
dev cp ~/docs/analysis.md  # copy files/dirs into container's /tmp/workspace
dev cp --to /workspace f.patch # copy into a specific container directory
dev cpout pom.xml          # copy from container (relative to /workspace)
dev cpout /tmp/file.txt    # copy from container (absolute path)
dev cpout --to ~/review src # copy from container into a specific host directory
dev review fix-auth        # headless review (default: claude; --agent=claude|bob|agy, --model=opus|fable|flash|pro)
dev review --loop          # multi-model review loop (normal = bob, flash, opus; also best, all, or a list)
dev use fix-auth           # set current container without entering
dev list                   # show all dev containers
dev pull                   # pull newer images and fetch sources
dev sync                   # pull + prune dead branches (host and automation fork)

# From the current git project directory:
cd ~/sources/keycloak && dev .   # detect template, push local HEAD to container

# From a GitHub issue, PR, or branch URL:
dev https://github.com/keycloak/keycloak/issues/50167
dev https://github.com/keycloak/keycloak/pull/50801
dev https://github.com/your-user/keycloak-client/tree/my-branch
dev https://github.com/keycloak/keycloak/pull/50801 --loop        # set up the container and run the review loop
dev https://github.com/keycloak/keycloak/pull/50801 --loop=best   # opus, gemini pro, fable

# Inside the container:
claude                     # start Claude Code (permissions bypassed via env var)
opus                       # Claude Code with the latest Opus  (= claude --model opus)
fable                      # Claude Code with the latest Fable (= claude --model fable)
claude-resume              # resume the Claude session of the last `dev review` (or the newest session)
claude-model fable         # make fable the default for `claude` and `dev review` (reset: claude-model reset)
bob                        # start Bob Shell (API key injected securely)
agy                        # start Antigravity CLI (Google Gemini models)
```

The current container is remembered per terminal: whatever a `dev` command worked with — created by `dev new`/`dev .`/`dev <url>`, named explicitly, or resolved from the cwd — becomes the target of the following `dev enter`, `dev see`, `dev cp`, `dev review`, ... in that terminal. A failed command never clears it, and flags (`dev delete --dont-sync`) are never mistaken for names.
Use `dev use <name>` to set the current container from a different terminal.
When nothing is remembered and multiple containers exist, commands resolve by cwd: `cd ~/sources/quarkus && dev see` picks the quarkus container if exactly one matches.

## Development flow

The flow is always the same four commands; nothing rebases, nothing merges upstream, nothing pushes to GitHub on your behalf:

```
dev see      container → host     fetch the agent's workspace, check out dev-auto/<container>/main
dev show     host → container     push the host branch you are on into the container
dev merge    dev see → in-review  one new commit by you on in-review/<feature> (you type the message)
dev squash   dev see → in-review  fold the changes into the HEAD commit of in-review/<feature>
```

```bash
# 1. Work on an issue (or `dev new`, or `dev .` from a branch)
dev https://github.com/keycloak/keycloak/issues/53157     # container keycloak-53157

# 2. Agent works; review on the host
dev see                    # host is now on dev-auto/keycloak-53157/main — review in the IDE
dev show                   # edited something? push it back and let the agent continue
dev see                    # ...

# 3. Looks good: make it your commit and open the PR
dev merge                  # editor opens for the message; creates in-review/53157, checks it out
git push -u michalvavrik in-review/53157      # (the exact command is printed)
# open the PR from in-review/53157

# 4. Review comments: the agent works on top of the PR branch
git checkout in-review/53157 && dev show     # PR branch → container (commit messages are copied without issue links, see below)
# tell the agent what to change ...
dev see                    # review the result
dev squash                 # reviewers are fine with amending: fold into the PR commit
dev merge                  # reviewers want separate commits: new commit on top (asks for the message)
git push --force-with-lease michalvavrik in-review/53157     # (printed by dev squash / dev merge)
```

### `dev see`

Commits whatever the container's workspace has (as the sandbox identity), pushes it to `dev-auto/<container>/main` on the automation fork, fetches it and checks it out in the project's source directory. Commits are kept as they are; the previous host state of that branch is backed up to `dev-auto/<container>/backup/see/<timestamp>` on the automation fork first.

### `dev show`

Pushes the host's current branch into the container, from any branch that belongs to the container: `dev-auto/<container>/main`, `in-review/<feature>`, `wip/<feature>` or the branch the container was created from. Uncommitted changes are committed first (`sync from host`). The container's previous state is backed up to `dev-auto/<container>/backup/show/<timestamp>`. See [Commit messages and issue links](#commit-messages-and-issue-links) for what exactly is pushed.

### `dev merge` and `dev squash`

Both take **what the last `dev see` fetched** (the host branch `dev-auto/<container>/main` — not the container, so you only ever merge what you reviewed) and record the agent's changes on `in-review/<feature>` as a commit of your host git identity (`user.name`/`user.email` of the source repo; `-S` when `commit.gpgsign` is set). Nothing is pushed; `in-review/<feature>` is checked out when done and the push command is printed.

- `dev merge [-m <message>]` — one new commit. Without `-m` your git editor opens (like `git commit`, with the diff stat as comments; an empty message aborts). `Signed-off-by` is added. If `in-review/<feature>` does not exist yet it is created; its first commit starts where the container's work started (the newest commit on the agent branch that was not made by the sandbox), or at the branch the container was created from with `dev .`.
- `dev squash` — the changes are folded into the current HEAD commit of `in-review/<feature>` (message and author date kept, like `git commit --amend`). The branch must exist.

The target branch is the branch the container was created from with `dev .` (`main` → `main`, `feature-x` → `feature-x`; `wip/x` graduates to `in-review/x`). Containers created from an issue, a PR or by `dev new` target `in-review/<feature>` (`keycloak-53157` → `in-review/53157`, `keycloak-pr-51877` → `in-review/pr-51877`); a `dev <pr-url>` container of your own PR has the PR's `in-review/*` head branch as its label and targets that. The target is printed before anything happens.

The target branch is the base the container's commits are added to, and it is expected not to change behind the container's back: the container works on top of exactly what is on it (that is what `dev show` pushed), so the result is simply the container's tree. If the base did change on the host since (no commit in the container has its current content), both commands abort without touching anything and print how to continue by hand — `dev show` the current branch into the container and let the agent redo its changes, or cherry-pick the container's commits yourself. If the container has changes that `dev see` did not fetch yet, a warning is printed.

### Commit messages and issue links

GitHub links every pushed commit whose message mentions an issue or PR (`closes: https://github.com/org/repo/issues/123`, `#123`, `org/repo#123`, `GH-123`) to that issue — so your PR commit, pushed to the automation fork by `dev show`, used to show up in the issue's timeline under the automation account. Therefore no `dev` command pushes such a commit to the automation fork, and no container ever has one:

- `dev show` and `dev .` copy the branch's own commits (those not on origin) through `scripts/dev-git-sanitize.sh` before pushing: same trees, authors and dates, but `https://github.com/…` becomes `github.com/…`, `#123` becomes `issue 123`, `org/repo#123` becomes `org/repo issue 123`, `GH-123` becomes `GH 123`. Your host branch is not changed. Commits without references keep their ids, so `dev show` from a clean `dev-auto` branch pushes exactly what it fetched.
- `dev <pr-url>` and `dev <tree-url>` (container creation and refresh) rewrite the commits fetched from GitHub the same way right after the checkout, using GitHub's own list of the PR's / branch's commits.
- Agents are told never to reference issues or PRs in commit messages.

Because the sanitized copy has the same tree, `dev merge` and `dev squash` work as if the container had the real commit. Upstream commits (anything on origin's branches or tags) are never rewritten — `dev show` fetches origin first to be sure of that, and refuses to continue if the fetch fails or if more than 100 commits would be rewritten.

## Branch lifecycle

| Branch | Created by | Pruned by `dev sync` when |
|--------|-----------|-------------|
| `in-review/<feature>` (host, your fork) | `dev merge` | no open PR has this head |
| `wip/<feature>` (host) | you, optionally (`git checkout -b wip/x && dev .`) | `in-review/<feature>` exists, or no commit for 20 days |
| `dev-auto/<container>/main` (host, automation fork) | `dev see`, `dev show`, `dev .`, `dev delete` | the container does not exist |
| `dev-auto/<container>/backup/{see,show}/<ts>` (automation fork) | `dev see`, `dev show` | the container does not exist, or older than 20 days |
| `dev-auto/<container>/backup` (automation fork) | the container's auto-backup (every 30 s) | the container does not exist |
| `backup/<feature>/<type>/<timestamp>` (your fork) | before any host branch is deleted | older than 20 days |

### How branches map to container names

The `<feature>` in `wip/<feature>` and `in-review/<feature>` is the branch suffix. When creating containers, the feature is sanitized and prefixed with the repo name if needed:

- `wip/fix-auth` in keycloak repo → container `keycloak-fix-auth` → `dev-auto/keycloak-fix-auth/main`
- `in-review/fix-auth` in keycloak repo → same container `keycloak-fix-auth`
- `fix-auth` (no prefix) → same container `keycloak-fix-auth`

All three branch forms map to the same container and the same `dev-auto` working branch. The `dev-original-branch` label records the host branch a container was created from (`dev .`), the PR's head branch (`dev <pr-url>`), or `in-review/<feature>` for containers created from an issue or by `dev new`; `dev merge` / `dev squash` derive their target from it (see above).

### `dev sync`

Superset of `dev pull`. Pulls images and sources, then prunes dead branches across all template projects:

1. **`dev-auto/<x>/*`** on the host — deleted when no container `<x>` exists
2. **`wip/<x>`** — deleted when `in-review/<x>` exists or the branch had no commit for 20 days
3. **`in-review/<x>`** — deleted when no open PR is associated (checked via `gh pr list`)
4. **`backup/*/<timestamp>`** on your fork — deleted when timestamp is older than 20 days
5. **`dev-auto/<x>/*`** on the automation fork — deleted when no container `<x>` exists; `dev-auto/<x>/backup/{see,show}/<timestamp>` of existing containers deleted after 20 days

Before any host branch deletion, the branch is backed up to `backup/<feature>/<type>/<timestamp>` on the `DEV_GHCR_USER` remote (your GitHub fork).

Runs automatically on login via a systemd user service. Run manually with `dev sync` — safe at any time: while a container is being created or recreated (`dev .`, `dev <url>`, `dev new`, `dev recreate`), its branch exists before the container does, so branch cleanup is skipped for that run (a lock in `/run/user/<uid>/dev-containers.lock`), and a container creation that starts during cleanup waits for it.

### `dev delete` behavior

`dev delete` first saves the container's workspace to the host branch `dev-auto/<container>/main` (same as `dev see`, without checking it out), then removes the container, its disks, its branches on the automation fork and its local `dev-auto/<container>/*` branches — each local branch is backed up to your fork as `backup/<feature>/dev-auto/<timestamp>` first, so the container's last state stays recoverable for 20 days. `wip/<feature>` is backed up and deleted only when `in-review/<feature>` exists; `in-review/*` branches are never touched. `--dont-sync` skips saving the workspace.

```bash
dev delete fix-auth              # save workspace, then delete
dev delete --dont-sync fix-auth  # delete without saving the workspace
```

During `dev recreate`, both the workspace save and the lifecycle branch cleanup are skipped (workspace is preserved across the recreate cycle).

### Backup safety

Nothing is ever deleted without a backup. Before any host branch deletion:
1. The branch is pushed to `backup/<feature>/<type>/<timestamp>` on your remote (`DEV_GHCR_USER`)
2. Only then is the local branch deleted

Backups are pruned after 20 days by `dev sync`.

## Antigravity CLI (Google Gemini models)

On first run inside a container, `agy` detects the SSH environment and prints an auth URL — open it in your host browser, sign in with your Google account, and paste the code back. Subsequent runs use cached tokens.

Google OAuth tokens live in plaintext inside the container — the agent can read them. `dev delete` revokes the token; always verify revocation or check `myaccount.google.com/permissions`.

## Local project workflow

```bash
# 1. Start — push your branch to an agent container
cd ~/sources/keycloak && git checkout -b wip/my-feature
dev .
# → creates container keycloak-my-feature, you're inside it
# → uncommitted changes included (temporary WIP commit, reset after push)

# 2. Work with the agent
claude

# 3. Review — pull agent's changes to host
dev see                    # checks out dev-auto/keycloak-my-feature/main

# 4. Edit locally, then push back to the container
dev show                   # pushes host edits into the container (works from wip/*, in-review/*, dev-auto/*)
dev .                      # alternative: re-syncs and re-enters

# Repeat steps 2–4 as needed

# If upstream main has advanced:
dev rebase                 # fetch upstream main and rebase workspace on top of it

# 5. Finish — your commit on in-review/my-feature (starts at wip/my-feature), then push it yourself
dev merge                  # asks for the message; checks out in-review/my-feature
git push -u michalvavrik in-review/my-feature
```

`dev merge` / `dev squash` work from any directory — they resolve the source directory from container metadata, like `dev show`. `dev-auto/` branches from `dev see` reuse the original container name when passed to `dev .`. Before `dev see` or `dev show` replaces a branch, its state is backed up to a timestamped branch. All agent branches are cleaned up by `dev delete`.

Works with PRs — a `dev <pr-url>` container of your own PR targets the PR's `in-review/*` branch (fetched to the host if missing):

```bash
dev https://github.com/keycloak/keycloak/pull/53587       # your PR, head in-review/53157
# ... agent work, dev see/show cycle ...
dev squash                 # or dev merge — amends / extends in-review/53157
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

# Use a different agent or model (default agent: claude with the container's default model)
dev review --agent=bob https://github.com/keycloak/keycloak/pull/50801
dev review --model=fable keycloak-pr-50801          # claude, latest Fable
dev review --model=pro keycloak-pr-50801            # agy (implied by flash/pro), latest Gemini Pro, highest effort
dev review --agent=agy --model=flash keycloak-pr-50801

# Custom prompt (replaces agent-specific template, base kept)
dev review --prompt "focus only on security issues"

# Append to the default prompt
dev review --append-to-prompt "also check for Java 21 API usage"
```

Model shortcuts always mean the newest model available, so they never need updating: `opus` / `fable` are Claude Code aliases for the latest model of each family (on Vertex they are pinned by `DEV_VERTEX_OPUS_MODEL` / `DEV_VERTEX_FABLE_MODEL`), and `flash` / `pro` pick the newest `gemini-*-flash-high` / `gemini-*-pro-high` from `agy models` (pin with `DEV_AGY_FLASH_MODEL` / `DEV_AGY_PRO_MODEL`).

Review prompts use a two-layer system in `configs/review-prompts/`:
- `base.txt` — shared context instructions (always included)
- `claude.txt`, `bob.txt`, `agy.txt` — agent-specific personality/style
- `loop.txt` — extra instructions for review loops (see below)

Edit these files to improve prompts over time. `--prompt` replaces only the agent-specific part; `--append-to-prompt` appends to the combined prompt.

For interactive follow-up (when headless isn't enough): `dev enter` then `claude-resume` — it resumes the Claude session of the last `dev review` in that container (recorded by the review; falls back to the most recent Claude session in `/workspace`). Extra arguments are passed to `claude`, e.g. `claude-resume --model fable`. The session ID is also printed at the end of each review for `claude -r <session-id>`.

Agents are instructed (in the generated `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` and in the review prompt) to always give the direct URL of any GitHub comment, review, issue, PR, commit or CI run they mention, never just a comment number or a paraphrase. Reviews must not change files or run formatters, and must not report housekeeping (the keycloak `spotless:apply` rule applies only to changes the agent made).

### Review loop (`--loop`)

`--loop` runs several reviewers one after another in the same container. Every reviewer first does its own independent review, then fact-checks each earlier review of the loop (CONFIRMED / REJECTED / UNVERIFIED per finding, with evidence) and writes both into `/workspace/.reviews/<agent>/<timestamp>-<model>.md`. The last reviewer therefore verifies everything before it.

```bash
dev https://github.com/keycloak/keycloak/pull/50801 --loop      # set up container + normal loop
dev review --loop                                               # normal loop in the current container
dev review --loop=best keycloak-pr-50801
dev review --loop=bob,pro,fable                                 # any list, in this order
dev review --loop=normal,fable                                  # profiles can be mixed into a list
dev review --loop --append-to-prompt "focus on the token store"
```

| Profile  | Reviewers, in order                                    |
|----------|--------------------------------------------------------|
| `normal` | `bob`, `flash` (Gemini Flash, highest effort), `opus`  |
| `best`   | `opus`, `pro` (Gemini Pro, highest effort), `fable`    |
| `all`    | `bob`, `pro`, `opus`, `flash`, `fable`                 |

List entries: `bob`, `flash`, `pro`, `opus`, `fable`; `gemini` means `flash`, `claude` means `opus`, and `agent:model` (e.g. `agy:pro`, `claude:fable`) also works. Ran out of Bob credits? Leave `bob` out: `--loop=flash,opus`. Profiles can be redefined with `DEV_LOOP_NORMAL`, `DEV_LOOP_BEST`, `DEV_LOOP_ALL` in `config.local`.

When a Gemini reviewer is in the loop and Antigravity is not signed in yet in the container, the sign-in (Google URL + code) is triggered before the loop starts, so you don't have to wait for Bob to finish and then paste a code; later runs reuse the token. A failing reviewer (e.g. no Bob credits) is reported and the loop continues with the next one; the summary at the end lists every review file. In `vertex` containers, `fable` is skipped unless `DEV_VERTEX_FABLE_MODEL` is set.

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
| `kind`  | Auto-creates a **rootful** Kind cluster + local registry (`localhost:5001`) on first start; 20 GiB podman storage. **Control-plane / manifest work only — in-cluster Service networking does not work (kernel limits), and it weakens in-VM isolation; see [the `kind` profile note](#the-kind-profile-weakens-in-vm-isolation).** |

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

### Claude auth and models

Claude Code authenticates through the host proxy either with a Claude Pro/Max subscription token (`api-key`, the default) or with Google Vertex AI (`vertex`). Pass `--auth-method=vertex|api-key` when a container is created (`dev new`, `dev .`, `dev <url>`, `dev review <url>`, `dev recreate`), or set `DEV_AUTH_METHOD` in `config.local` to change the default. Bob Shell and Antigravity CLI ignore it.

```
dev new fix-auth --auth-method=vertex
dev review --agent=claude --auth-method=vertex https://github.com/keycloak/keycloak/pull/50801
dev recreate --auth-method=api-key fix-auth   # switch an existing container
```

On first `api-key` use, `dev` asks for a token from `env -u CLAUDE_CODE_USE_VERTEX claude setup-token` (one browser login on the host) and saves it to `keys/claude-oauth-token` (mode 600). The method is fixed at creation (label `dev-auth-method`); `dev recreate` keeps it unless `--auth-method` is given.

**Models.** Claude Code picks the model in this order: `--model` > `ANTHROPIC_MODEL` > `model` in `~/.claude/settings.json`. The aliases `opus` and `fable` always mean the latest model of that family, so they never need updating.

**What "latest" means.** An alias resolves to the newest model of that family *known to the installed Claude Code*, and the API refuses newer models from older clients (Opus 5.5 needs 2.1.280+; a 2.1.267 client gets `400 ... version 2.1.280 or newer is required` even with the full model ID). So the Claude Code version in the image decides how new `opus`/`fable` can be. The image installs Claude Code from the `latest` RPM channel (`stable` trails new-model releases by weeks) and is rebuilt every 3 days; `dev pull` / `dev sync` print a note when the image's Claude Code is older than the newest release. To update a single running container without waiting for a new image, run `claude install latest` inside it (installs into `~/.local/bin`, which precedes `/usr/bin` in PATH).

- Subscription containers set `ANTHROPIC_MODEL=opus` (change with `DEV_SUBSCRIPTION_MODEL` in `config.local`).
- Vertex containers use the `model` from `configs/claude-settings.json` and pin the aliases with `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_FABLE_MODEL` (from `DEV_VERTEX_OPUS_MODEL` / `DEV_VERTEX_FABLE_MODEL`), because the newest model of a family may not be enabled for the Vertex project.
- Inside a container, `opus` and `fable` start Claude Code with that model (`opus -r <session>` etc. pass arguments through), and `claude-model opus|fable|<model>` changes the default for plain `claude` and for `dev review` in that container (persisted; `claude-model reset` restores the container default, `claude-model` shows it). `/model` inside a session still overrides everything for that session.

The token works like the Vertex credentials: it **never enters the VM**. The container gets `ANTHROPIC_BASE_URL=http://host.internal:<port>/anthropic` and a placeholder `ANTHROPIC_AUTH_TOKEN`; `dev-proxy.py` replaces the auth with the real token and forwards to `api.anthropic.com`. Per-port rules: a container's port serves either Vertex or the subscription (never both), and only `/v1/messages`, `/v1/messages/count_tokens` and `/v1/models` are forwarded. The proxy reads the token file on every request, so rotation is just replacing the file.

Caveats: a compromised agent can still spend subscription usage through the proxy while its container exists (same as Vertex), but cannot take the token with it. This relies on the API accepting subscription tokens with the `oauth-2025-04-20` beta header — not an officially documented setup, so it may break. Claude Code sees itself as API-key authenticated, so `/status` does not show plan usage; check it on claude.ai.

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
        (6 GiB default, 20 GiB kind)      (Testcontainers / rootful Kind nodes)
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

Every 30 seconds, a background process (`scripts/dev-auto-backup.sh`, launched by the entrypoint) snapshots the workspace — including uncommitted and untracked files — and force-pushes it to `dev-auto/<name>/backup` on the automation fork, without touching the workspace. A push failure (e.g. the proxy is down) is logged but the local snapshot commit is kept, so the work is still recoverable with `dev see` or directly from the disk image.

It records progress to `/mnt/bounded/backup/{status,log}` on the bounded disk, which the host reads even when the container is stopped:

- `dev list` shows a `BACKUP` column — the age of the last loop run for running containers (`STALE`/`never` means the loop is not working).
- `dev see` / `dev show` warn if a container that has been up a while has an inactive auto-backup.

If the whole mechanism fails and the container won't even start, the workspace still lives in the disk image's fuse-overlay upperdir (`~/.local/share/dev-sandbox-disks/<name>.img`, dir `ws-upper`) and can be recovered read-only with `debugfs`.

## Known issues

- agy review doesn't print progress

