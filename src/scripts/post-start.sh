#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh disable=SC1091
source "$script_dir/lib.sh"

cd -- "$REPO_ROOT"

# Self-heal execution bits on the project-owned launchers: checkouts done with
# core.fileMode=false (Windows-side clones, some VS Code git operations) restore
# these files without the +x recorded at install time.
chmod +x "$VIBE_DIR/vibe" "$VIBE_DIR/project/"*.sh 2>/dev/null || true

# Complete GitHub git wiring when — and only when — the user has logged into gh:
# the login is the opt-in; without it this block never runs. gh becomes git's
# credential helper, and git@github.com: remotes rewrite to HTTPS (the container
# has no SSH keys, so a repo cloned over SSH on the host is otherwise push-dead
# in here). Both settings land in the container-local ~/.gitconfig, which is why
# this reruns on every start: it restores them after a rebuild.
if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
  gh auth setup-git 2>/dev/null || warn "gh is logged in but credential-helper setup failed"
  # Rewrite both GitHub SSH remote forms — scp-style (git@github.com:owner/repo)
  # and ssh:// (ssh://git@github.com/owner/repo) — to HTTPS. insteadOf is
  # multi-valued, so clear then re-add both: idempotent across every start,
  # where a plain set would clobber and --add would accumulate duplicates.
  if command -v git >/dev/null 2>&1; then
    git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
    if ! { git config --global --add url."https://github.com/".insteadOf "git@github.com:" \
        && git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"; }; then
      warn "could not set the GitHub SSH->HTTPS rewrite"
    fi
  fi
fi

# pipefail makes the doctor exit status win over tee's.
if ! bash "$script_dir/doctor.sh" 2>&1 | tee /tmp/dev-doctor.log; then
  warn "Environment checks reported problems; see /tmp/dev-doctor.log"
fi

# The doctor above is advisory by design — its MISSes describe the
# environment, they don't mean the start failed. The project hook is
# different: it is the project declaring what a usable start means.
# Swallowing its failure made `vibe up` report success on a broken
# environment (2026-07 external review), so under the strict default it
# now propagates — do_up surfaces the nonzero exit.
project_hook="$VIBE_DIR/project/post-start.sh"
if [[ -f "$project_hook" ]]; then
  if ! bash "$project_hook"; then
    if [[ "$DEV_BOOTSTRAP_STRICT" == "1" ]]; then
      fail "Project post-start hook failed"
      exit 1
    fi
    warn "Project post-start hook failed; continuing because DEV_BOOTSTRAP_STRICT=0"
  fi
fi

exit 0
