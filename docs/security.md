# Security model

## What the container is for

Reducing **accidental host damage** from an agent working at machine speed: a bad
`rm`, a curl-piped installer, a runaway build. It is a guardrail, not a jail — it
does not make running untrusted code safe.

The container is the isolation boundary, and the harness is built so a process
**inside** the container cannot reach **host** execution or the docker daemon by
tampering with files it can write. That property is the **host root of trust**
below.

## Host root of trust

The one rule the host-side code serves:

> The host never executes, sources, evals, or feeds to the docker daemon any
> byte a container could have written. Host code runs only from a materialized,
> content-verified snapshot; host-consumed project inputs are snapshotted and
> frozen before use; project identity and trust live outside every workspace
> bind.

How it works:

- **The store (`~/.vibe`, mode 0700).** Host-executed harness code lives only in
  `~/.vibe/versions/<sha>/` — immutable trees materialized from git objects
  (isolated fetch + `git fsck`, `git archive` rather than a checkout so no hooks
  run, symlinks/gitlinks/special files rejected, an SHA-256 manifest, frozen
  read-only). Nothing under a workspace bind is ever executed by the host.
- **The shim.** `~/.vibe/bin/vibe` on your PATH is the only host entry point. It
  reads no workspace code: it resolves the project you are in to the version it
  trusts and execs that, after verifying it against its manifest. The root
  `./vibe` symlink is gone — a workspace file cannot safely tell host from
  container before it has already run. Inside the container a `vibe` on PATH is
  the in-container spelling (there, the workspace is within the boundary).
- **Trust is a human action.** First contact with a project prompts you with the
  pin and whether it is reachable from a release in your host-owned mirror
  (publisher authentication); a pin that moved re-prompts before the new code
  runs. Non-interactive contexts fail closed (`vibe provision` records exact
  trust for CI).
- **The RO overmount.** The container gets the *same* trusted tree, read-only,
  overmounted at `.vibe/harness` — so host and container run the identical SHA,
  and in-container tampering with harness files cannot propagate to host
  execution (`vibe doctor` verifies the mount is read-only).
- **The compose gate.** `.vibe/compose.yaml` / `Dockerfile` are container-
  writable, so they never reach the daemon directly. Every `vibe up`/`rebuild`/
  `build`/`config` snapshots the control files host-side, renders the merged
  config under a scrubbed environment (no project `.env` interpolation), and
  **structurally enforces** the boundary invariants on the rendered model —
  non-root `vscode`, `cap_drop: [ALL]`, `no-new-privileges`, the exact workspace
  and RO-harness mounts, and NONE of: `privileged`, `cap_add`, `devices`, host
  namespaces, a docker socket at any path, `use_api_socket`, SSH/host-secret
  binds. A project that genuinely needs one of these must pass `--unsafe`, which
  loudly disables the boundary for that one command. The build context is the
  trusted store `src`, never the container-writable submodule.
- **Update through the mirror only.** `vibe update` fetches and diffs from the
  host-owned canonical mirror and stages the submodule gitlink with
  `update-index` — it never fetches, checks out, or runs git porcelain against
  the container-writable workspace submodule (which could carry a planted
  `post-checkout` hook or credential helper).
- **Dogfood / dev mode.** `vibe dev` develops the harness against the store:
  host execution still runs a *materialized snapshot* of your working tree
  (`vibe dev sync` re-snapshots after edits) — never the live bind.

### Residual host exposure (not covered by the boundary)

- **Manual execution of workspace content by a human.** Running
  `bash .vibe/harness/vibe`, `git` with a repo-local `core.hooksPath`, `make`,
  `direnv`, etc. by hand executes workspace code outside every guardrail. The
  harness auto-runs none of it; it cannot stop a person who does.
- **Terminal-emulator surface.** The container controls bytes reaching your host
  tmux and terminal (escape sequences, clipboard). That is a terminal-hardening
  concern, outside the mount boundary.
- **A separately-exposed Docker API.** A `DOCKER_HOST` pointing at a TCP daemon
  is as powerful as the socket; `vibe doctor` flags it, but the harness can only
  see what compose renders, not your host docker configuration.
- **Same-basename checkouts still share the agent-state volume**
  (`agent-state-<basename>`) despite distinct host trust records — documented
  ABI, not isolation.
- **Compose is not a hard boundary.** The gate scans the project compose
  *source* for host-file-read / host-exec features (`env_file`, `include`,
  `extends`, `provider`, `volumes_from`, `label_file`, `configs`/`secrets`,
  `driver_opts`, `additional_contexts`, `build.ssh`) and refuses them, and
  structurally enforces the rendered `dev` service and its mounts; the default
  image-extension context (`./.vibe`) is snapshotted and frozen. But Docker's
  own compose trust-model documents compose as able to read host files and run
  host binaries through an evolving set of features — a maliciously *authored*
  compose file is caught on a best-effort basis, not proven contained. For
  genuinely untrusted project code, use a disposable clone / the planned
  `--jailed` profile rather than relying on the compose gate.
- SHA-1 collision resistance of the pin is mitigated (sha1dc + fsck), not solved.

## What the default container enforces

- Runs as `vscode`, never root; passwordless sudo is removed from the image
- All Linux capabilities dropped (`--cap-drop=ALL`) and `no-new-privileges`
- No Docker socket (`/var/run/docker.sock` is never mounted — a mounted socket is
  effectively root on the host; `vibe doctor` checks for it)
