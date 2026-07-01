#!/usr/bin/env bash
# Usage: ./scripts/run-sweep-server.sh [size] [-- llama-server args...]
#   size  Sweep model size: 0.5b, 1.5b (default), or 7b
#
# Options:
#   -p <port>   Port to listen on (default: 8000)
#   -c <ctx>    Context size in tokens (default: 8192)
#   -g <ngl>    GPU layers to offload (default: 99 = all; ignored on CPU builds)
#
# Examples:
#   ./scripts/run-sweep-server.sh                # 1.5b on :8000
#   ./scripts/run-sweep-server.sh 0.5b -p 8001
#   ./scripts/run-sweep-server.sh 7b -- --threads 8
#
# Runs llama.cpp's llama-server tuned for cursortab's request pattern:
# consecutive completion requests share almost their entire prompt (file
# context, diff history), so --cache-reuse lets the server reuse the KV cache
# for the unchanged prefix instead of re-processing the prompt on every
# keystroke. Point the plugin at it with:
#
#   provider = { type = "sweep", url = "http://localhost:8000" }

set -euo pipefail

SIZE="1.5b"
PORT=8000
CTX=8192
NGL=99

if [[ $# -gt 0 && $1 != -* ]]; then
  SIZE="${1,,}"
  shift
fi

while getopts "p:c:g:h" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    c) CTX="$OPTARG" ;;
    g) NGL="$OPTARG" ;;
    h)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))
[[ "${1:-}" == "--" ]] && shift

case "$SIZE" in
  0.5b | 1.5b | 7b) MODEL="sweepai/sweep-next-edit-$SIZE" ;;
  *)
    echo "error: unknown model size '$SIZE' (expected 0.5b, 1.5b, or 7b)" >&2
    exit 1
    ;;
esac

if ! command -v llama-server >/dev/null 2>&1; then
  echo "error: llama-server not found in PATH" >&2
  echo "install llama.cpp: https://github.com/ggml-org/llama.cpp" >&2
  exit 1
fi

# --cache-reuse 256: reuse KV cache for matching prompt prefixes (>=256 token
#   chunks). Cursortab resends nearly identical prompts as you type, so this
#   turns most prompt processing into a cache hit.
# -ngl: offload all layers to the GPU when one is available.
exec llama-server \
  -hf "$MODEL" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --ctx-size "$CTX" \
  -ngl "$NGL" \
  --cache-reuse 256 \
  "$@"
