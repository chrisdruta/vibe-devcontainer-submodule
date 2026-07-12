# Updating the harness

Every consuming project pins the harness submodule to a **commit SHA** — nothing
changes underneath you until you deliberately move the pin. Treat updates as a
review-the-diff moment, not a blind pull.

## Recommended: update to a tagged release

```bash
git -C .devcontainer/harness fetch --tags
git -C .devcontainer/harness tag --list          # see what's available
git -C .devcontainer/harness checkout v0.1.0
git diff --submodule .devcontainer/harness       # review what changed
git add .devcontainer/harness
git commit -m "Update devcontainer harness to v0.1.0"
./.devcontainer/dev rebuild                      # if the Dockerfile changed
```

Tags mark intentional upgrade points and rollback targets; rolling back is the same
flow with an older tag.

## Convenience: follow the branch

```bash
git submodule update --remote --merge .devcontainer/harness
git add .devcontainer/harness && git commit -m "Update devcontainer harness"
```

This moves the pin to the tip of the configured branch (`--ref` at install time,
default `main`) — fine for your own repositories, but it takes whatever is on the
branch without a version decision. Prefer tags for anything you care about.

## Updating many repositories

The pin lives in each consuming repo, so each repo updates independently. A quick
sweep over everything under `~/dev`:

```bash
for repo in ~/dev/*/.devcontainer/harness; do
  git -C "${repo%/.devcontainer/harness}" submodule update --remote --merge .devcontainer/harness
done
```

…then review and commit per repo.

## After updating

- Run `./.devcontainer/dev doctor`.
- Run `./.devcontainer/dev rebuild` when the update touched the `Dockerfile` or
  anything under `templates/` you want re-rendered (template changes only affect
  newly installed projects; your project-owned files are never rewritten —
  re-run `install.sh --force` if you want a fresh seed, your old files are backed up).
