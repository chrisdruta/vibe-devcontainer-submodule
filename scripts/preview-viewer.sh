#!/usr/bin/env bash
#
# Image review viewer: the pane process of a dedicated tmux window named
# "preview". Flip through images arriving in a watched directory (Gemini
# output, Blender render batches, `vibe clip` captures), record approve/reject
# verdicts to a JSONL file an agent or pipeline can consume, and jump to
# whatever a Claude Code hook just surfaced (preview-image-hook.sh feeds the
# queue file below).
#
# Why a dedicated window and not a split: sixel under tmux 3.5a survives
# only in a calm window. Native ingestion (no passthrough) is a dead letter
# on this build — tmux stores the image but never re-emits it to the
# client, so even fresh renders appear as "+" placeholders (see also
# tmux/tmux#4499, #4639, #5126). Passthrough renders for real but paints at
# the client cursor, so any window shared with a busy agent TUI smears it
# into ghosts (cursor drag, scroll optimizations). A dedicated window the
# viewer fully owns removes every disturber: the cursor is ours, nothing
# scrolls, tmux repaints only the active window. The viewer still
# re-renders on window re-entry, on SIGWINCH, on demand (`r`), and heals
# the cached raster on idle ticks (entry/resize redraw storms can eat any
# pass, including the first).
#
# Pixels: vibe_render_sixel (preview-lib.sh) — img2sixel nearest-neighbor
# integer upscaling for small png/jpeg/gif/bmp (real format sniffed from
# magic bytes, never the extension), chafa smooth for everything else.
# Renderer errors surface in the UI and in the debug log; `d` shows the
# full diagnosis for the current image.
#
# Modes:
#   (no args)          run the UI — must be a tmux pane's own process
#   DIR                review DIR as a batch: watch it and record verdicts
#                      (default file: DIR/vibe-decisions.jsonl)
#   --ensure SESSION   create the window detached if absent (hooks; silent)
#   --focus  SESSION   jump to the window, creating it if needed (prefix+i)
#
# Viewing vs reviewing: verdict keys and the verdict label exist only when a
# decisions target is configured — a DIR argument or VIBE_PREVIEW_DECISIONS in
# config.env. Otherwise the viewer is passive (look, don't judge): the common
# case for clip/paste previews, where demanding a decision is just noise.
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
    # The whole leading comment block, however long it grows.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$self"
    exit 0
    ;;
esac

# Shared render/sniff/diagnostics helpers — same two homes as this script:
# a harness checkout (beside us) or the baked copy from the Dockerfile.
lib_ok=""
for _lib in "$script_dir/preview-lib.sh" /usr/local/lib/vibe/preview-lib.sh; do
  # shellcheck source=preview-lib.sh disable=SC1091
  if [ -f "$_lib" ]; then . "$_lib" && lib_ok=1; break; fi
done
if [ -z "$lib_ok" ]; then
  echo "preview-lib.sh not found (harness checkout incomplete, or old baked image — vibe rebuild)" >&2
  exit 1
fi

# Optional positional DIR: review that directory as a batch (per-stage dirs in
# a generation pipeline — `vibe review renders/asset42/angles`).
review_dir=""
if [ -n "${1:-}" ]; then
  if [ -d "$1" ]; then
    review_dir="$(cd -- "$1" && pwd)"
  else
    echo "not a directory: $1" >&2
    exit 2
  fi
fi

# Two homes: a tmux window (prefix+i — best effort, see header), or a plain
# host terminal via `vibe review` (devcontainer exec with a pty) — the
# RELIABLE one: chafa probes the real terminal and emits sixel with no tmux
# between the pixels and the screen.
in_tmux=""
[ -n "${TMUX:-}" ] && in_tmux=1
[ -t 0 ] || { echo "preview-viewer needs an interactive terminal" >&2; exit 1; }
command -v chafa >/dev/null 2>&1 || { echo "chafa not installed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not installed" >&2; exit 1; }

# Singleton for the TMUX window only: a second window instance (hook race,
# double prefix+i) fails this lock, exits, and its window self-closes
# without ever taking focus. A host-terminal `vibe review` is deliberately
# NOT gated — it owns its own terminal, and blocking it here would make it
# exit silently whenever the tmux window happens to be open. (If both run,
# both watch the dir; a hook-queued path jumps whichever drains it first.)
if [ -n "$in_tmux" ]; then
  exec 9>"$LOCK"
  flock -n 9 || exit 0
fi

# Project config, best effort: harness layout puts config.env two levels up
# (.devcontainer/harness/scripts -> .devcontainer/config.env); the baked copy
# falls back to the session start directory (the workspace root under
# `vibe agent`). Defaults applied after so missing keys or files are fine.
for cfg in "$script_dir/../../config.env" "$PWD/.devcontainer/config.env"; do
  # shellcheck disable=SC1090  # runtime project config, path known only here
  if [ -f "$cfg" ]; then . "$cfg"; break; fi
