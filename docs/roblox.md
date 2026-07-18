# Roblox integration recipe

A worked example of layering a real toolchain on the generic harness. The rule:
the harness installs **ecosystem machinery** (Rokit); the repository declares and
materializes its own tools.

## Install

```bash
~/dev/vibe-devcontainer-submodule/install.sh --preset roblox ~/dev/my-roblox-game
```

The `roblox` preset uses the Python 3.14 base image (for build/pipeline scripting
with `uv`), sets `INSTALL_ROKIT=true`, and adds the Luau LSP and Rojo VS Code
extensions. `rokit` is added to `DEV_REQUIRED_COMMANDS`.

## Project bootstrap

Tool versions come from the repository, not the image. With `rokit.toml` and
`wally.toml` present, the generic bootstrap already runs `rokit install` and
`wally install`; anything extra goes in the project hook:

```bash
# .devcontainer/project/post-create.sh
uv sync --frozen           # if not lockfile-detected already
wally-package-types --sourcemap sourcemap.json Packages 2>/dev/null || true
```

## Services (Rojo)

The harness never starts services. Start Rojo from the project hook or a tmux pane:

```bash
# .devcontainer/project/post-start.sh (keep idempotent)
pgrep -f "rojo serve" >/dev/null || (rojo serve &>/tmp/rojo.log &)
```

To reach Rojo from Roblox Studio on the Windows host, pick by how you attach:

- **Terminal-first (`vibe agent` / `devcontainer exec` — no VS Code attached):
  publish the port to loopback with `appPort`.** `forwardPorts` is implemented
  by the attached client; the devcontainer CLI forwards nothing, so with
  `forwardPorts` alone Studio cannot reach Rojo and sync silently breaks.

  ```jsonc
  "appPort": ["127.0.0.1:34872:34872"]
  ```

  The loopback bind is the point: this is the sanctioned exception to the
  no-published-ports rule, because `127.0.0.1:` keeps the port off the
  network — only the local machine (and, via Docker Desktop's proxy, the
  Windows host) can reach it. Never publish bare (`"appPort": [34872]`
  binds `0.0.0.0`). `appPort` applies at container creation — rebuild after
  adding it.

- **VS Code-attached workflows** can use `forwardPorts` instead (active only
  while the client is connected):

  ```jsonc
  "forwardPorts": [34872],
  "portsAttributes": { "34872": { "label": "Rojo" } }
  ```

## Studio bridge / Blender / MCP

Application integrations stay in the project's own configuration:

- A host-side Studio bridge that needs to call **into** the container uses the
  forwarded port above; the container reaching **out** to a host service needs the
  `--add-host=host.docker.internal:host-gateway` runArg
  (see [local-models.md](local-models.md) for the same pattern).
- Blender (headless) is heavy: prefer a Dev Container Feature or a Compose sidecar
  in the project over adding it to the shared Dockerfile.
- MCP server registration is agent configuration — script it in
  `project/post-create.sh` so it lands in the persisted agent state.

## Reviewing generated images and renders

For pipelines that produce image batches (Blender renders, generated
textures/sprites, concept art), give each pipeline stage its own output
directory and review each gate with `vibe review <dir>` from any host
terminal — verdicts (approve/reject, plus an optional one-line reject note
the regenerating agent can steer by) append to `<dir>/vibe-decisions.jsonl`.
A staged asset flow maps one review per gate — e.g. concept art → angle
sheets → render batches, each a directory the generating agent writes into
and then polls the verdict file of. The stage state machine (what "reject"
triggers: regenerate vs refine) belongs to the project's agent skills, not
the harness. Alternatively set `VIBE_PREVIEW_DIR`/`VIBE_PREVIEW_DECISIONS`
in `config.env` to make the `prefix+i` window review a fixed directory —
see [usage.md](usage.md#reviewing-images).
