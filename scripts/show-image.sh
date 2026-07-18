#!/usr/bin/env bash
#
# Preview an image in the terminal with chafa (sixel where the terminal
# supports it, unicode blocks otherwise). The companion to `vibe clip`: with no
# argument it shows the newest /tmp/clip-*.png so you can eyeball what an agent
# is about to see — the Claude Code TUI itself can't render images inline.
#
# Runs container-side, either directly in a pane or via `vibe show` from the
# host (devcontainer exec).
set -euo pipefail

path="${1:-}"
if [ -z "$path" ]; then
  # Newest image by mtime across /tmp clips AND the review-viewer watch dir
  # (VIBE_PREVIEW_DIR/GLOB, resolved the same way preview-viewer.sh does).
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  for cfg in "$script_dir/../../config.env" "$PWD/.devcontainer/config.env"; do
    # shellcheck disable=SC1090  # runtime project config, path known only here
    if [ -f "$cfg" ]; then . "$cfg"; break; fi
  done
  watch_dir="${VIBE_PREVIEW_DIR:-/tmp}"
  name_args=()
  for g in ${VIBE_PREVIEW_GLOB:-*.png *.jpg *.jpeg *.webp}; do # deliberate split
    if [ "${#name_args[@]}" -gt 0 ]; then name_args+=(-o); fi
    name_args+=(-name "$g")
  done
  path="$({
    find /tmp -maxdepth 1 -name 'clip-*.png' -printf '%T@ %p\n' 2>/dev/null
    find "$watch_dir" -maxdepth 1 -type f \( "${name_args[@]}" \) -printf '%T@ %p\n' 2>/dev/null
  } | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -z "$path" ]; then
    echo "No images in /tmp or $watch_dir — run \`vibe clip\` on the host first, or pass a path." >&2
    exit 1
  fi
fi
if [ ! -f "$path" ]; then
  echo "Not a readable image file: $path" >&2
  exit 1
fi

echo "$path"
if [ -n "${TMUX:-}" ]; then
  # Inside tmux, sixel in a passthrough envelope (explicit — chafa's "auto"
  # default already means this, but leave no room for drift): this tmux
  # build ingests raw sixel yet never re-emits it to the client, so native
  # compositing shows only "+" placeholders. Passthrough paints at the
  # client cursor — correct when this pane is focused in a calm window
  # (manual use, the review viewer's window), garbage next to a busy agent
  # TUI, which is why hooks feed preview-viewer.sh instead of rendering
  # into shared windows.
  exec chafa -f sixel --passthrough tmux "$path"
fi
if [ -t 1 ]; then
  exec chafa "$path"
fi
# Not a tty (e.g. `devcontainer exec` without a pty): chafa can't probe the
# terminal, so force sixel at a fixed size for the host terminal to render.
exec chafa -f sixel -s 100x "$path"
