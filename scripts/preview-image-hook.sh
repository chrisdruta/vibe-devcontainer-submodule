#!/usr/bin/env bash
#
# Claude Code hook: auto-preview images beside the TUI. Wired (via
# templates/claude-settings.json) to two events:
#   UserPromptSubmit — an image path pasted into the prompt (e.g. from
#     `vibe clip`) pops a preview split the moment you submit;
#   PostToolUse (matcher: Read) — whenever the agent reads an image file,
#     you see what it sees.
# The TUI itself can't render images (upstream: not planned), so this is the
# closest thing to inline display: a transient, unfocused tmux split running
# show-image.sh that closes itself after VIBE_PREVIEW_SECONDS (default 15).
#
# Hook contract: JSON on stdin; stdout must stay EMPTY (UserPromptSubmit
# stdout is injected into the model's context). Always exit 0 — a preview
# failure must never block the agent.
set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

payload="$(cat)"
[ -n "${TMUX:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

event="$(jq -r '.hook_event_name // empty' <<<"$payload")"
case "$event" in
  UserPromptSubmit)
    # First absolute image path mentioned in the prompt (paths with spaces
    # won't match — fine for /tmp/clip-*.png and typical workspace paths).
    path="$(jq -r '.prompt // empty' <<<"$payload" |
      grep -oE '/[^[:space:]"'"'"']+\.(png|jpe?g|gif|webp|bmp)' | head -1)"
    ;;
  PostToolUse)
    path="$(jq -r '.tool_input.file_path // empty' <<<"$payload")"
    case "$path" in
      *.png | *.jpg | *.jpeg | *.gif | *.webp | *.bmp) : ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
[ -n "$path" ] && [ -f "$path" ] || exit 0

# Debounce: prompt-paste and the agent's subsequent Read of the same file
# would otherwise pop two previews back to back. Keyed per window so parallel
# agent sessions in other windows don't suppress each other's previews.
window="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)" || window=w0
last_file="/tmp/.vibe-preview-last-${window#@}"
now="$(date +%s)"
if [ -f "$last_file" ]; then
  read -r last_path last_time <"$last_file" || true
  if [ "$last_path" = "$path" ] && [ $((now - ${last_time:-0})) -lt 30 ]; then
    exit 0
  fi
fi
printf '%s %s\n' "$path" "$now" >"$last_file"

# One preview at a time: replace any pane a previous invocation left open.
tmux list-panes -F '#{pane_id} #{pane_title}' 2>/dev/null |
  awk '$2 == "vibe-preview" {print $1}' |
  while read -r pane; do tmux kill-pane -t "$pane" 2>/dev/null; done

# The split draws FOCUSED, then hands focus straight back to the invoking
# pane: sixel passthrough renders at the client cursor, so an unfocused (-d)
# pane draws the image at whatever position the active pane's redraw left the
# cursor — over the TUI, half the time nowhere visible. The focus flap lasts
# only as long as the render (~100ms); the pane then lingers unfocused and
# closes itself after VIBE_PREVIEW_SECONDS.
# The pane titles itself (OSC 2) rather than via `select-pane -T`, which can
# also change the active pane and would re-steal the focus just handed back.
tmux split-window -v -l '35%' \
  "printf '\\033]2;vibe-preview\\033\\\\'; bash '$script_dir/show-image.sh' '$path'; tmux select-pane -t '${TMUX_PANE:-}' 2>/dev/null; sleep ${VIBE_PREVIEW_SECONDS:-15}" 2>/dev/null || exit 0
exit 0
