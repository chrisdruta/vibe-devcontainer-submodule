# Installation

## Prerequisites

- The target must be an **existing git repository**, and you must run the installer
  against its top level — the harness is added as a git submodule.
- Git and Docker on the host (Docker Desktop bundles the compose plugin the
  launcher uses). Nothing else — no Node, no devcontainer CLI.
- On Windows, keep the repository in the WSL filesystem (`~/dev/...`); `/mnt/c`
  paths suffer severe filesystem-performance and permission problems in containers.
- On macOS, Docker Desktop works out of the box on Apple Silicon and Intel
  (OrbStack is a faster drop-in alternative if bind-mount performance bites).
  All host-side scripts run on the stock macOS bash 3.2.

## Install (submodule-first — the default flow)

From the top level of the project repository:

```bash
git submodule add https://github.com/chrisdruta/vibe-tui-box.git .vibe/harness
.vibe/harness/install.sh
```

The submodule is the delivery mechanism — no separate clone, no `curl | sh`,
no npx; everything arrives over git and is pinnable/diffable like any other
dependency. Run on a terminal with no arguments, the installer is
**interactive**: pick the preset, optionally enable extras (`codex`, `grok`,
`node`, `playwright`), confirm. Any argument switches to plain flag mode
(`--preset python --extras codex`) for scripts and agents.

The installer:

1. seeds the project-owned files (`compose.yaml`, `config.env`, `vibe` wrapper,
   `AGENTS.md`, `project/` hooks, `yazi/` review preferences) rendered for the
   chosen preset — selected extras get their build args set to `"true"` in the seeded
   `compose.yaml` — plus `.claude/settings.json` (statusline, image-preview
   hooks, sudo/`.env`-read deny) unless the project already has one,
2. registers the submodule if needed (already done in the flow above; a plain
   `git clone` into `.vibe/harness` gets absorbed),
3. **bootstraps the host trust store** (`~/.vibe`): installs the `vibe` shim onto
   your PATH surface, records the canonical harness remote, materializes this
   pin into the store, and records this project's trust (see
   [security.md → Host root of trust](security.md)). Pass `--no-self` to skip
   this (e.g. CI that provisions the store separately),
4. stages everything — nothing is committed; review with `git status` and commit.

There is **no** root `./vibe` symlink: the host spelling is `vibe` on your PATH
(the shim), which runs only trusted, materialized code — never the workspace
copy. Add `~/.vibe/bin` to your PATH if the bootstrap says it isn't there. Inside
the container, a `vibe` on the container PATH is the in-container spelling.

The pin is whatever `git submodule add` cloned (branch tip); pin a tagged
release afterwards with `vibe update vX.Y.Z` — it stages the move for
review like everything else.

To have an agent make the judgment calls (build args, hooks, migrating an old
setup), see [onboarding.md](onboarding.md). A project still on the legacy
`.devcontainer/` layout migrates via
[updating.md → Migrating to the compose engine](updating.md) instead of
reinstalling.

## Install from a scaffold clone

Handy when setting up many projects, or when developing the harness itself:

```bash
git clone https://github.com/chrisdruta/vibe-tui-box.git \
  ~/dev/vibe-tui-box

~/dev/vibe-tui-box/install.sh --preset python ~/dev/my-project
```

Same result; the installer adds the submodule itself (from the clone's
`origin` URL) instead of finding one already in place.

## Options

| Flag             | Meaning                                                        |
| ---------------- | -------------------------------------------------------------- |
| `--preset NAME`  | `minimal` (default), `python`, `bun`, or `roblox`               |
| `--extras LIST`  | Comma-separated: `codex`, `grok`, `node`, `playwright` — enables the build args in the seeded `compose.yaml` (`playwright` implies `node`) |
| `--url URL`      | Submodule URL (default: the clone's `origin` remote)            |
| `--ref BRANCH`   | Submodule branch to track (default: `main`; scaffold mode only) |
| `--force`        | Back up an existing `.vibe` and replace it (scaffold mode only) |

With `--force`, the existing `.vibe` is moved to a timestamped
`.vibe.backup.*` directory and any previous harness submodule registration
is scrubbed before reinstalling.

If the scaffold clone has no `origin` remote (e.g. you are hacking on a local copy),
its local path is used as the submodule URL; switch later with:

```bash
git submodule set-url .vibe/harness https://github.com/chrisdruta/vibe-tui-box.git
```

## First start

```bash
cd ~/dev/my-project
vibe up        # builds the image, starts the container, bootstraps
vibe agent     # launches the default agent (Claude Code)
```

`vibe` here is the shim on your PATH. On first run in a project it shows the
harness pin and asks you to trust it once (host root of trust); after that it
runs the trusted, materialized version directly.

On first `vibe agent`, Claude Code walks through its login. Logins persist in a
named volume per project — see [agent-state.md](agent-state.md).

For `git push` / `gh` from inside the container, mint a per-project
fine-grained PAT and `gh auth login` once — the installer prints the
permission set in its next-steps output, and
[configuration.md → GitHub access](configuration.md) has the full reference.

## Cloning a project that already uses the harness

```bash
git clone --recurse-submodules <project-url>
# or, after a plain clone / in a new git worktree:
git submodule update --init

# Bootstrap the host trust store from the checkout you just reviewed:
.vibe/harness/install.sh --self
```

The `--self` step establishes `~/.vibe` on this machine (shim on PATH, canonical
remote, materialize this pin, record this project's trust) — the one bootstrap
ceremony that runs workspace code, from a checkout you deliberately invoked.
Afterwards `vibe` on your PATH is the only host entry point.

## Uninstall from a project

```bash
git submodule deinit -f .vibe/harness
git rm -f .vibe/harness
rm -rf "$(git rev-parse --git-common-dir)/modules/.vibe/harness"
git rm -r .vibe          # also remove the project-owned files, if desired
docker volume rm agent-state-<folder-name>   # discard persisted agent logins
```

Then drop the project's trust record and cached versions from the store if you
like: `rm ~/.vibe/state/projects/*` (per project) or remove `~/.vibe` entirely.
The container and image can be removed with `vibe down` (before removing
`.vibe`) and `docker rmi` (`docker images | grep vibe-`).
