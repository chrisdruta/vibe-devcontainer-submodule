#!/usr/bin/env bash
#
# `vibe ui` — the riced host-side tmux UI. One tmux server on a dedicated
# socket (-L vibe) for all vibe projects on this host; one session per
# project. The default layout is the pre-`vibe open` workflow folded into
# one surface: agent pane (docker exec -> container tmux, persistence as
# ever) beside a native HOST shell pane (git on the host side, vibe clip).
# More windows come from the palette (prefix+Space) or the "+" tab.
#
# Host-side: keep bash-3.2 compatible (stock macOS).

set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "Usage: ui.sh REPO_ROOT WS_BASE HARNESS_DIR PROJECT_NAME" >&2
  echo "(normally invoked via: vibe ui)" >&2
  exit 2
fi
repo_root="$1"
ws_base="$2"
harness_dir="$3"
project_name="$4"

socket="vibe"
conf="$harness_dir/src/config/tmux-ui.conf"
tmux_bin="${VIBE_UI_TMUX:-tmux}"

if [ -n "${TMUX:-}" ]; then
  echo "vibe ui hosts its own tmux — run it from a plain terminal." >&2
  echo "(already on the vibe socket? switch with: tmux -L vibe switch-client -t <session>)" >&2
  exit 1
fi

if ! command -v "$tmux_bin" >/dev/null 2>&1; then
  echo "vibe ui needs tmux on the host. Install the pinned 3.7b build:" >&2
  echo "  bash $harness_dir/src/scripts/host/install-tmux.sh" >&2
  echo "(a distro tmux >= 3.4 also works, but sixel image previews degrade below 3.7)" >&2
  exit 1
fi

# Version gate: 3.4 for styles-that-contain-formats and user mouse ranges
# (the conf depends on both); 3.7 is only a warning — below it, sixel
# images are cleared by adjacent-pane redraws (the pre-spike behavior).
raw_version="$("$tmux_bin" -V 2>/dev/null | sed 's/^tmux //')"
numeric="$(printf '%s\n' "$raw_version" | sed 's/^next-//; s/[^0-9.].*$//')"
major="${numeric%%.*}"
minor="${numeric#*.}"
minor="${minor%%.*}"
case "$major" in
  '' | *[!0-9]*) major=0 ;;
esac
case "$minor" in
  '' | *[!0-9]*) minor=0 ;;
esac
if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 4 ]; }; then
  echo "Host tmux is $raw_version; vibe ui needs >= 3.4 (styles with formats)." >&2
  echo "Install the pinned build: bash $harness_dir/src/scripts/host/install-tmux.sh" >&2
  exit 1
fi
if [ "$major" -eq 3 ] && [ "$minor" -lt 7 ]; then
  echo "Host tmux is $raw_version — fine, but image previews (vibe show) will not" >&2
  echo "survive pane redraws below 3.7. Pinned build: src/scripts/host/install-tmux.sh" >&2
fi

vtmux() {
  "$tmux_bin" -L "$socket" -f "$conf" "$@"
}

# Session per project. Friendly name first (basename); if a same-named
# session belongs to a DIFFERENT checkout, fall back to the unique
# per-checkout project name so two clones never share a session. Plain -t
# names throughout: on 3.7b, display-message -t "=name" silently resolves
# to empty formats (has-session accepts it, display-message doesn't), and
# exact names beat prefix matches anyway — with the path check catching
# anything a prefix match could confuse.
session="$ws_base"
if vtmux has-session -t "$session" 2>/dev/null; then
  existing_path="$(vtmux display-message -p -t "$session" '#{session_path}')"
  if [ "$existing_path" != "$repo_root" ]; then
    session="$project_name"
  fi
fi

if ! vtmux has-session -t "$session" 2>/dev/null; then
  # Default agent title = first word of the project's DEV_AGENT_CMD (the
  # config is container-side; this is a best-effort host read for the label).
  agent_title="claude"
  if [ -f "$repo_root/.vibe/config.env" ]; then
    configured="$(sed -n 's/^[[:space:]]*DEV_AGENT_CMD=//p' "$repo_root/.vibe/config.env" | tail -1 | tr -d '"'"'" | cut -d' ' -f1)"
    [ -n "$configured" ] && agent_title="$configured"
  fi

  # VIBE_NESTED rides the session environment into every pane: cexec
  # forwards it into docker exec, and agent-entry.sh turns the INNER
  # status bar off so only this server draws chrome.
  vtmux new-session -d -s "$session" -c "$repo_root" -e VIBE_NESTED=1 -n main "./vibe agent"
  # For the prefix+R reload binding.
  vtmux set-environment -g VIBE_UI_CONF "$conf"

  agent_pane="$(vtmux display-message -p -t "$session:main" '#{pane_id}')"
  vtmux set-option -p -t "$agent_pane" @vibe_role "agent"
  vtmux set-option -p -t "$agent_pane" @vibe_title "$agent_title"
  # Agent exit/detach keeps the pane corpse instead of collapsing the
  # layout; prefix+r respawns it.
  vtmux set-option -p -t "$agent_pane" remain-on-exit on

  host_pane="$(vtmux split-window -h -l '30%' -c "$repo_root" -t "$agent_pane" -P -F '#{pane_id}')"
  vtmux set-option -p -t "$host_pane" @vibe_role "host"
  vtmux set-option -p -t "$host_pane" @vibe_title "host"

  vtmux select-pane -t "$agent_pane"
fi

exec "$tmux_bin" -L "$socket" -f "$conf" attach-session -t "$session"
