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
  # Newest clip by mtime; clip filenames sort by timestamp too, but mtime also
  # covers files copied in by other means.
  path="$(find /tmp -maxdepth 1 -name 'clip-*.png' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -z "$path" ]; then
    echo "No clipped images in /tmp — run \`vibe clip\` on the host first, or pass a path." >&2
    exit 1
  fi
fi
if [ ! -f "$path" ]; then
  echo "Not a readable image file: $path" >&2
  exit 1
fi

echo "$path"
if [ -n "${TMUX:-}" ]; then
  # Inside tmux force sixel in a passthrough envelope: tmux's own sixel image
  # engine ingests the image but fails to re-emit it to the client (seen with
  # Windows Terminal — raw sixel prints as text soup), while passthrough
  # (allow-passthrough on, set in config/tmux.conf) hands the bytes straight
  # to the outer terminal.
  # Build the envelope by hand rather than `chafa --passthrough tmux`: tmux
  # splices passthrough bytes into the client stream at whatever position the
  # client cursor holds at that instant, and any busy pane (an agent TUI
  # spinner) drags it away mid-splice — the image paints over the wrong pane
  # and the next repaint wipes it. Anchoring inside the envelope (save cursor,
  # jump to this pane's client coordinates, draw, restore) makes the render
  # position-independent.
  geom="$(tmux display-message -p -t "${TMUX_PANE:-}" \
    '#{pane_left} #{pane_top} #{cursor_y} #{pane_width} #{pane_height}' 2>/dev/null)" || geom=""
  if [ -n "$geom" ]; then
    read -r pl pt cy pw ph <<<"$geom"
    row=$((pt + cy + 1))
    if [ "$(tmux show -gv status-position 2>/dev/null)" = "top" ]; then
      row=$((row + 1))
    fi
    h=$((ph - cy))
    if [ "$h" -lt 1 ]; then h=$ph; fi
    img="$(chafa -f sixel -s "${pw}x${h}" "$path")"
    esc="$(printf '\033')"
    printf '\033Ptmux;'
    printf '\0337\033[%d;%dH%s\0338' "$row" "$((pl + 1))" "$img" | sed "s/$esc/$esc$esc/g"
    # shellcheck disable=SC1003  # literal backslash: the ST terminator, not a quote escape
    printf '\033\\'
    exit 0
  fi
  # No geometry (detached client edge cases): chafa's own envelope still works
  # whenever the client cursor sits in this pane.
  exec chafa -f sixel --passthrough tmux "$path"
fi
if [ -t 1 ]; then
  exec chafa "$path"
fi
# Not a tty (e.g. `devcontainer exec` without a pty): chafa can't probe the
# terminal, so force sixel at a fixed size for the host terminal to render.
exec chafa -f sixel -s 100x "$path"
