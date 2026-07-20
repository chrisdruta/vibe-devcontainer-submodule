# Project services

Three patterns cover everything long-running a project needs. Pick by where
the process belongs, not by habit:

| Pattern | For | Lifecycle |
| ------- | --- | --------- |
| **Compose sidecar** | Independent daemons: databases, caches, message brokers — anything that doesn't need the workspace or its toolchain | `vibe up` starts, `vibe status` shows, `vibe down` removes (named volumes survive) |
| **Services session** (`vibe-svc`) | Workspace processes: dev servers, watchers, `rojo serve` — anything built from or watching the repo | Stood up by `project/post-start.sh` on every container start; `vibe attach` is the door in |
| **Host program** | GPU/OS-bound tools: Ollama, Roblox Studio — anything that shouldn't or can't run in a container | Runs on the host; the container connects out (or the host connects in on loopback) |

## Compose sidecars

Declare ordinary services in `.vibe/compose.yaml`:

```yaml
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: dev
    volumes:
      - dbdata:/var/lib/postgresql/data

volumes:
  dbdata: {}
```

`vibe up` starts them alongside `dev` (compose up is idempotent — it also
heals a died sidecar), `vibe status` lists them with a SERVICE column, and
`vibe down` removes them together with the project network. Named volumes
(`dbdata` above, and the agent-state volume) survive `down`; only
`docker volume rm` deletes data. The dev container reaches a sidecar by its
service name (`db:5432`) on the compose network.

## The services session (`vibe-svc`)

For processes that need the workspace, its toolchain, or its logs in view:

```bash
# .vibe/project/post-start.sh — runs on every container start; vibe-svc is
# idempotent per window name, so this is safe to rerun.
vibe-svc web  bun run dev
vibe-svc rojo rojo serve
```

Each service is one window (named after it) in the shared `services` tmux
session. `vibe attach` opens that session; logs are the window scrollback.
A window closes when its process exits, so a crashed service is restarted by
the next `vibe up` — or immediately with `vibe bootstrap`-style rerunning of
the hook, or by calling `vibe-svc` again from any shell.

Rules of the pattern:

- **Secrets are not loaded.** `vibe-svc` starts the command bare — the
  explicit-loading rule from [security.md](security.md) applies to services
  too. A service that needs `.env` wraps the runner:
  `vibe-svc api .vibe/harness/src/scripts/env-run.sh bun run api`.
- The session name follows `DEV_ATTACH_TMUX_SESSION` (default `services`) —
  `vibe attach` and `vibe-svc` resolve it identically, so the door always
  opens on the windows the hook created.
- `vibe-svc` is baked into the image; after moving the harness pin across
  the release that introduced it, run `vibe rebuild` once before hooks can
  use it.

## Host programs

Some things belong on the host: GPU inference servers (Ollama —
[local-models.md](local-models.md)), GUI applications (Roblox Studio —
[roblox.md](roblox.md)). Two connection directions, both opt-in per project
in `.vibe/compose.yaml`:

- **Container → host**: add the host gateway alias, then address
  `host.docker.internal:<port>`:

  ```yaml
  services:
    dev:
      extra_hosts:
        - "host.docker.internal:host-gateway"
  ```

- **Host → container**: publish loopback-only —
  `ports: ["127.0.0.1:34872:34872"]`. Never publish bare (`"X:Y"` binds
  `0.0.0.0`); the loopback bind is the sanctioned exception to the
  no-published-ports rule.

The harness never manages host processes — start them yourself
(`src/scripts/host/start-ollama.sh` is the worked example of a tuned host
service launcher).
