#!/usr/bin/env bash
#
# vibe tui project sidebar — the cross-project glance as a vertical pane
# on the far left (graduated from the 2026-07-22 spike; it REPLACES the
# old status-line-2 strip): every project session on the vibe socket with
# its state dots (the same @vibe_glyph / @vibe_dot_fg / @vibe_attn data
# state-render.sh maintains for the tabs), the workspace name in bold
# (bright = the session this sidebar lives in, dim = the others), and the
# checkout's git branch underneath.
#
# GLOBAL across the whole UI: @vibe_sidebar_on (conf defaults it to 1) is
# the one switch, and the conf's ensure hooks (after-new-window /
# after-select-window / client-session-changed) grow a sidebar into every
# window as it is created or visited. A tmux pane can only live in one
# window, so "one global sidebar" is really one-per-window kept in
# lockstep — same look everywhere, one toggle.
#
# Modes:
#   toggle WINDOW_ID   flip @vibe_sidebar_on: off kills every sidebar pane
#                      on the server; on stamps this window (the hooks
#                      cover the rest as they're visited)
#   ensure WINDOW_ID   idempotent: sidebar present in WINDOW iff flag on
#   render [--once]    the draw loop inside the pane (--once: one frame)
#
# Refresh is a 2s poll INSIDE each sidebar pane (the branch line has no
# tmux event to hook anyway); the status line stays event-driven. If the
# poll ever matters, move the dots to `tmux wait-for` nudges from
# state-render.sh and keep the poll only as the branch fallback.
#
# Host-side: bash-3.2-safe (stock macOS). Runs under the vibe server
# (run-shell provides TMUX for toggle/ensure; the pane's environment for
# render), so plain `tmux` is always the right binary/socket.
set -u

mode="${1:-render}"
tab="$(printf '\t')"

sidebar_panes() { # sidebar pane ids in window $1, oldest first
  tmux list-panes -t "$1" -F "#{pane_id}$tab#{@vibe_role}" 2>/dev/null |
    awk -F "$tab" '$2 == "sidebar" { print $1 }'
}

create_in() {
  win="$1"
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  # Full-height split BEFORE the leftmost pane; input off so stray clicks
  # can't type into the render loop; focus returns to where the user was.
  pane="$(tmux split-window -fhb -l 26 -t "$win" -P -F '#{pane_id}' \
    "exec bash '$self' render")"
  tmux set-option -p -t "$pane" @vibe_role "sidebar" \; \
    set-option -p -t "$pane" @vibe_title "projects" \; \
    select-pane -d -t "$pane" \; \
    select-pane -l
}

ensure_in() {
  win="$1"
  found=""
  for p in $(sidebar_panes "$win"); do
    if [ -z "$found" ]; then
      found="$p"
    else
      # the ensure hooks run async (-b) and can race a double-create on a
      # fast window-hop; heal to exactly one
      tmux kill-pane -t "$p" 2>/dev/null
    fi
  done
  [ -n "$found" ] || create_in "$win"
}

case "$mode" in
toggle)
  win="${2:-}"
  [ -n "$win" ] || exit 0
  if [ "$(tmux show-options -gqv @vibe_sidebar_on)" = "1" ]; then
    tmux set-option -g @vibe_sidebar_on 0
    for p in $(tmux list-panes -a -F "#{pane_id}$tab#{@vibe_role}" 2>/dev/null |
      awk -F "$tab" '$2 == "sidebar" { print $1 }'); do
      tmux kill-pane -t "$p" 2>/dev/null
    done
  else
    tmux set-option -g @vibe_sidebar_on 1
    ensure_in "$win"
  fi
  exit 0
  ;;
ensure)
  win="${2:-}"
  [ -n "$win" ] || exit 0
  [ "$(tmux show-options -gqv @vibe_sidebar_on)" = "1" ] || exit 0
  ensure_in "$win"
  exit 0
  ;;
render) ;;
*) exit 0 ;;
esac

# ── render ───────────────────────────────────────────────────────────────
once=0
[ "${2:-}" = "--once" ] && once=1

