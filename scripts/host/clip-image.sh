#!/usr/bin/env bash
#
# Save the HOST clipboard image into the dev container's /tmp so agents can read
# it — the workaround for image paste not working in the container.
#
# Why paste doesn't work: Claude Code's Ctrl-V image paste reads the OS clipboard
# from the process side (on plain WSL it shells out to powershell.exe via interop).
# Inside the container there is no WSL interop and no display server, so the OS
# clipboard is unreachable — no terminal or tmux setting can fix that (the
# terminal only ever sends TEXT down the pty).
#
# Invoked by `vibe clip [DIR]` on the host (WSL or macOS). By default the PNG is
# streamed into the running container's /tmp over `devcontainer exec` (nothing
# lands in the repo, gone on rebuild). With DIR — a workspace-relative directory
# — it is written straight into the bind-mounted repo instead (persists; no
# running container needed; gitignore the directory if it stays). Either way the
# container path is printed and — QoL — replaces the image on the host clipboard
# so the next paste in an agent prompt is the path itself.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: clip-image.sh REPO_ROOT DEST_DIR_OR_EMPTY DEVCONTAINER_CLI [CLI_ARG ...]" >&2
  echo "(normally invoked via: .devcontainer/vibe clip [DIR])" >&2
  exit 2
fi
repo_root="$1"
dest_dir="$2"
shift 2
cli=("$@")

case "$dest_dir" in
  /*)
    echo "Destination must be a relative path inside the workspace: $dest_dir" >&2
    exit 2
    ;;
  ..|../*|*/..|*/../*)
    echo "Destination must not escape the workspace: $dest_dir" >&2
    exit 2
    ;;
esac
dest_dir="${dest_dir%/}"

file_name="clip-$(date +%Y%m%d-%H%M%S).png"
if [ -n "$dest_dir" ]; then
  # Workspace mode: the repo is bind-mounted, so writing on the host is enough.
  mkdir -p "$repo_root/$dest_dir"
  host_png="$repo_root/$dest_dir/$file_name"
  container_path="/workspaces/$(basename "$repo_root")/$dest_dir/$file_name"
else
  container_path="/tmp/$file_name"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  host_png="$tmp_dir/clip.png"
fi

if command -v powershell.exe >/dev/null 2>&1; then
  # WSL: PowerShell needs a WINDOWS path; wslpath maps the WSL-side temp file.
  win_path="$(wslpath -w "$host_png")"
  result="$(powershell.exe -NoProfile -Command "
    Add-Type -AssemblyName System.Windows.Forms
    \$img = [System.Windows.Forms.Clipboard]::GetImage()
    if (\$img -eq \$null) { Write-Output 'NOIMAGE' } else { \$img.Save('$win_path', [System.Drawing.Imaging.ImageFormat]::Png); Write-Output 'SAVED' }
  " | tr -d '\r')"
  if [ "$result" != "SAVED" ]; then
    echo "No image on the Windows clipboard." >&2
    exit 1
  fi
elif command -v osascript >/dev/null 2>&1; then
  # macOS: stock AppleScript; errors out before opening the file when the
  # clipboard has no PNG-convertible image.
  if ! osascript >/dev/null 2>&1 \
    -e 'set png to the clipboard as «class PNGf»' \
    -e "set f to open for access POSIX file \"$host_png\" with write permission" \
    -e 'write png to f' \
    -e 'close access f'; then
    echo "No image on the macOS clipboard." >&2
    exit 1
  fi
else
  echo "Neither powershell.exe (WSL) nor osascript (macOS) is available —" >&2
  echo "run this on the host, not inside the container." >&2
  exit 1
fi

if [ -z "$dest_dir" ]; then
  # Stream into the container as base64 so the CLI's stdin handling can't mangle
  # binary bytes. /tmp is container-local: survives detach, gone on rebuild.
  base64 <"$host_png" | "${cli[@]}" exec --workspace-folder "$repo_root" \
    bash -c "base64 -d >'$container_path'"
else
  echo "Saved: $dest_dir/$file_name"
fi

echo "In the container: $container_path"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s' "$container_path" | clip.exe && echo "(path copied to clipboard)"
elif command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$container_path" | pbcopy && echo "(path copied to clipboard)"
fi
