#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
source "$script_dir/lib.sh"

cd -- "$REPO_ROOT"
log "Bootstrapping $REPO_ROOT"

# One subdir per agent CLI inside the shared state volume.
mkdir -p -- \
  "${CLAUDE_CONFIG_DIR:-$HOME/.agents/claude}" \
  "${CODEX_HOME:-$HOME/.agents/codex}" \
  "$HOME/.agents/grok"

# Keep the persisted Claude state internally consistent with the native installation.
if command -v claude >/dev/null 2>&1; then
  claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  claude_cfg="$claude_dir/.claude.json"
  mkdir -p -- "$claude_dir"
  if [[ ! -f "$claude_cfg" ]]; then
    printf '{"installMethod":"native","autoUpdates":false}\n' >"$claude_cfg"
    chmod 600 "$claude_cfg"
  elif command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq '.installMethod = "native" | .autoUpdates = false' "$claude_cfg" >"$tmp"
    mv -- "$tmp" "$claude_cfg"
    chmod 600 "$claude_cfg"
  fi
fi

if [[ "$DEV_AUTO_INSTALL" == "1" ]]; then
  if [[ -f pyproject.toml && -f uv.lock ]]; then
    require_command uv
    run_step "Syncing locked Python environment" uv sync --frozen
  fi

  if [[ -f bun.lock || -f bun.lockb ]]; then
    require_command bun
    run_step "Installing locked Bun dependencies" bun install --frozen-lockfile
  elif [[ -f pnpm-lock.yaml ]]; then
    require_command pnpm
    run_step "Installing locked pnpm dependencies" pnpm install --frozen-lockfile
  elif [[ -f package-lock.json ]]; then
    require_command npm
    run_step "Installing locked npm dependencies" npm ci
  elif [[ -f yarn.lock ]]; then
    require_command yarn
    run_step "Installing locked Yarn dependencies" yarn install --immutable
  fi

  if [[ -f rokit.toml ]]; then
    require_command rokit
    run_step "Installing Rokit-managed tools" rokit install
  fi

  if [[ -f wally.toml ]]; then
    require_command wally
    run_step "Installing Wally dependencies" wally install
  fi
fi

if [[ "$DEV_AUTO_GIT_HOOKS" == "1" && -d .githooks ]]; then
  hooks_path="$REPO_ROOT/.githooks"
  run_step "Configuring repository Git hooks" git config --local core.hooksPath "$hooks_path"
fi

if [[ "$DEV_AUTO_GIT_LFS" == "1" && -f .gitattributes ]] \
  && grep -Eq 'filter=lfs|filter[[:space:]]+lfs' .gitattributes; then
  require_command git-lfs
  run_step "Initializing Git LFS for this repository" git lfs install --local
fi

project_hook="$DEVCONTAINER_DIR/project/post-create.sh"
if [[ -f "$project_hook" ]]; then
  run_step "Running project post-create hook" bash "$project_hook"
fi

log "Bootstrap complete. Run: ./.devcontainer/dev doctor"
