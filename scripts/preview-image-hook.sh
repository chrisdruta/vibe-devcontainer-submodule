#!/usr/bin/env bash
#
# Claude Code hook: feed images into the review window. Wired (via
# templates/claude-settings.json) to two events:
#   UserPromptSubmit — an image path pasted into the prompt (e.g. from
#     `vibe clip`) queues into the viewer the moment you submit;
#   PostToolUse (matcher: Read) — whenever the agent reads an image file,
#     you can see what it sees.
# The TUI itself can't render images (upstream: not planned), and transient
# splits can't hold a sixel render on tmux 3.5a (client redraws replace
# images with placeholders — see preview-viewer.sh for the full constraint
# set). So: ensure the dedicated "preview" window exists (detached, never
# steals focus) and enqueue the path; the viewer renders it if its window is
# active, otherwise the window name lights up in the status bar.
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
    prompt="$(jq -r '.prompt // empty' <<<"$payload")"
    path="$(grep -oE '/[^[:space:]"'"'"']+\.(png|jpe?g|gif|webp|bmp)' <<<"$prompt" | head -1)"
    if [ -z "$path" ]; then
      case "$prompt" in
        *'[Image #'*)
          # Pasting the path of an EXISTING image makes the TUI attach the
          # file and replace the text with "[Image #N]" — the payload never
          # carries the path, and the agent won't Read a file it already
          # received, so neither hook event would fire. Best effort: preview
          # the newest recent `vibe clip` capture (workspace-mode clips and
          # images attached by other means won't match — acceptable).
          path="$(find /tmp -maxdepth 1 -name 'clip-*.png' -mmin -10 2>/dev/null | sort | tail -1)"
          ;;
      esac
    fi
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

# Duplicate events (prompt-paste then the agent's Read of the same file) need
# no debounce anymore: enqueueing the same path twice just re-selects it.
session="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_id}' 2>/dev/null)" || exit 0
[ -n "$session" ] || exit 0
bash "$script_dir/preview-viewer.sh" --ensure "$session" >/dev/null 2>&1 || exit 0

# Append under the same flock the viewer's drain-then-truncate takes, so a
# path can't vanish between its read and reset.
queue=/tmp/.vibe-preview-queue
( flock -x 8; printf '%s\n' "$path" >>"$queue" ) 8>>"$queue" 2>/dev/null
exit 0