done
watch_dir="${review_dir:-${VIBE_PREVIEW_DIR:-/tmp}}"
watch_glob="${VIBE_PREVIEW_GLOB:-$(vibe_default_glob)}"

# Review mode only with an explicit decisions target: VIBE_PREVIEW_DECISIONS
# (config.env or environment) wins; a DIR argument implies its own batch file.
# Neither set -> passive viewer, no verdict UI.
review=""
decisions=""
if [ -n "${VIBE_PREVIEW_DECISIONS:-}" ]; then
  review=1
  decisions="$VIBE_PREVIEW_DECISIONS"
elif [ -n "$review_dir" ]; then
  review=1
  decisions="${review_dir%/}/vibe-decisions.jsonl"
fi

# Light the window name in the status bar when we print while unfocused.
[ -n "$in_tmux" ] && tmux set-option -w -t "${TMUX_PANE:-}" monitor-activity on 2>/dev/null

name_args=()
for g in $watch_glob; do # deliberate word split: glob list is space-separated
  if [ "${#name_args[@]}" -gt 0 ]; then name_args+=(-o); fi
  name_args+=(-iname "$g")
done

images=()
current=""
declare -A extras=() # hook-fed paths outside the watch dir, live while file exists
need_render=1
winch=""
last_active=""
last_sig=""
heal_left=0
last_dcs="" # cached bare sixel DCS + anchor of the last render, for emit_last
last_row=1
last_col=1
trap 'winch=1' WINCH
trap 'printf "\033[2J\033[H"; rm -f -- "$VIBE_RENDER_ERR"' EXIT

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
  [ -n "$review" ] || return 0
  [ -n "$current" ] && [ -f "$current" ] || return 0
  local note=""
  if [ "$1" = "reject" ]; then
    # A bare reject gives the regenerating agent nothing to steer with — offer
    # a one-line why. Prompt on the bottom row, clear of the image; the full
    # redraw after the verdict wipes it. Enter (or EOF) records a plain reject.
    printf '\033[999;1H\033[Kreject note (Enter = none): '
    IFS= read -r note || note=""
  fi
  mkdir -p -- "$(dirname -- "$decisions")" 2>/dev/null
  if [ -n "$note" ]; then
    jq -nc --arg ts "$(date -u +%FT%TZ)" --arg path "$current" --arg verdict "$1" \
      --arg note "$note" \
      '{ts: $ts, path: $path, verdict: $verdict, note: $note}' >>"$decisions" 2>/dev/null
  else
    jq -nc --arg ts "$(date -u +%FT%TZ)" --arg path "$current" --arg verdict "$1" \
      '{ts: $ts, path: $path, verdict: $verdict}' >>"$decisions" 2>/dev/null
  fi
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

emit_last() {
  # Flicker-free heal: re-emit only the cached sixel envelope, over itself.
  # A render can land mid client-redraw (window switch, resize settling) and
  # get wiped; the text survives in tmux's grid, so repainting just the
  # pixels repairs the image without a clear — invisible when the previous
  # pass survived. The main loop calls this on every idle tick (heal_left
  # only meters the staggered fallback for very large rasters).
  heal_left=$((${heal_left:-0} > 0 ? heal_left - 1 : 0))
  [ -n "$last_dcs" ] || return 0
  local esc
  esc="$(printf '\033')"
  printf '\033Ptmux;'
  printf '\0337\033[%d;%dH%s\0338' "$last_row" "$last_col" "$last_dcs" | sed "s/$esc/$esc$esc/g"
  # shellcheck disable=SC1003  # literal backslash: the ST terminator, not a quote escape
  printf '\033\\'
}

