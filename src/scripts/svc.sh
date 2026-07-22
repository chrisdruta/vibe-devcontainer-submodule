#!/usr/bin/env bash
#
# vibe-svc NAME COMMAND [ARG ...] — idempotently run a long-lived dev
# service as window NAME in the shared services tmux session (`vibe attach`
# is the door in; logs are the window scrollback).
#
# Window-exists means running: windows close when their process exits, so a
# crashed service is simply recreated by the next run — project post-start
# hooks call this on every container start. Baked as /usr/local/bin/vibe-svc
# (see src/Dockerfile) because hooks are plain bash processes that inherit
# no harness functions and can only rely on a fixed PATH name.
#
# Deliberately does NOT load .env: secrets reach a process only through the
# explicit runner. A service that needs them wraps it:
#   vibe-svc api .vibe/harness/src/scripts/env-run.sh bun run api
set -euo pipefail

usage="usage: vibe-svc NAME COMMAND [ARG ...]"
name="${1:?$usage}"
shift
[ "$#" -ge 1 ] || { echo "$usage" >&2; exit 2; }

# Hooks don't source config.env; resolve the session name from the nearest
# project config above $PWD (hooks run at the repo root; legacy layout
# covered for pre-migration projects).
if [ -z "${DEV_ATTACH_TMUX_SESSION:-}" ]; then
  dir="$PWD"
  while [ "$dir" != "/" ]; do
    for cfg in "$dir/.vibe/config.env" "$dir/.devcontainer/config.env"; do
      if [ -f "$cfg" ]; then
        # shellcheck disable=SC1090
        source "$cfg"
        break 2
      fi
    done
    dir="$(dirname -- "$dir")"
  done
fi
session="${DEV_ATTACH_TMUX_SESSION:-services}"

# tmux takes the window command as one shell string; %q keeps args intact.
# (With agent-entry.sh's two, this is the sanctioned tmux shell-string
# boundary — do not add another site.)
cmd="$(printf '%q ' "$@")"

pin() { # window-name idempotency needs tmux's auto-rename off per window
  tmux set-option -w -t "$1" automatic-rename off
}

if ! tmux has-session -t "=$session" 2>/dev/null; then
  win_id="$(tmux new-session -d -P -F '#{window_id}' -s "$session" -n "$name" "$cmd")"
  pin "$win_id"
  exit 0
fi

# Target by window id, not name (a name could collide with tmux's target
# glob/index syntax).
win_id="$(tmux list-windows -t "=$session" -F '#{window_id} #{window_name}' |
  awk -v n="$name" '$2 == n {print $1; exit}')"
if [ -n "$win_id" ]; then
  # A user tmux.conf with remain-on-exit keeps dead panes around — respawn.
  if [ "$(tmux display -p -t "$win_id" '#{pane_dead}')" = "1" ]; then
    tmux respawn-window -t "$win_id" "$cmd"
  fi
  exit 0
fi
win_id="$(tmux new-window -d -P -F '#{window_id}' -t "=$session" -n "$name" "$cmd")"
pin "$win_id"
