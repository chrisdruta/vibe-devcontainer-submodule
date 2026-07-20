#!/usr/bin/env bash
set -euo pipefail

# Repository-specific start-time setup belongs here. Keep it idempotent.
#
# Long-running dev services that need the workspace/toolchain: one window
# each in the shared services tmux session — idempotent by window name,
# `vibe attach` is the door in, logs are the scrollback (docs/services.md):
#   vibe-svc web  bun run dev
#   vibe-svc rojo rojo serve
# Databases and independent daemons belong in .vibe/compose.yaml as
# sidecars instead (vibe up/status/down manage them).