render() {
  need_render=""
  last_dcs=""
  if [ -z "$in_tmux" ]; then heal_left=0; else heal_left=1; fi
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
  if [ -n "$review" ]; then
    printf '[%d/%d] %s  (%s)\n' "$((idx + 1))" "${#images[@]}" \
      "$(basename -- "$current")" "$(verdict_of "$current")"
    printf 'h/< newer  l/> older  g newest  y approve  n/x reject(+note)  r redraw  d details  q quit\n\n'
  else
    printf '[%d/%d] %s\n' "$((idx + 1))" "${#images[@]}" "$(basename -- "$current")"
    printf 'h/< newer  l/> older  g newest  r redraw  d details  q quit\n\n'
  fi
  # Image box: side and bottom margins, centered via chafa (it composes the
  # padding into the canvas, so the anchored sixel below stays one block).
  local iw ih
  iw=$((cols - 4))
  ih=$((rows - 5))
  if [ "$iw" -lt 4 ]; then iw=4; fi
  if [ "$ih" -lt 3 ]; then ih=3; fi
  if [ -z "$in_tmux" ]; then
    # Plain terminal (`vibe review` from the host) — the zero-caveat home.
    # When the terminal answers the DA1 probe with sixel support, use the
    # shared renderer (crisp img2sixel nearest-neighbor for small
    # stb-format images, measured chafa otherwise), with the budget sized
    # by real cell metrics where the terminal reports them (XTWINOPS 16).
    # No sixel, or an unanswered probe: chafa probes the terminal itself
    # and picks sixel or unicode blocks — the original path, untouched.
    local raw pxw pxh cellw cellh hoff
    if term_has_sixel; then
      read -r cellw cellh <<<"$(term_cell_px)" || :
      if vibe_render_sixel "$current" "$iw" "$ih" $((iw * cellw)) $((ih * cellh)); then
        hoff=$(((iw - (pxw + cellw - 1) / cellw) / 2))
        [ "$hoff" -lt 0 ] && hoff=0
        printf '\033[%dG' $((hoff + 1))
        printf '%s\n' "$raw"
        dlog "OK $current fmt=$last_fmt renderer=$last_renderer scale=$last_scale out=${pxw}x${pxh}"
      else
        printf '(render failed via %s: %s%s — d details, r retry)\n' \
          "${last_renderer:-?}" "$last_err" "$(vibe_format_mismatch)"
        dlog "FAIL $current fmt=$last_fmt renderer=$last_renderer rc=$last_rc err=$last_err"
      fi
    else
      last_fmt="$(sniff_format "$current")"
      # shellcheck disable=SC2034  # read by the lib's vibe_diag_report
      last_ext="$(ext_format "$current")"
      last_renderer="chafa (self-probed)"
      last_scale=auto
      chafa --animate off --align mid,mid -s "${iw}x${ih}" -- "$current" 2>"$VIBE_RENDER_ERR"
      last_rc=$?
      if [ "$last_rc" -ne 0 ]; then
        last_err="$(head -n 1 -- "$VIBE_RENDER_ERR" 2>/dev/null)"
        printf '(render failed: %s%s — d details, r retry)\n' \
          "${last_err:-unknown}" "$(vibe_format_mismatch)"
        dlog "FAIL $current fmt=$last_fmt renderer=$last_renderer rc=$last_rc err=$last_err"
      fi
    fi
  elif tmux display-message -p '#{client_termfeatures}' 2>/dev/null | grep -q sixel; then
    # In tmux, a hand-anchored passthrough envelope — the only variant that
    # rendered deterministically on 3.5a. Native ingestion redraws as "+"
    # placeholders, and BARE passthrough races: tmux batches pane-text
    # drawing but forwards passthrough bytes immediately, so the image can
    # reach the client before the header text that positioned the cursor.
    # Self-positioning inside the envelope (save cursor, absolute jump,
    # draw, restore) is immune to both, and this window never scrolls, so
    # the shared-window ghost problem can't occur either.
    # Pixel production lives in vibe_render_sixel (preview-lib.sh): crisp
    # img2sixel nearest-neighbor for small stb-format images, measured
    # chafa otherwise. Sizing stays measured, not predicted — chafa's
    # cell→pixel mapping when its output is captured bears no relation to
    # the real terminal's cell size (observed: images rendered beyond the
    # whole screen), so the lib reads the true pixel size from the sixel
    # raster header ("Pan;Pad;Ph;Pv) and enforces a conservative pixel
    # budget for the box (10x20 px/cell — real cells are almost always
    # bigger, so output errs SMALL and fits; the client's true cell size
    # is unknowable through tmux).
    local raw img esc row col voff hoff pxw pxh cw ch
    if ! vibe_render_sixel "$current" "$iw" "$ih" $((iw * 10)) $((ih * 20)); then
      printf '(render failed via %s: %s%s — d details, r retry)\n' \
        "${last_renderer:-?}" "$last_err" "$(vibe_format_mismatch)"
      dlog "FAIL $current fmt=$last_fmt renderer=$last_renderer rc=$last_rc err=$last_err"
      return
    fi
    dlog "OK $current fmt=$last_fmt renderer=$last_renderer scale=$last_scale out=${pxw}x${pxh}"
    # Bare DCS only — any text decoration executed inside the envelope acts
    # at CLIENT level (spaces blank cells, a bottom-row linefeed scrolls the
    # whole screen).
    img="${raw#*$'\x1bP'}"
    img="${img%$'\x1b\\'*}"
    img=$'\x1bP'"$img"$'\x1b\\'
    # Center using the same conservative cell estimate the budget used.
    cw=$(((${pxw:-0} + 9) / 10))
    ch=$(((${pxh:-0} + 19) / 20))
    hoff=$(((iw - cw) / 2))
    voff=$(((ih - ch) / 2))
    if [ "$hoff" -lt 0 ]; then hoff=0; fi
    if [ "$voff" -lt 0 ]; then voff=0; fi
    row=$((4 + voff)) # under 2 header lines + 1 blank; window origin is client row 1
    if [ "$(tmux show -gv status-position 2>/dev/null)" = "top" ]; then row=$((row + 1)); fi
    col=$((3 + hoff))
    last_dcs="$img" # cache for the flicker-free heal pass
    last_row=$row
    last_col=$col
    # Very large rasters skip the continuous idle heal; meter out a few
    # staggered ones instead to bound client bandwidth (see the main loop).
    [ "${#last_dcs}" -gt 2097152 ] && heal_left=3
    esc="$(printf '\033')"
    printf '\033Ptmux;'
    printf '\0337\033[%d;%dH%s\0338' "$row" "$col" "$img" | sed "s/$esc/$esc$esc/g"
    # shellcheck disable=SC1003  # literal backslash: the ST terminator, not a quote escape
    printf '\033\\'
  else
    last_fmt="$(sniff_format "$current")"
    # shellcheck disable=SC2034  # read by the lib's vibe_diag_report
    last_ext="$(ext_format "$current")"
    last_renderer="chafa (symbols)"
    last_scale="cell art (no sixel in client_termfeatures)"
    # --animate off: chafa would otherwise PLAY an animated GIF here,
    # blocking the whole viewer loop for the animation's duration.
    chafa -f symbols --animate off --align mid,mid -s "${iw}x${ih}" -- "$current" 2>"$VIBE_RENDER_ERR"
    last_rc=$?
    if [ "$last_rc" -ne 0 ]; then
      last_err="$(head -n 1 -- "$VIBE_RENDER_ERR" 2>/dev/null)"
      printf '(render failed: %s%s — d details, r retry)\n' \
        "${last_err:-unknown}" "$(vibe_format_mismatch)"
      dlog "FAIL $current fmt=$last_fmt renderer=$last_renderer rc=$last_rc err=$last_err"
    fi
  fi
}

