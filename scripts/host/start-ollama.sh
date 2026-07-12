#!/usr/bin/env bash
#
# Start Ollama on the WINDOWS HOST, from WSL, tuned for parallel inference.
#
# Stops any running Ollama instance - including the system-tray app, which
# would otherwise respawn the server with default settings - then launches
# `ollama serve` in the foreground with:
#
#   OLLAMA_MAX_LOADED_MODELS = --max-loaded      (default 1)
#   OLLAMA_CONTEXT_LENGTH    = --context-length  (default 4096)
#   OLLAMA_NUM_PARALLEL      = --parallel        (default 24)
#   OLLAMA_FLASH_ATTENTION   = 1
#   OLLAMA_KV_CACHE_TYPE     = --kv-cache-type   (default q8_0, halves KV-cache VRAM)
#
# KV cache is allocated as context_length x parallel up front. On a 16 GB card
# most of the VRAM is weights - raise --parallel only as far as `ollama ps`
# still shows 100% GPU; spilling weights to CPU costs far more than
# parallelism gains.
#
# The variables are forwarded to the Windows process via WSLENV for this
# launch only; nothing is written to the system environment. Ctrl+C stops the
# server - relaunch the Ollama desktop app afterwards if you want the tray
# icon / default behavior back.
#
# Dev containers reach the server at http://host.docker.internal:11434 when
# the project's runArgs include --add-host=host.docker.internal:host-gateway.
set -euo pipefail

parallel=24
kv_cache_type=q8_0
context_length=4096
max_loaded=1

usage() {
  cat <<'USAGE'
Usage: start-ollama.sh [--parallel N] [--kv-cache-type TYPE]
                       [--context-length N] [--max-loaded N]
USAGE
}

while (($#)); do
  case "$1" in
    --parallel)       parallel="$2"; shift 2 ;;
    --kv-cache-type)  kv_cache_type="$2"; shift 2 ;;
    --context-length) context_length="$2"; shift 2 ;;
    --max-loaded)     max_loaded="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v ollama.exe >/dev/null 2>&1; then
  echo "ollama.exe not found on PATH." >&2
  echo "Install it from https://ollama.com/download/windows and make sure WSL" >&2
  echo "Windows-PATH interop is enabled (appendWindowsPath in /etc/wsl.conf)." >&2
  exit 1
fi

# The tray app ("ollama app") supervises the server: stop it first, or it
# immediately respawns ollama.exe with default settings.
for name in "ollama app.exe" "ollama.exe"; do
  taskkill.exe /F /IM "$name" >/dev/null 2>&1 || true
done

port_in_use() {
  netstat.exe -ano 2>/dev/null | grep -E ':11434[[:space:]]' | grep -q LISTENING
}

# Wait (up to ~5s) for the previous server to release port 11434.
for _ in $(seq 1 20); do
  port_in_use || break
  sleep 0.25
done
if port_in_use; then
  echo "Port 11434 is still in use - is another Ollama instance running?" >&2
  exit 1
fi

export OLLAMA_MAX_LOADED_MODELS="$max_loaded"
export OLLAMA_CONTEXT_LENGTH="$context_length"
export OLLAMA_NUM_PARALLEL="$parallel"
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE="$kv_cache_type"

# WSLENV /w flags forward these WSL variables into the Windows process.
export WSLENV="${WSLENV:+$WSLENV:}OLLAMA_MAX_LOADED_MODELS/w:OLLAMA_CONTEXT_LENGTH/w:OLLAMA_NUM_PARALLEL/w:OLLAMA_FLASH_ATTENTION/w:OLLAMA_KV_CACHE_TYPE/w"

cat <<EOF

Starting ollama serve (Windows host) with:
  OLLAMA_MAX_LOADED_MODELS = $OLLAMA_MAX_LOADED_MODELS
  OLLAMA_CONTEXT_LENGTH    = $OLLAMA_CONTEXT_LENGTH
  OLLAMA_NUM_PARALLEL      = $OLLAMA_NUM_PARALLEL
  OLLAMA_FLASH_ATTENTION   = $OLLAMA_FLASH_ATTENTION
  OLLAMA_KV_CACHE_TYPE     = $OLLAMA_KV_CACHE_TYPE

Containers reach it at http://host.docker.internal:11434 (requires the
--add-host=host.docker.internal:host-gateway runArg in that project).

After the first batch, run 'ollama.exe ps' - the model must show 100% GPU;
if it doesn't, restart with a lower --parallel.
Ctrl+C stops the server.

EOF

exec ollama.exe serve
