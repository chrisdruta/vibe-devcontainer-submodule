# Changelog

Consumers pin a commit; tags mark intentional upgrade points
(see [docs/updating.md](docs/updating.md)).

## Unreleased

- **`dev agent --cold`**: fresh-perspective agent session without repo instruction
  files — Claude via `--safe-mode`, Codex via `-c project_doc_max_bytes=0`; agents
  without a known skip mechanism refuse. Cold runs get their own tmux session
  (`<session>-cold`) so they never reattach to a warm one.
- **`dev agent -a/--agent CMD`**: per-invocation agent override (e.g.
  `dev agent -a codex`, composable with `--cold`) without touching
  `DEV_AGENT_CMD`; each override gets its own tmux session (`<session>-codex`).
- **`dev clip [DIR]`**: save the host clipboard image into the container's `/tmp`
  (or a workspace-relative `DIR` to keep it) and put the container path on the
  clipboard — the workaround for Ctrl-V image paste being unreachable from
  inside the container. WSL (PowerShell) and macOS (AppleScript); new host
  helper `scripts/host/clip-image.sh`.
- **Codex plugin for Claude Code auto-installed** when `INSTALL_CODEX=true`:
  post-create adds [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)
  (user scope, persisted in the agent-state volume), giving Claude sessions
  `/codex:review`, `/codex:rescue`, and friends without switching panes. Warns
  instead of failing bootstrap when offline.

## v0.3.0 — 2026-07-12

- **playwright-deps Dev Container Feature** + [browser-automation recipe](docs/browser-automation.md):
  headless Chromium for shell-driven agent browsing (`@playwright/cli`). Feature
  option `version` pins the playwright release that resolves the apt dependency list.
- **`dev agent` can run in a persistent tmux session** (`DEV_AGENT_TMUX`, seeded on
  for new installs; unset = previous behavior). Rerunning attaches; detaching keeps
  the agent alive.
- **Onboarding scaffolding**: seeded `.devcontainer/AGENTS.md` (container rules for
  agents; import via `@.devcontainer/AGENTS.md`), [docs/onboarding.md](docs/onboarding.md)
  with an agent reconcile prompt.
- **Default Claude statusline**: harness-shipped `scripts/statusline.sh` /
  `scripts/subagent-statusline.sh`; `install.sh` seeds `.claude/settings.json`
  (statusline + sudo/su deny) when the project has none.
- **Hardening**: Dockerfile builds with `pipefail` and asserts installed binaries
  (a failed `curl | bash` previously produced a cached layer with the tool
  missing); launcher exec bits are recorded in the git index and self-healed at
  post-start (survives `core.fileMode=false` checkouts).
- verify.sh covers `features/`, seeded files, and index modes; CI workflow added.

## v0.2.0 — 2026-07-12

- macOS support: cross-platform Ollama host helper, arm64-verified image, docs.

## v0.1.0 — 2026-07-12

- Initial release: generic agent dev-container harness (hardened non-root image,
  preset installer, lifecycle scripts, agent-state volume, docs).
