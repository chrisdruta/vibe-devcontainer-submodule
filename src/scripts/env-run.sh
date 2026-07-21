#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
source "$script_dir/lib.sh"

if (($# == 0)); then
  echo "Usage: env-run.sh COMMAND [ARGUMENT ...]" >&2
  exit 2
fi

cd -- "$REPO_ROOT"
env_path="$REPO_ROOT/$DEV_ENV_FILE"

if [[ -f "$env_path" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$env_path"
  set +a
fi

# Agent runs (identity minted by agent-entry.sh) trade the zero-cost exec
# for a wrapper that records process death: the one transition no Claude
# hook can report, and the liveness layer that dominates semantic state
# (BACKLOG "agent state at a glance"). EXIT fires on errexit and on
# trappable signals too; the explicit exit keeps the agent's code.
if [[ -n "${VIBE_AGENT_INSTANCE:-}" ]]; then
  # shellcheck disable=SC2154  # rc is assigned inside the single-quoted trap
  trap 'rc=$?; VIBE_AGENT_EXIT=$rc bash "$script_dir/agent-state-hook.sh" __exit </dev/null >/dev/null 2>&1 || true; exit $rc' EXIT
  "$@"
else
  exec "$@"
fi