diag() {
  # `d`: why did the last render of this image do what it did — the
  # anti-silent-blank key. Any key returns and re-renders.
  [ -n "$current" ] || return 0
  if [ -z "$last_renderer" ]; then # no attempt yet (e.g. window never active)
    last_fmt="$(sniff_format "$current")"
    # shellcheck disable=SC2034  # read by the lib's vibe_diag_report
    last_ext="$(ext_format "$current")"
  fi
  printf '\033[2J\033[H'
  printf 'render diagnostics: last attempt on this image\n\n'
  vibe_diag_report "$current"
  if [ -n "$in_tmux" ]; then
    printf 'tmux:        client_termfeatures=[%s] status-position=%s\n' \
      "$(tmux display-message -p '#{client_termfeatures}' 2>/dev/null)" \
      "$(tmux show -gv status-position 2>/dev/null)"
    printf 'cached DCS:  %s bytes anchored at row %s col %s\n' \
      "${#last_dcs}" "$last_row" "$last_col"
  else
    printf 'terminal:    DA1 sixel=%s cell=%spx\n' \
      "$(term_has_sixel && echo yes || echo no)" "$(term_cell_px | tr ' ' 'x')"
  fi
  printf '\nany key to return\n'
  IFS= read -rsn1 -t 300 _ 2>/dev/null || :
  need_render=1
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
    # Re-entry and resizes both invalidate whatever sixel was on screen; a
    # changed image list refreshes the [n/total] header.
    [ "$last_active" != "1" ] && need_render=1
    [ "$sig" != "$last_sig" ] && need_render=1
    [ -n "$winch" ] && winch="" && need_render=1
    if [ -n "$need_render" ]; then
      render
    elif [ -n "$last_dcs" ]; then
      # Continuous idle heal: tmux 3.5a can drop a sixel on ANY client
      # redraw — window switch, resize settling, status-bar activity — and
      # a single post-render heal loses whenever the redraw lands later
      # (the observed symptom: header text, blank image, no error). Idle
      # ticks (no key for 2s) repaint the cached envelope over itself:
      # invisible when nothing was dropped, self-repairing within one tick
      # when something was. Very large rasters get heal_left staggered
      # passes instead of a continuous repaint.
      if [ "${#last_dcs}" -le 2097152 ] || [ "${heal_left:-0}" -gt 0 ]; then
        emit_last
      fi
    fi
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
    d) diag ;;
    r) need_render=1 ;;
    q) exit 0 ;;
  esac
done
