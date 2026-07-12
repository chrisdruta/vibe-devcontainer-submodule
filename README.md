# Generic Agent Dev Container

A small, reusable Dev Container harness for agentic coding on Windows + WSL2 + Docker.

Projects consume this repository as a **git submodule** at `.devcontainer/harness/`.
The shared, unchanging pieces (Dockerfile, lifecycle scripts, launcher) live in the
submodule; each project owns only a thin `devcontainer.json`, a `config.env`, and its
own hooks.

```text
my-project/.devcontainer/
├── devcontainer.json    project-owned (references harness/ paths)
├── config.env           project-owned behavior toggles
├── dev                  thin wrapper → harness/dev
├── project/             project-owned post-create / post-start hooks
└── harness/             ← this repository, as a submodule
```

## Design goals

- Keep repositories in the WSL filesystem, such as `~/dev/my-project`.
- Run the coding agent as a non-root user.
- Do not mount the Docker socket, SSH keys, or the host home directory.
- Keep agent state in a named Docker volume (per project, survives rebuilds).
- Keep project dependencies declared by the project itself.
- Make lifecycle hooks small, visible, and safe to rerun.
- Update every consuming repository with one `git submodule update --remote`.

## Install into an existing repository

The target must be a git repository (the harness is added as a submodule):

```bash
~/dev/generic-agent-devcontainer/install.sh --preset minimal ~/dev/my-project
```

| Preset    | Base image                  | Extras                          |
| --------- | --------------------------- | ------------------------------- |
| `minimal` | `devcontainers/base:debian` | shell tools, Claude Code, `uv`  |
| `python`  | `devcontainers/python:3.14` | Python + Ruff extensions        |
| `bun`     | `devcontainers/base:debian` | Bun, Biome extension            |
| `roblox`  | `devcontainers/python:3.14` | Rokit, Luau/Rojo extensions     |

The installer seeds the project-owned files, adds the submodule, and stages
everything for review. Commit when satisfied.

The submodule URL defaults to this scaffold's `origin` remote; before publishing to
GitHub it falls back to the scaffold's local path (switch later with
`git submodule set-url .devcontainer/harness <GITHUB_URL>`). Pass `--url`/`--ref`
to override.

## Start it

From the target repository in WSL:

```bash
./.devcontainer/dev up
./.devcontainer/dev agent
```

Other commands:

```bash
./.devcontainer/dev shell
./.devcontainer/dev doctor
./.devcontainer/dev bootstrap
./.devcontainer/dev rebuild      # after editing devcontainer.json or the Dockerfile
./.devcontainer/dev run codex    # any command with explicit .env loading
./.devcontainer/dev exec uv run pytest
```

The launcher uses a locally installed `devcontainer` CLI, falling back to
`npx -y @devcontainers/cli`. You can also open the repository in VS Code and choose
**Reopen in Container**. The launcher itself is repo-agnostic; a host-wide symlink
(`ln -s ~/dev/my-project/.devcontainer/harness/dev ~/.local/bin/dev`) also works if
you prefer running plain `dev up` — it resolves the project from its own location.

## Updating projects

```bash
git submodule update --remote --merge .devcontainer/harness
git add .devcontainer/harness && git commit -m "Update agent harness"
```

Caveats that come with submodules:

- Fresh clones need `git clone --recurse-submodules`, or `git submodule update --init`
  after the fact.
- New git worktrees need `git submodule update --init` inside the worktree.
- The seeded `.devcontainer/dev` wrapper prints exactly that hint when the submodule
  is missing.

## Customize a project

### Image-level tooling

Edit the build args in your project's `.devcontainer/devcontainer.json`:

```jsonc
"args": {
  "BASE_IMAGE": "mcr.microsoft.com/devcontainers/base:debian",
  "INSTALL_CLAUDE_CODE": "true",
  "INSTALL_CODEX": "false",   // OpenAI Codex CLI (pulls in Node)
  "INSTALL_GROK": "false",    // xAI Grok Build
  "INSTALL_NODE": "false",
  "INSTALL_BUN": "false",
  "INSTALL_ROKIT": "false"
}
```

Tool versions are pinned in the harness Dockerfile (`UV_VERSION`, `BUN_VERSION`,
`ROKIT_VERSION`, `CODEX_VERSION`); override them via build args without touching the
submodule. `CLAUDE_CODE_VERSION` defaults to `stable` and `GROK_VERSION` to the
installer's latest stable — the consciously mutable components; set concrete versions
to freeze them.

For larger tools such as Blender, databases, or browsers, prefer a Dev Container
Feature or a Compose sidecar in the project — not the shared harness.

### Lifecycle behavior

Edit `.devcontainer/config.env`:

```bash
DEV_AGENT_CMD=claude
DEV_BOOTSTRAP_STRICT=1
DEV_ENV_FILE=.env
DEV_REQUIRED_COMMANDS="git gh jq rg uv claude"
```

The generic bootstrap detects common lockfiles and manifests:

