#!/usr/bin/env bash
#
# Build/install the pinned tmux on the HOST for `vibe tui`. Same version,
# checksum, and --enable-sixel configuration as the container build in
# src/Dockerfile (keep the pins in sync with it): Debian/Ubuntu package
# tmux 3.5a, which drops sixel images whenever a pane redraws; 3.7b holds
# them (dogfood spike + in-image validation, 2026-07-21).
#
# Usage: install-tmux.sh [--prefix DIR]     (default: ~/.local)

set -euo pipefail

TMUX_VERSION=3.7b
TMUX_SHA256=87f2e99e3b685973f2ca002ffd6ed7e51a5744f7009daae5a15670b6d532db96

prefix="$HOME/.local"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 2; }
      prefix="$2"
      shift 2
      ;;
    -h | --help)
      echo "Usage: install-tmux.sh [--prefix DIR]   (default: ~/.local)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

missing=""
for tool in cc make curl pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if ! pkg-config --exists libevent 2>/dev/null; then
  missing="$missing libevent-dev"
fi
if ! pkg-config --exists ncurses 2>/dev/null && ! pkg-config --exists ncursesw 2>/dev/null; then
  missing="$missing libncurses-dev"
fi
if [ -n "$missing" ]; then
  echo "Missing build tools/libraries:$missing" >&2
  echo "On Debian/Ubuntu (incl. WSL):" >&2
  echo "  sudo apt-get update && sudo apt-get install -y build-essential curl pkg-config libevent-dev libncurses-dev byacc" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

echo "Downloading tmux $TMUX_VERSION..."
curl -fsSL -o tmux.tar.gz \
  "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
echo "${TMUX_SHA256}  tmux.tar.gz" | sha256sum -c -
tar xzf tmux.tar.gz
cd "tmux-${TMUX_VERSION}"

echo "Building (--enable-sixel, prefix: $prefix)..."
./configure --prefix="$prefix" --enable-sixel
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
make install

installed="$prefix/bin/tmux"
echo
echo "Installed: $installed ($("$installed" -V))"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *)
    echo "NOTE: $prefix/bin is not on your PATH — add it, or point vibe tui at it:" >&2
    echo "  export VIBE_TUI_TMUX=$installed" >&2
    ;;
esac
