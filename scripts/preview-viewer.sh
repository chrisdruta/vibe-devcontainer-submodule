#!/usr/bin/env bash
#
# Image review viewer: the pane process of a dedicated tmux window named
# "preview". Flip through images arriving in a watched directory (Gemini
# output, Blender render batches, `vibe clip` captures), record approve/reject
# verdicts to a JSONL file an agent or pipeline can consume, and jump to
# whatever a Claude Code hook just surfaced (preview-image-hook.sh feeds the
# queue file below).
#
# Why a dedicated window and not a split: on tmux 3.5a sixel is reliable ONLY
# while the image's own window is active — tmux repaints just the active
# window, so a busy agent TUI elsewhere can't clobber it. Client redraws
# replace images with placeholders and pane resizes drop them outright
# (tmux/tmux#4499, #4639, #5126; overwrite fix #4364 landed after 3.5a), so
# the viewer re-renders on window re-entry, on SIGWINCH, and on demand (`r`).
# Passthrough envelopes are a dead end — they paint at the client cursor and
# client scroll optimizations smear them into ghosts; hence the explicit
# `--passthrough none` guard on chafa.
#
# Modes:
#   (no args)          run the UI — must be a tmux pane's own process
#   --ensure SESSION   create the window detached if absent (hooks; silent)
#   --focus  SESSION   jump to the window, creating it if needed (prefix+i)
set -uo pipefail

WINDOW_NAME=preview
QUEUE=/tmp/.vibe-preview-queue
LOCK=/tmp/.vibe-preview-viewer.lock

