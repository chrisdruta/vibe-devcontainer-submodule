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
./.devcontainer/vibe rebuild                      # if the Dockerfile changed
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

- Run `./.devcontainer/vibe doctor`.
- Run `./.devcontainer/vibe rebuild` when the update touched the `Dockerfile` or
  anything under `templates/` you want re-rendered (template changes only affect
  newly installed projects; your project-owned files are never rewritten —
  re-run `install.sh --force` if you want a fresh seed, your old files are backed up).

## Agent-driven update

Moving the pin is mechanical; reconciling the project-owned seeded files with
what new versions expect (new `containerEnv` keys, settings denies, wrapper
changes) is the judgment-call part — like [onboarding](onboarding.md), a good
job for an agent. Paste into an agent at the project root:

```text
Update this project's vibe-devcontainer-submodule harness pin and reconcile
the project-owned files with the new version.

1. In .devcontainer/harness: git fetch --tags, then report the current pin
   (git describe --tags) and the latest tag. Before touching anything, read
   the harness CHANGELOG.md entries between those two versions and
   docs/updating.md — especially any "Crossing ..." migration sections that
   apply to this jump.
2. Check out the latest tag in the submodule and stage the pin move.
3. Reconcile the project-owned files against the new templates in
   .devcontainer/harness/templates/:
   - devcontainer.json: adopt new containerEnv keys and build args from the
     template (e.g. GH_CONFIG_DIR as of v0.4.0);
   - config.env: adopt new toggles, keeping the project's current values;
   - the wrapper: copy templates/vibe over .devcontainer/vibe — and if this
     project still has .devcontainer/dev (pre-v0.4.0), git mv it to vibe
     first;
   - .claude/settings.json: merge new permission denies and statusline keys
     from templates/claude-settings.json without clobbering existing entries.
   Reconcile, don't reset: where the template and the project disagree, keep
   the project's value and flag it in your report.
4. Never weaken hardening while reconciling: no sudo, no docker-socket
   mounts, no published ports.
5. Verify with vibe doctor. If the Dockerfile or devcontainer.json changed, a
   rebuild is required — run ./.devcontainer/vibe rebuild on the host; if you
   are running inside the container, stage everything and ask the user to
   rebuild instead.
6. Commit the pin move and the reconciliations together. Report: old -> new
   version, each file changed and why, and anything in the changelog that
   needs a human decision.
```

Review the diff before pushing — the seeded files are project-owned, and the
agent is instructed to prefer your values over the templates on conflict.

## Crossing the v0.4.0 rename from an older install

The launcher was renamed `dev` → `vibe` in v0.4.0 and the back-compat shim was
dropped in v0.5.0, so a pre-v0.4.0 project's seeded `.devcontainer/dev`
wrapper stops working when the pin moves to ≥ v0.5.0 (it execs
`harness/dev`, which no longer exists — the failure message misleadingly
suggests a missing submodule). **In the same commit as the pin bump**, replace
the wrapper:

```bash
git mv .devcontainer/dev .devcontainer/vibe
cp .devcontainer/harness/templates/vibe .devcontainer/vibe
```

Two more seeded files are worth reconciling by hand (or with
`install.sh --force`) to pick up the v0.4.0 features:

- `devcontainer.json`: add `"GH_CONFIG_DIR": "/home/vscode/.agents/gh"` to
  `containerEnv` — without it, `gh auth login` lands in the container
  filesystem and dies on every rebuild instead of persisting in the state
  volume ([configuration.md → GitHub access](configuration.md)).
- `.claude/settings.json`: merge the `Read(./.env)` / `Read(./.env.*)` denies
  (and, pre-v0.3.0, the statusline) from `templates/claude-settings.json`.

Optionally rename the wrapper to match the docs: `git mv .devcontainer/dev
.devcontainer/vibe`, then copy the current `templates/vibe` over it (the new
wrapper tries both launcher names, so it also works if the pin ever moves back).
