#!/usr/bin/env bash
#
# prefix+v in vibe tui: grab the host clipboard image (`vibe clip`) and type
# the resulting container path into the agent pane — replaces the whole
# switch-tab / clip / copy / paste dance with one chord.
#
# Runs as a tmux run-shell job on the HOST server, cwd = repo root (the
# binding cd's to #{session_path} first); run-shell provides TMUX, so
# plain `tmux` is the right binary/socket (same rule as sidebar/dock).
# $1 = window id.

set -euo pipefail

window="${1:-}"

note() {
  tmux display-message "$1" 2>/dev/null || true
}

if ! out="$(./vibe clip 2>&1)"; then
  last_line="$(printf '%s\n' "$out" | tail -1)"
  note "vibe clip: ${last_line:-failed}"
  exit 0
fi
path="$(printf '%s\n' "$out" | sed -n 's/^In the container: //p' | tail -1)"
if [ -z "$path" ]; then
  note "vibe clip: no container path in output"
  exit 0
fi

# Prefer the pane tui.sh marked as the agent; fall back to the window's
# active pane (ad-hoc windows never get roles stamped).
target="$(tmux list-panes -t "$window" -F '#{pane_id} #{@vibe_role}' 2>/dev/null \
  | awk '$2 == "agent" { print $1; exit }')"
if [ -z "$target" ]; then
  target="$(tmux list-panes -t "$window" -F '#{?pane_active,#{pane_id},}' 2>/dev/null | grep . | head -1)"
fi
if [ -z "$target" ]; then
  note "clip saved ($path) but no pane to type it into"
  exit 0
fi

# Literal keystrokes, no Enter — the path lands in the agent's prompt for
# you to submit (or prepend words to).
tmux send-keys -t "$target" -l "$path"
note "clip → $path"
