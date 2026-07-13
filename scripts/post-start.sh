#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
source "$script_dir/lib.sh"

cd -- "$REPO_ROOT"

# Self-heal execution bits on the project-owned launchers: checkouts done with
# core.fileMode=false (Windows-side clones, some VS Code git operations) restore
# these files without the +x recorded at install time.
chmod +x "$DEVCONTAINER_DIR/dev" "$DEVCONTAINER_DIR/project/"*.sh 2>/dev/null || true

# pipefail makes the doctor exit status win over tee's.
if ! bash "$script_dir/doctor.sh" 2>&1 | tee /tmp/dev-doctor.log; then
  warn "Environment checks reported problems; see /tmp/dev-doctor.log"
fi

project_hook="$DEVCONTAINER_DIR/project/post-start.sh"
if [[ -f "$project_hook" ]]; then
  if ! bash "$project_hook"; then
    warn "Project post-start hook failed"
  fi
fi

exit 0
