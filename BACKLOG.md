# Backlog

Ideas accepted but not scheduled. Items graduate into a release when they get
designed; entries here are one paragraph of intent, not a spec.

- **Interactive installer.** `install.sh` is flag-driven (`--preset`, `--url`,
  `--ref`, `--force`); with no flags on a tty it could interview instead:
  pick a preset from the list, toggle the extras (`INSTALL_CODEX` /
  `INSTALL_GROK` / `INSTALL_NODE`), seed the obvious `config.env` values, and
  confirm before touching the target repo. Flags keep working unchanged for
  scripted/CI use; interactive mode is sugar over the same code path.

- **Auto-symlink `vibe` into the project root.** Consumers today run
  `./.devcontainer/vibe up` (install.sh seeds the CLI at `.devcontainer/vibe`).
  Have the installer also drop a root-level `vibe -> .devcontainer/vibe`
  symlink so the everyday spelling is `./vibe up`. To decide: commit the
  symlink vs. append it to `.gitignore` (a committed symlink is harmless on
  Linux/WSL but noisy for Windows-native checkouts), and whether existing
  projects get it on pin update or only at install time.

- **Reduced-trust profile for unattended runs.** Promised in
  docs/security.md ("planned but not implemented"): a config.env posture for
  long autonomous tasks — no `GH_TOKEN` passthrough (or a minimum-permission
  fine-grained token), `DEV_AUTO_GIT_HOOKS=0` / `DEV_AUTO_INSTALL=0`, and a
  doctor mode that verifies the reduced posture instead of the interactive
  one. Review and push stay host-side.

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

- **Reorganize `scripts/` into subdirectories.** Post-yazi the directory is
  smaller but still flat (~13 files). `scripts/*` paths are public
  interface (referenced by project-owned seeded files: devcontainer.json
  lifecycle hooks, .claude/settings.json hook + statuslines, seeded
  AGENTS.md), so any move needs one-release compat shims at the old paths
  and a changelog flag for the pin-update reconcile.
