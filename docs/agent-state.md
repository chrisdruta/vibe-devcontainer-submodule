# Agent state and multi-agent use

## The state volume

Each project gets one named Docker volume, mounted at `~/.agents` in the container:

```text
agent-state-<workspace-folder-basename>
├── claude/   # CLAUDE_CONFIG_DIR
├── codex/    # CODEX_HOME
└── grok/     # ~/.grok is a symlink here (Grok has no config-dir env override)
```

Log in to each agent once per project; logins survive `dev rebuild` and image
upgrades. The volume mountpoint is pre-created in the image owned by `vscode` —
necessary because with sudo removed and all capabilities dropped, a root-owned
volume could never be repaired from inside the container.

## Installed agents

| Agent       | Command  | Enable via            | Auth                          |
| ----------- | -------- | --------------------- | ----------------------------- |
| Claude Code | `claude` | default               | OAuth or `ANTHROPIC_API_KEY`  |
| Codex CLI   | `codex`  | `INSTALL_CODEX=true`  | OAuth or `OPENAI_API_KEY`     |
| Grok Build  | `grok`   | `INSTALL_GROK=true`   | OAuth or `XAI_API_KEY`        |

`DEV_AGENT_CMD` in `config.env` selects the default for `dev agent`; run the others
with `dev run codex` / `dev run grok`, or side by side in tmux panes via `dev shell`.
Agents can also invoke each other as subprocesses (e.g. Claude shelling out to
`codex` or `grok` to cross-check work) — they share the workspace and the
`.env`-loaded credentials of the process that spawned them.

Grok's binary is materialized into `~/.local/bin` at image build time (its installer
would otherwise symlink into `~/.grok/downloads`, which the volume shadows); its
self-update therefore does not stick — update Grok by rebuilding the image.

## Worktrees and naming

The volume name uses only the workspace folder **basename**:

- Different worktree folder names (`my-project`, `my-project-feature-x`) get
  **separate** state volumes → separate logins, full isolation.
- Two projects whose folders share a basename (e.g. `~/dev/a/app` and `~/dev/b/app`)
  **collide** on the same volume — rename one folder, or change the volume `source=`
  in that project's `devcontainer.json` to a unique key.

## Resetting state

```bash
docker volume ls | grep agent-state
docker volume rm agent-state-<name>      # container must not be running
```

The next `dev up` recreates it empty; agents will ask to log in again.