- `uv.lock` + `pyproject.toml` → `uv sync --frozen`
- `bun.lock` / `bun.lockb` → `bun install --frozen-lockfile`
- `pnpm-lock.yaml` → `pnpm install --frozen-lockfile`
- `package-lock.json` → `npm ci`
- `yarn.lock` → `yarn install --immutable`
- `rokit.toml` → `rokit install`
- `wally.toml` → `wally install`
- `.githooks/` → repository-local `core.hooksPath`
- LFS attributes → repository-local Git LFS initialization

A manifest whose required executable is missing is an error when
`DEV_BOOTSTRAP_STRICT=1`.

> **Warning — auto git hooks leak to the host.** `DEV_AUTO_GIT_HOOKS=1` wires a
> repo-supplied `.githooks/` directory into `.git/config`, and `.git` lives in the
> shared workspace mount: hooks configured in-container also run when you use git
> **on the WSL host**, outside every container guardrail. Fine for repos whose hooks
> you wrote; set `DEV_AUTO_GIT_HOOKS=0` in `config.env` before pointing the harness
> at cloned third-party code.

## Multiple agents in one container

Claude Code is installed by default. Codex (OpenAI) and Grok Build (xAI) are opt-in
build args; all agents share one state volume (`agent-state-<folder-name>`) mounted
at `~/.agents`, with one subdirectory per CLI — log in to each once per project,
and logins survive rebuilds:

| Agent       | Command  | State                       | Auth                        |
| ----------- | -------- | --------------------------- | --------------------------- |
| Claude Code | `claude` | `~/.agents/claude`          | OAuth or `ANTHROPIC_API_KEY`|
| Codex CLI   | `codex`  | `~/.agents/codex`           | OAuth or `OPENAI_API_KEY`   |
| Grok Build  | `grok`   | `~/.agents/grok` (`~/.grok` symlink) | OAuth or `XAI_API_KEY` |

API keys belong in the project `.env` (loaded explicitly by `dev agent` / `dev run`,
never auto-sourced). `DEV_AGENT_CMD` in `config.env` picks the default for
`dev agent`; run the others with `dev run codex`, `dev run grok`, or side by side in
tmux panes via `dev shell`. Agents can also invoke each other as subprocesses
(e.g. Claude calling `codex` or `grok` to cross-check work) — they share the
workspace and the `.env`-loaded credentials of the process that spawned them.

### Repository-specific setup

Put project-only operations in:

```text
.devcontainer/project/post-create.sh
.devcontainer/project/post-start.sh
```

Examples: database migrations, code generation, MCP setup. The harness itself does
not assume a process manager or start services.

### Secrets

The harness does not mutate `.bashrc` or automatically source `.env` in every shell.
Load them explicitly:

```bash
./.devcontainer/harness/scripts/env-run.sh your-command --arguments
```

`./.devcontainer/dev agent` does this automatically. `GH_TOKEN` is forwarded via
`remoteEnv`; it is not baked into the image. For autonomous runs, use a token with
minimum permissions, or omit it.

## Security boundary

The default container:

- runs as `vscode`, not root
- removes passwordless `sudo`
- drops all Linux capabilities and enables `no-new-privileges`
- does not mount `/var/run/docker.sock`, `~/.ssh`, or the WSL home directory
- publishes no ports
- only mounts the workspace and a persistent agent-state volume
  (`agent-state-<folder-name>`, one login per agent per project, survives rebuilds)

This reduces accidental host damage; it does not make untrusted code harmless. The
agent can modify the mounted repository and read any credentials deliberately passed
to it. A dedicated autonomous trust profile (disposable worktree, no push-capable
token) is planned but **not implemented yet** — for unattended work, use a disposable
clone and reduced credentials manually.

## Local LLMs (Ollama on the Windows host)

Don't mount the GPU into containers — on AMD + WSL2 + Docker Desktop that path is
unsupported (Docker's `--gpus` is NVIDIA-only, ROCm-on-WSL excludes containers).
Instead run the inference server natively on Windows, where the Radeon drivers work,
and let containers reach it over the host gateway:

1. Start Ollama from WSL with the tuned settings (stops the tray app first, forwards
   the `OLLAMA_*` variables to the Windows process via `WSLENV`, foreground serve):

   ```bash
   ./.devcontainer/harness/scripts/host/start-ollama.sh --parallel 24
   ```

2. Give the project's container a route to the host — add to its `runArgs`:

   ```jsonc
   "--add-host=host.docker.internal:host-gateway"
   ```

3. Point tooling at it, e.g. in the project `.env`:

   ```bash
   OPENAI_BASE_URL=http://host.docker.internal:11434/v1
   ```

Model weights live once on the host, every devcontainer shares the same server, and
containers stay slim. After the first batch, check `ollama.exe ps` shows 100% GPU;
if not, lower `--parallel`.

## Roblox migration

Use the `roblox` preset, then keep project-level operations in the repository:

```bash
# .devcontainer/project/post-create.sh
rokit install
wally install
uv sync --frozen
```

Keep Blender/MCP, Rojo service startup, ports, and Studio host bridging in the Roblox
project's own configuration. If the Studio bridge needs to reach the host, add
`--add-host=host.docker.internal:host-gateway` to that project's `runArgs` — it is
deliberately not part of the generic harness.

## Developing the harness itself

```bash
./verify.sh
```

Runs shell syntax checks, ShellCheck, and installs every preset into scratch git
repositories (committed HEAD only — commit before verifying).