# One palette: read the theme off the server, conf defaults as fallback
# (same rule as state-render.sh). Read once at launch — a palette change
# lands on the next toggle, which is fine.
thm() { v="$(tmux show-options -gv "$1" 2>/dev/null)"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }
fg() { # hex -> truecolor foreground escape
  h="${1#\#}"
  printf '\033[38;2;%d;%d;%dm' "0x$(printf '%.2s' "$h")" "0x$(printf '%.2s' "${h#??}")" "0x$(printf '%.2s' "${h#????}")"
}
c_fg="$(fg "$(thm @thm_fg '#a9b6d8')")"
c_dim="$(fg "$(thm @thm_dim '#5c6b96')")"
c_coral="$(fg "$(thm @thm_coral '#e8735a')")"
bold="$(printf '\033[1m')"
reset="$(printf '\033[0m')"
eol="$(printf '\033[K')"

# .git/HEAD read directly — no git subprocess per tick. Handles the .git
# FILE indirection (worktrees, submodule checkouts); detached HEAD shows
# the short sha.
branch_of() {
  p="$1"
  g="$p/.git"
  if [ -f "$g" ]; then
    gd="$(sed -n 's/^gitdir: //p' "$g" 2>/dev/null)"
    case "$gd" in
      '') return 0 ;;
      /*) g="$gd" ;;
      *) g="$p/$gd" ;;
    esac
  fi
  [ -r "$g/HEAD" ] || return 0
  IFS= read -r line <"$g/HEAD" || [ -n "$line" ] || return 0
  case "$line" in
    "ref: refs/heads/"*) printf '%s' "${line#ref: refs/heads/}" ;;
    *) printf '%.7s' "$line" ;; # detached: the short sha is the label
  esac
}

frame() {
  width="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_width}' 2>/dev/null)"
  case "$width" in '' | *[!0-9]*) width=26 ;; esac
  here="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)" || here=""
  # Text budget: 2-col left gutter, keep 1 clear on the right.
  max=$((width - 3))
  [ "$max" -lt 8 ] && max=8

  buf="$(printf '\033[H')"
  buf="$buf
$eol"
  while IFS="$tab" read -r sid name path; do
    [ -n "$sid" ] || continue
    # Dots: window order, same semantics as the tabs — attention renders
    # coral (the tab-blend @vibe_dot_fg would vanish here), plain windows
    # (host shells, popups) emit nothing.
    dots=""
    while IFS="$tab" read -r glyph dfg attn; do
      [ -n "$glyph" ] || continue
      if [ "$attn" = "1" ]; then
        dots="$dots ${c_coral}●"
      else
        dots="$dots $(fg "${dfg:-#5c6b96}")$glyph"
      fi
    done <<EOF2
$(tmux list-windows -t "$sid" -F "#{@vibe_glyph}$tab#{@vibe_dot_fg}$tab#{@vibe_attn}" 2>/dev/null)
EOF2
    if [ "$name" = "$here" ]; then
      mark="${c_coral}▍" name_c="$c_fg"
    else
      mark=" " name_c="$c_dim"
    fi
    shown="$name"
    [ "${#shown}" -gt "$max" ] && shown="$(printf '%.*s' $((max - 1)) "$shown")…"
    buf="$buf
${mark}${reset} ${bold}${name_c}${shown}${reset}${dots}${reset}${eol}"
    br="$(branch_of "$path")"
    if [ -n "$br" ]; then
      [ "${#br}" -gt $((max - 2)) ] && br="$(printf '%.*s' $((max - 3)) "$br")…"
      buf="$buf
   ${c_dim}⎇ ${br}${reset}${eol}"
    fi
    buf="$buf
$eol"
  done <<EOF
$(tmux list-sessions -F "#{session_id}$tab#{session_name}$tab#{session_path}" 2>/dev/null | sort -t "$tab" -k2)
EOF
  printf '%s\033[J' "$buf"
}

printf '\033[?25l'
trap 'printf "\033[?25h"' EXIT
frame
[ "$once" = "1" ] && exit 0
while :; do
  sleep 2
  # Last real pane gone (shell exited, window would linger on just us):
  # let the window die with it. The main window's agent corpse still
  # counts as a pane (remain-on-exit), so it keeps its sidebar.
  n="$(tmux list-panes -t "${TMUX_PANE:-}" 2>/dev/null | wc -l)" || exit 0
  [ "$n" -le 1 ] && exit 0
  frame
done
