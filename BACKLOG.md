# Backlog

Ideas accepted but not scheduled. Items graduate into a release when they get
designed; entries here are one paragraph of intent, not a spec.

- **RESOLVED (2026-07, both phases at once): the devcontainer-engine
  exit.** Implemented as the pre-v1.0 engine swap: `vibe` drives docker
  compose + docker exec directly, the consumer layout is `.vibe/` with a
  root `./vibe` symlink, and the devcontainer CLI/Node host dependency is
  gone (see CHANGELOG Unreleased). Remaining from this item graduated to
  its own entry below: renaming the repository.

- **Rename the repository — SCHEDULED pre-v1.0 (decided 2026-07-20).** The `-devcontainer-` in
  `vibe-devcontainer-submodule` no longer describes the project post-engine-swap
  (candidate: `vibe-harness`). GitHub redirects old clone/submodule URLs
  indefinitely, so existing consumers keep working, but the name is embedded in
  places a redirect doesn't fix: the `install.sh` submodule-add URL and help
  text, README title/badges, seeded docs, and the onboarding prompt. Do it as
  its own release — ideally before v1.0 while the consumer count is small — and
  walk known consumers' `.gitmodules` URLs forward afterwards. Explicitly out of
  scope (decided 2026-07-20): renaming the in-container `vscode` user — it comes
  from the devcontainers base images and is load-bearing ABI (extension
  `USER vscode` contract, `/home/vscode/.agents` paths).

- **RESOLVED (2026-07): interactive installer.** Implemented alongside the
  submodule-first install flow: `install.sh` with no arguments on a tty
  interviews (preset, extras via the new `--extras`
  codex/grok/node/playwright, confirm); any argument or no tty keeps exact
  flag behavior for scripted/CI use.

- **RESOLVED (2026-07): auto-symlink `vibe` into the project root.**
  install.sh now seeds a committed `vibe -> .vibe/vibe` symlink (skipped if
  a real file is in the way); existing projects get it during the compose
  migration. Harmless on Linux/WSL/macOS checkouts; Windows-native
  checkouts see a text file, which was accepted.

- **Reduced-trust profile for unattended runs.** Promised in
  docs/security.md ("planned but not implemented"): a config.env posture for
  long autonomous tasks — `DEV_AUTO_GIT_HOOKS=0` / `DEV_AUTO_INSTALL=0` and a
  doctor mode that verifies the reduced posture instead of the interactive
  one. Review and push stay host-side. The credential half landed early
  (2026-07-20): the `GH_TOKEN` create-time passthrough is gone entirely —
  GitHub auth is `gh auth login` with a fine-grained PAT, persisted in the
  per-project state volume, so the remaining scope is the DEV_AUTO_* posture.

- **RESOLVED (2026-07, differently): the "rewrite the preview subsystem in
  Go" item.** The trigger fired early — dogfooding judged the homegrown
  viewer clunky — and the resolution beat writing our own binary: the
  review viewer is now yazi (pinned release binary in the Dockerfile),
  which is the same class of solution maintained upstream. The remaining
  harness-owned render code is the small `vibe show` one-shot path
  (preview-lib.sh); if THAT grows or breaks repeatedly, fold it into yazi
  usage or revisit. The host launcher, installer, and lifecycle scripts
  stay bash regardless — they are the bootstrap and must run on stock
  macOS bash 3.2 with nothing installed.

- **RESOLVED (2026-07): reorganize `scripts/` into subdirectories.**
  Superseded by the `src/` reorg that rode along with the devcontainer-engine
  exit (the breaking release made the path moves free): everything
  harness-internal lives under `src/`, entry points stay at the root, and
  `examples/` carries rendered per-preset seeds verified against real
  installs. `src/*` paths are the new public interface (AGENTS.md).

- **`vibe open`: host terminal-layout adapter — first feature after v1.0
  (decided 2026-07-20).** One command that opens the workspace as native
  terminal panes, Windows Terminal first: each pane runs a stable `vibe`
  command (`vibe agent`, `vibe agent -a codex`, `vibe review`, `vibe shell`),
  so the terminal owns tabs/panes/rendering while the per-agent tmux sessions
  keep persistence. The adapter lives host-side (`src/scripts/host/`), knows
  nothing project-specific, and prints the per-pane commands when no supported
  terminal is found (that fallback IS the macOS story for now). A prototype
  with hardcoded layouts shipped 2026-07-20; graduation means config-driven
  layouts (project-declared panes) and, only after that stabilizes, maybe
  other frontends (WezTerm — see decision record below).

- **Productize worktrees.** Today parallel worktrees work but are manual:
  a differently-named worktree directory gets its own `agent-state-<basename>`
  volume, which means fresh agent logins per worktree unless the user edits
  the volume `source=` themselves (docs/agent-state.md). Add
  `vibe worktree create/list/remove` plus an explicit state-scope choice
  (default: today's per-workspace isolation; opt-in: worktrees of one repo
  share a volume via explicit `source=` in the seeded compose override).
  Constraint: the `agent-state-<workspace-basename>` default derivation is
  ABI (AGENTS.md) — sharing happens by writing an explicit `source=`, never
  by changing the derivation. Scheduled after `vibe open`.

- **Decision records from the 2026-07-20 external design review** (so future
  reviews don't relitigate): **REJECTED — session-backend abstraction**
  (`VIBE_SESSION_BACKEND=tmux|shpool|none` and renaming the `DEV_AGENT_TMUX*`
  vars). tmux here is not just persistence: the `prefix+i` preview window,
  the Claude-hook DDS feed, and chafa passthrough rendering are tmux-specific,
  and `DEV_AGENT_TMUX=0` already is the "none" backend. An abstraction layer
  plus a config deprecation cycle buys nothing at the current consumer count.
  **DEFERRED — version-lock machinery** (`vibe versions lock`): Dockerfile
  ARGs already pin what upstream supports; Claude `stable` and the base-image
  tag float deliberately. If reproducibility ever bites, the cheapest step is
  a base-image digest pin, not a lockfile subsystem. **NOT NOW — WezTerm
  frontend**: revisit only as another `vibe open` adapter once layouts are
  config-driven.
