#!/usr/bin/env bash
#
# Sourced helper: find_repo_root_from_pwd prints the nearest ancestor of $PWD
# containing .devcontainer/devcontainer.json (the consuming project root), or
# returns 1. Shared by the host launcher (`vibe`) and update.sh so the walk
# can't drift between them. Host-side callers may be macOS: bash-3.2 only.
#
# Deliberately distinct from lib.sh's find_repo_root: container lifecycle
# scripts anchor on the .devcontainer dir they live under (their project is
# fixed by their location), while these host tools anchor on $PWD (a
# PATH-installed `vibe` must resolve whichever project you're standing in).

find_repo_root_from_pwd() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.devcontainer/devcontainer.json" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname -- "$dir")"
  done
  return 1
}
