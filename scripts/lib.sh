#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# These scripts live at .devcontainer/harness/scripts/ inside a consuming project.
HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEVCONTAINER_DIR="$(cd -- "$HARNESS_DIR/.." && pwd)"

find_repo_root() {
  # Anchor on the project's .devcontainer dir, not the harness: inside the submodule,
  # git rev-parse would report the submodule's own toplevel.
  if root="$(git -C "$DEVCONTAINER_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$root"
  else
    cd -- "$DEVCONTAINER_DIR/.." && pwd
  fi
}

# shellcheck disable=SC2034  # consumed by the scripts that source this file
REPO_ROOT="$(find_repo_root)"
CONFIG_FILE="$DEVCONTAINER_DIR/config.env"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

DEV_AGENT_CMD="${DEV_AGENT_CMD:-claude}"
DEV_BOOTSTRAP_STRICT="${DEV_BOOTSTRAP_STRICT:-1}"
DEV_AUTO_INSTALL="${DEV_AUTO_INSTALL:-1}"
DEV_AUTO_GIT_HOOKS="${DEV_AUTO_GIT_HOOKS:-1}"
DEV_AUTO_GIT_LFS="${DEV_AUTO_GIT_LFS:-1}"
DEV_ENV_FILE="${DEV_ENV_FILE:-.env}"
DEV_REQUIRED_COMMANDS="${DEV_REQUIRED_COMMANDS:-git gh jq rg uv claude}"

log() {
  printf '[dev] %s\n' "$*"
}

warn() {
  printf '[dev] WARN: %s\n' "$*" >&2
}

fail() {
  printf '[dev] ERROR: %s\n' "$*" >&2
  return 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: $command_name"
}

run_step() {
  local description="$1"
  shift
  log "$description"
  if "$@"; then
    return 0
  fi

  if [[ "$DEV_BOOTSTRAP_STRICT" == "1" ]]; then
    fail "$description failed"
  else
    warn "$description failed; continuing because DEV_BOOTSTRAP_STRICT=0"
  fi
}