# Canonicalize our own path (readlink loop, not GNU-only `readlink -f`) so
# --ensure/--focus relaunch the SAME copy: the baked /usr/local/bin/vibe-preview
# spawns the baked copy, a harness checkout spawns the harness copy.
self_path="${BASH_SOURCE[0]}"
while [ -L "$self_path" ]; do
  link_target="$(readlink "$self_path")"
  case "$link_target" in
    /*) self_path="$link_target" ;;
    *) self_path="$(dirname -- "$self_path")/$link_target" ;;
  esac
done
script_dir="$(cd -- "$(dirname -- "$self_path")" && pwd)"
self="$script_dir/$(basename -- "$self_path")"

case "${1:-}" in
  --ensure | --focus)
    session="${2:-}"
    [ -n "$session" ] || exit 0
    if [ "$1" = "--focus" ]; then
      tmux select-window -t "${session}:=${WINDOW_NAME}" 2>/dev/null && exit 0
      tmux new-window -t "$session" -n "$WINDOW_NAME" "exec bash '$self'" >/dev/null 2>&1
    else
      tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null |
        grep -qx "$WINDOW_NAME" && exit 0
      tmux new-window -d -t "$session" -n "$WINDOW_NAME" "exec bash '$self'" >/dev/null 2>&1
    fi
    exit 0
    ;;
  -h | --help)
    sed -n '2,25p' "$self" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

[ -n "${TMUX:-}" ] || {
  echo "Run inside the agent tmux session (prefix+i), or use \`vibe show\` outside tmux." >&2
  exit 1
}
command -v chafa >/dev/null 2>&1 || { echo "chafa not installed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not installed" >&2; exit 1; }

# Singleton: a second viewer (hook race, double prefix+i) fails this lock,
# exits, and its window self-closes without ever taking focus.
exec 9>"$LOCK"
flock -n 9 || exit 0

# Project config, best effort: harness layout puts config.env two levels up
# (.devcontainer/harness/scripts -> .devcontainer/config.env); the baked copy
# falls back to the session start directory (the workspace root under
# `vibe agent`). Defaults applied after so missing keys or files are fine.
for cfg in "$script_dir/../../config.env" "$PWD/.devcontainer/config.env"; do
  # shellcheck disable=SC1090  # runtime project config, path known only here
  if [ -f "$cfg" ]; then . "$cfg"; break; fi
done
watch_dir="${VIBE_PREVIEW_DIR:-/tmp}"
watch_glob="${VIBE_PREVIEW_GLOB:-*.png *.jpg *.jpeg *.webp}"
decisions="${VIBE_PREVIEW_DECISIONS:-${watch_dir%/}/vibe-decisions.jsonl}"

# Light the window name in the status bar when we print while unfocused.
tmux set-option -w -t "${TMUX_PANE:-}" monitor-activity on 2>/dev/null

name_args=()
for g in $watch_glob; do # deliberate word split: glob list is space-separated
  if [ "${#name_args[@]}" -gt 0 ]; then name_args+=(-o); fi
  name_args+=(-name "$g")
done

images=()
current=""
declare -A extras=() # hook-fed paths outside the watch dir, live while file exists
need_render=1
winch=""
last_active=""
last_sig=""
trap 'winch=1' WINCH
trap 'printf "\033[2J\033[H"' EXIT

scan() {
  local entries=() line path
  local -A seen=()
  for path in "${!extras[@]}"; do # prune vanished hook-fed files
    [ -f "$path" ] || unset 'extras[$path]'
  done
  # Newest first; NUL-safe so paths with spaces survive (the hook's prompt
  # grep can't match those, but queue/watch-dir arrivals can).
  mapfile -d '' -t entries < <(
    {
      find "$watch_dir" -maxdepth 1 -type f \( "${name_args[@]}" \) -printf '%T@\t%p\0' 2>/dev/null
      for path in "${!extras[@]}"; do
        printf '%s\t%s\0' "$(stat -c %Y -- "$path" 2>/dev/null || echo 0)" "$path"
      done
    } | sort -rzn
  )
  images=()
  for line in "${entries[@]}"; do
    path="${line#*$'\t'}"
    [ -n "${seen[$path]:-}" ] && continue
    seen[$path]=1
    images+=("$path")
  done
}

drain_queue() { # sets $jump to the newest valid queued path, if any
  jump=""
  [ -s "$QUEUE" ] || return 0
  local lines p
  # shellcheck disable=SC2094  # sequential read-then-truncate, serialized by the flock
  lines="$( { flock -x 8; cat -- "$QUEUE" 2>/dev/null; : >"$QUEUE"; } 8>>"$QUEUE" )"
  while IFS= read -r p; do
    if [ -z "$p" ] || [ ! -f "$p" ]; then continue; fi
    extras["$p"]=1
    jump="$p"
  done <<<"$lines"
}

idx_of_current() {
  local i
  for i in "${!images[@]}"; do
    [ "${images[$i]}" = "$current" ] && { printf '%s' "$i"; return; }
  done
  printf -- '-1'
}

verdict_of() {
  [ -f "$decisions" ] || { printf 'undecided'; return; }
  local v
  v="$(jq -r --arg p "$1" 'select(.path==$p).verdict' "$decisions" 2>/dev/null | tail -1)"
  printf '%s' "${v:-undecided}"
}

decide() {
  [ -n "$current" ] && [ -f "$current" ] || return 0
  mkdir -p -- "$(dirname -- "$decisions")" 2>/dev/null
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg path "$current" --arg verdict "$1" \
    '{ts: $ts, path: $path, verdict: $verdict}' >>"$decisions" 2>/dev/null
  move older # reviewing runs newest -> older through the batch
  need_render=1
}

move() { # older|newer|newest — selection is by path; index recomputed per scan
  [ "${#images[@]}" -gt 0 ] || return 0
  local idx
  idx="$(idx_of_current)"
  case "$1" in
    newest) idx=0 ;;
    newer) idx=$((idx > 0 ? idx - 1 : 0)) ;;
    older) idx=$((idx + 1 < ${#images[@]} ? idx + 1 : ${#images[@]} - 1)) ;;
  esac
  [ "$idx" -lt 0 ] && idx=0
  if [ "${images[$idx]}" != "$current" ]; then
    current="${images[$idx]}"
    need_render=1
  fi
}

render() {
  need_render=""
  local cols rows idx
  cols="$(tput cols 2>/dev/null || echo 80)"
  rows="$(tput lines 2>/dev/null || echo 24)"
  printf '\033[2J\033[H'
  if [ -z "$current" ]; then
    printf 'No images yet — watching %s (%s)\n' "$watch_dir" "$watch_glob"
    printf 'q quit  r rescan\n'
    return
  fi
  idx="$(idx_of_current)"
  printf '[%d/%d] %s  (%s)\n' "$((idx + 1))" "${#images[@]}" \
    "$(basename -- "$current")" "$(verdict_of "$current")"
  printf 'h/< newer  l/> older  g newest  y approve  n/x reject  r redraw  q quit\n'
  # Sixel only for clients tmux says can take it; everyone else gets cell art,
  # which tmux composites without any of the image bugs.
  if tmux display-message -p '#{client_termfeatures}' 2>/dev/null | grep -q sixel; then
    chafa -f sixel --passthrough none -s "${cols}x$((rows - 3))" -- "$current" 2>/dev/null ||
      printf '(render failed — press r to retry)\n'
  else
    chafa -f symbols -s "${cols}x$((rows - 3))" -- "$current" 2>/dev/null ||
      printf '(render failed — press r to retry)\n'
  fi
}

while :; do
  drain_queue
  scan
  if [ -n "$jump" ]; then
    current="$jump"
    need_render=1
  fi
  if [ -z "$current" ] || [ "$(idx_of_current)" -lt 0 ]; then # gone or never set
    current="${images[0]:-}"
    need_render=1
  fi
  sig="${#images[@]}:${images[0]:-}"
  active="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_active}' 2>/dev/null)"
  if [ "$active" = "1" ]; then
    # Re-entry and resizes both invalidate whatever sixel was on screen.
    [ "$last_active" != "1" ] && need_render=1
    [ -n "$winch" ] && winch="" && need_render=1
    [ -n "$need_render" ] && render
  elif [ "$sig" != "$last_sig" ] && [ -n "${images[0]:-}" ]; then
    # Unfocused: one short line trips monitor-activity; render waits for entry.
    printf 'new: %s (%d total)\n' "$(basename -- "${images[0]}")" "${#images[@]}"
  fi
  last_active="$active"
  last_sig="$sig"

  key=""
  IFS= read -rsn1 -t 2 key || continue
  if [ "$key" = $'\x1b' ]; then # arrow keys arrive as ESC [ C/D
    rest=""
    IFS= read -rsn2 -t 0.05 rest || rest=""
    key="ESC$rest"
  fi
  case "$key" in
    h | 'ESC[D') move newer ;;
    l | 'ESC[C') move older ;;
    g) move newest ;;
    y) decide approve ;;
    n | x) decide reject ;;
    r) need_render=1 ;;
    q) exit 0 ;;
  esac
done
