#!/usr/bin/env bash
#
# vibe tui host renderer for the agent-state title channel (BACKLOG "agent
# state at a glance"). Invoked by the vibe server's pane-title-changed hook
# as: state-render.sh PANE_ID — and ONLY the server-controlled pane id is
# ever interpolated into that hook command. The pane title is
# container-controlled text, so it is fetched out-of-band here and never
# becomes host shell words (the injection rule the title-channel spike
# baked into the design; see BACKLOG).
#
# Input title encoding (written by the container-side agent-state-hook.sh):
#   vibe1|<project>|<session>|<instance>|<state>
# Output: data-only tmux user options; presentation lives in tmux-tui.conf.
#   pane   @vibe_state  raw state, @vibe_title (only if unset — keeps the
#                       raw encoding out of the pane border)
#   pane+window @vibe_glyph / @vibe_dot_fg  the pre-chosen dot + its color
#   window @vibe_attn   1 while the agent wants a human (tab flash)
#
# Host-side: must stay bash-3.2-safe (stock macOS). Runs under the vibe
# server via run-shell, which provides TMUX pointing at that server.
set -u

pane="${1:-}"
[ -n "$pane" ] || exit 0

# Liveness dominates semantic state (the layered-liveness rule): hook
# run-shell is async, so a queued title event can execute AFTER the pane
# died — never let it overwrite the pane-died hook's frontend-dead mark.
dead="$(tmux display-message -p -t "$pane" '#{pane_dead}' 2>/dev/null)" || exit 0
[ "$dead" = "1" ] && exit 0

title="$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null)" || exit 0
case "$title" in
  "vibe1|"*) ;;
  *) exit 0 ;; # not an agent-state title — nothing to render
esac

IFS='|' read -r _ _proj session _instance state <<EOF
$title
EOF

# One palette: read the theme options off the server, with the conf's
# defaults as fallback so a bare server still renders something sane.
thm() { v="$(tmux show-options -gv "$1" 2>/dev/null)"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

attn=0
case "$state" in
  working) glyph="●" dot_fg="$(thm @thm_green '#9ece6a')" ;;
  attention)
    # The whole tab flashes coral (conf); the dot blends into that bg.
    glyph="●" dot_fg="$(thm @thm_bg '#0e1421')" attn=1
    ;;
  idle) glyph="●" dot_fg="$(thm @thm_dim '#5c6b96')" ;;
  exited) glyph="✗" dot_fg="$(thm @thm_red '#f7768e')" ;;
  *) exit 0 ;; # unknown state from a newer/older pin — render nothing
esac

tmux set-option -p -t "$pane" @vibe_state "$state" \; \
  set-option -p -t "$pane" @vibe_glyph "$glyph" \; \
  set-option -p -t "$pane" @vibe_dot_fg "$dot_fg" \; \
  set-option -w -t "$pane" @vibe_glyph "$glyph" \; \
  set-option -w -t "$pane" @vibe_dot_fg "$dot_fg" \; \
  set-option -w -t "$pane" @vibe_attn "$attn" 2>/dev/null || exit 0

# Human label for the pane border: the border format prefers @vibe_title,
# so stamping the session name here keeps the raw vibe1|… encoding from
# ever showing. Never overwrite a label tui.sh/the palette already chose.
cur_title="$(tmux show-options -pqv -t "$pane" @vibe_title 2>/dev/null)"
[ -n "$cur_title" ] || tmux set-option -p -t "$pane" @vibe_title "$session" 2>/dev/null

exit 0
