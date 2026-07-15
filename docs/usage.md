# Daily usage

All commands run from the project root via the seeded wrapper:

```bash
./.devcontainer/dev COMMAND [ARGS...]
```

| Command     | Does                                                                  |
| ----------- | --------------------------------------------------------------------- |
| `up`        | Build (if needed) and start the Dev Container                          |
| `rebuild`   | Recreate the container — required after editing `devcontainer.json` or the Dockerfile |
| `build`     | Build the image only                                                   |
| `shell`     | Open a Bash shell in the container                                     |
| `agent [--cold] [-a CMD]` | Run the configured default agent (`DEV_AGENT_CMD`) with explicit `.env` loading; with `DEV_AGENT_TMUX=1`, inside a persistent tmux session. `--cold`: fresh-perspective session without repo instruction files. `-a`/`--agent`: run `CMD` instead of `DEV_AGENT_CMD` for this invocation |
| `run CMD`   | Run any command with explicit `.env` loading (e.g. `dev run codex`)    |
| `exec CMD`  | Run any command **without** `.env` loading                             |
| `doctor`    | Check the environment; prints OK/MISS per requirement                  |
| `bootstrap` | Rerun create-time dependency setup (idempotent)                        |
| `clip [DIR]` | Save the host clipboard image into container `/tmp`, or `DIR` in the workspace (image-paste workaround) |

The launcher uses a locally installed `devcontainer` CLI, falling back to
`npx -y @devcontainers/cli`. It is repo-agnostic — a host-wide symlink also works
(`ln -s ~/dev/my-project/.devcontainer/harness/dev ~/.local/bin/dev`), resolving
the project from its own location.

## Typical day

```bash
./.devcontainer/dev up          # morning: container resumes, doctor runs
./.devcontainer/dev agent       # interactive Claude session
./.devcontainer/dev exec uv run pytest
```

## tmux

With `DEV_AGENT_TMUX=1` in `config.env` (the seeded default for new installs),
`dev agent` runs inside a tmux session named `agent` (`DEV_AGENT_TMUX_SESSION`):

- **Detach** with `Ctrl-b d` — the agent keeps running; closing the terminal or
  losing the connection also leaves it running.
- **Reattach** by rerunning `./.devcontainer/dev agent` (arguments are ignored
  when an existing session is attached; the session ends when the agent exits).
- **One-off plain run**: `dev run claude`, or set `DEV_AGENT_TMUX=0`.

Run several agents side by side in tmux (installed in the image):

```bash
./.devcontainer/dev shell
tmux
# pane 1: claude    pane 2: codex    pane 3: grok
```

## Cold sessions (fresh perspective)

`dev agent --cold` starts the agent without the repo's instruction files, for an
unbiased second opinion — reviewing a design without the repo's conventions
arguing back, or checking whether docs stand on their own:

- **Claude Code** runs with `--safe-mode`: no CLAUDE.md/AGENTS.md memory, and all
  `.claude/` customizations (skills, plugins, hooks, MCP servers, statusline) are
  off for the session. Auth, model, built-in tools, and permissions are normal.
- **Codex** (`DEV_AGENT_CMD=codex`) runs with `-c project_doc_max_bytes=0`, which
  drops all AGENTS.md loading.
- Agents with no known instruction-skip mechanism (e.g. Grok) refuse with an
  error instead of silently running warm.

Remaining arguments pass through (`dev agent --cold --continue`), and it
composes with the per-invocation agent selector:

```bash
./.devcontainer/dev agent -a codex          # Codex session (DEV_AGENT_CMD untouched)
./.devcontainer/dev agent --cold -a codex   # Codex without AGENTS.md
./.devcontainer/dev agent -a "codex --model gpt-5"   # override may carry arguments
```

With `DEV_AGENT_TMUX=1` each variant uses its own tmux session — `agent`,
`agent-cold`, `agent-codex`, `agent-codex-cold` — so runs never reattach to the
wrong session and can happily run side by side.

## Pasting images to an agent

Ctrl-V image paste cannot work inside the container: the agent reads the OS
clipboard from its own process, and the container has no WSL interop or display
server to reach it (the terminal only ever sends text down the pty). Instead,
with an image on the host clipboard, run on the host:

```bash
./.devcontainer/dev clip
# In the container: /tmp/clip-20260715-093042.png
# (path copied to clipboard)
```

The image lands in the container's `/tmp` (nothing is written to the repo), and
the printed path replaces the image on the host clipboard — paste it straight
into the agent prompt. Works on WSL (PowerShell) and macOS (AppleScript); the
container must be running. Files vanish on rebuild, as `/tmp` is
container-local.

To keep captures instead, pass a workspace-relative directory — the image is
written straight through the bind mount (no running container required):

```bash
./.devcontainer/dev clip .captures
# Saved: .captures/clip-20260715-093042.png
```

Gitignore the directory if you use this mode routinely.

## Troubleshooting

- **Start with `dev doctor`.** It verifies non-root execution, workspace
  writability, required commands (`DEV_REQUIRED_COMMANDS`), the agent command,
  and the absence of the Docker socket and passwordless sudo. Its output is also
  logged to `/tmp/dev-doctor.log` inside the container on every start.
- **Changed `devcontainer.json` or the Dockerfile and nothing happened?**
  `dev up` reuses an existing container; run `dev rebuild`.
- **`Harness submodule is missing`** — run `git submodule update --init`.
- **Bootstrap fails loudly** — that is `DEV_BOOTSTRAP_STRICT=1` doing its job:
  a detected manifest's tool is missing. Install the tool via build args or set
  `DEV_BOOTSTRAP_STRICT=0` to degrade to warnings
  (see [configuration.md](configuration.md)).
- **Agent asks to log in again after a rebuild** — the state volume persists
  across rebuilds but is per project folder name; see [agent-state.md](agent-state.md).
- **Slow file operations on macOS** — Docker Desktop bind mounts (virtiofs) are
  slower than WSL's native ext4; if a heavy directory (e.g. `node_modules`) hurts,
  move it to a named volume in the project's `devcontainer.json`.
- **Root shell for maintenance**: `docker exec -u root -it <container> bash`
  (deliberately outside the normal flow).