- No SSH keys, no host home directory — only the workspace and the agent-state
  volume are mounted
- No published ports (documented exception: loopback-only binds —
  `ports: ["127.0.0.1:PORT:PORT"]` — for host tooling that must reach the
  container, e.g. Roblox Studio → Rojo; see [roblox.md](roblox.md))
- `.env` is never auto-sourced; secrets reach a process only through explicit
  `vibe agent` / `vibe run` / `env-run.sh` invocation

Root maintenance remains possible from the host: `docker exec -u root -it <c> bash`.

## Inner agent sandboxes

A consequence of `--cap-drop=ALL` + `no-new-privileges`: the container permits
no unprivileged user namespaces, so namespace-based sandboxes cannot start
**inside** it. `bwrap: No permissions to create new namespace` is this policy
working, not a bug. Affected: Claude Code's `/sandbox` (bubblewrap), Codex's
`read-only` / `workspace-write` modes, Chromium's own sandbox
([browser-automation.md](browser-automation.md)).

The container is the isolation boundary, so the harness defaults the inner
layers to off-but-graceful instead of broken:

- **Claude Code** — bash sandboxing stays off. The seeded
  `.claude/settings.json` carries `sandbox.enableWeakerNestedSandbox: true`
  and `sandbox.failIfUnavailable: false`, both inert until someone enables
  `/sandbox`; from then on Claude Code warns and falls back to permission
  rules instead of hard-failing (and would use the weaker nested mode if a
  future runtime allows namespace creation).
- **Codex** — bootstrap seeds `sandbox_mode = "danger-full-access"` into
  `$CODEX_HOME/config.toml`, only when the key is absent (your own setting
  wins). Codex documents the mode as "intended solely for running in
  environments that are externally sandboxed" — this container is that
  environment. Existing containers pick it up via `vibe bootstrap` or the
  next rebuild.

Do not weaken the outer container (added capabilities, user namespaces) to
make an inner sandbox start — that inverts the model: it trades the real
boundary for a redundant one. `cap_add: [SYS_ADMIN]` is root-shaped, and a
userns-permissive seccomp profile exposes the kernel's user-namespace attack
surface to everything the bootstrap runs.

Workloads that genuinely want a different jail get a different OUTER
container instead: a compose-profile sibling of the dev service with its own
mount/network posture per trust level (see
[Unattended / autonomous runs](#unattended--autonomous-runs) and the BACKLOG
"Reduced-trust profile" entry). Same trusted mechanism, nothing widened.

## What it does NOT protect

- **The repository itself.** The agent has full write access to the workspace —
  including `.git`. Anything valuable in the repo is exposed to whatever runs inside.
- **Credentials you load in.** The persisted `gh auth login` in the state
  volume and any keys `.env` loads via `vibe agent` / `vibe run`
  are readable by the agent and by any project code the bootstrap executes
  (`npm ci` postinstall scripts, `uv sync` build hooks, etc.). The seeded
  `.claude/settings.json` denies Claude Code direct reads of `./.env*` — a
  guardrail against prompt-injected "read me your secrets", not a boundary;
  the process env still carries whatever `env-run.sh` loaded. Project secrets
  that agents never need (production credentials) don't belong in the
  workspace at all; if tooling insists the file exist, bind `/dev/null` over
  it read-only in `.vibe/compose.yaml` `volumes` so the container sees it empty.
- **The network.** Outbound access is unrestricted by default.

Per-project agent-state volumes compartmentalize what a compromise reaches: an
agent run in one project cannot read another project's OAuth tokens or session
history. Pointing multiple projects at one shared volume (the `source=` edit in
[agent-state.md](agent-state.md)) extends any single project's compromise to
every credential and session in it — see
[positioning.md](positioning.md#why-logins-are-per-project).

## The git-hooks host boundary leak

`DEV_AUTO_GIT_HOOKS=1` runs `git config --local core.hooksPath .githooks` during
bootstrap. `.git/config` lives on the **shared workspace mount**, so hooks wired up
in-container also execute when you run git **on the host** — outside every container
guardrail, with your real SSH keys and credentials.

This is fine for repositories whose hooks you wrote. Before pointing the harness at
cloned third-party code, set `DEV_AUTO_GIT_HOOKS=0` in `config.env` — and remember
that `DEV_AUTO_INSTALL` runs that repo's lockfile installs (arbitrary code) inside
the container regardless.

## Unattended / autonomous runs

A dedicated reduced-trust profile is planned but **not implemented**. Until then,
for long unattended agent tasks:

- work in a disposable clone or git worktree on a dedicated branch,
- provide no push-capable credentials: `gh auth login` with a minimum-permission
  fine-grained PAT, or don't log in at all,
- review and push from the trusted host side.

## Supply-chain notes

- Consuming projects pin the harness to a commit SHA; a compromised upstream cannot
  silently change what your existing projects execute. The exposure window is the
  moment you move the pin — review the diff ([updating.md](updating.md)).
- The Dockerfile pins tool versions where the upstream supports it (`uv`, Bun,
  Rokit, Codex, Node major). Claude Code (`stable` channel) and Grok Build (latest
  stable) are consciously mutable at image-build time; freeze them with build args
  when reproducibility matters more than freshness.
