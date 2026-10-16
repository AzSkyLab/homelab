#!/usr/bin/env bash
# Starts, stops or reports on the local AI 3D service (ComfyUI on 127.0.0.1:8188, this machine only).
#   ai3d.sh start | stop | status | log
# Starts offline (HF_HUB_OFFLINE=1) so nothing downloads new weights or remote code at run time; setup.sh pins them.
set -euo pipefail
AI3D_HOME="${AI3D_HOME:-$HOME/ai-3d}"
PORT="${AI3D_PORT:-8188}"
LOG="$AI3D_HOME/comfyui.log"
# VRAM mode: "high" keeps the models on the GPU between jobs (--highvram), so they don't sit in system RAM (TRELLIS.2's
# weights were ~17 GB of RAM in ComfyUI's default mode) and jobs start faster; "normal" is ComfyUI's default, which moves
# them back to RAM after each job and leaves the VRAM free for Ollama (the LiteLLM backend on this card).
VRAM="${AI3D_VRAM:-high}"
case "$VRAM" in
  high) VRAM_FLAG=(--highvram) ;;
  normal) VRAM_FLAG=() ;;
  *) echo "AI3D_VRAM must be high or normal" >&2; exit 2 ;;
esac
URL="http://127.0.0.1:$PORT"

running() { curl -sf -o /dev/null "$URL/system_stats"; }

vram_warning() {
  # TRELLIS.2 needs about 24 GB; Ollama's big models leave too little on a 32 GB card.
  if command -v ollama >/dev/null && [ -n "$(ollama ps 2>/dev/null | tail -n +2)" ]; then
    echo "warning: Ollama has models loaded (ollama ps). Unload them for TRELLIS.2: ollama stop <model>"
  fi
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/GPU memory: /'
}

case "${1:-status}" in
  start)
    if running; then echo "already running at $URL"; exit 0; fi
    vram_warning
    cd "$AI3D_HOME/ComfyUI"
    echo "VRAM mode: $VRAM (AI3D_VRAM=normal frees the GPU between jobs for Ollama)"
    HF_HUB_OFFLINE=1 nohup "$AI3D_HOME/venv/bin/python" main.py --listen 127.0.0.1 --port "$PORT" "${VRAM_FLAG[@]}" >"$LOG" 2>&1 &
    for _ in $(seq 1 60); do running && { echo "running at $URL"; exit 0; }; sleep 2; done
    echo "did not start; see $LOG" >&2; exit 1 ;;
  stop)
    pkill -f "python main.py --listen 127.0.0.1 --port $PORT" && echo stopped || echo "not running" ;;
  status)
    if running; then echo "running at $URL"; else echo "stopped"; fi
    vram_warning ;;
  log)
    tail -n 50 "$LOG" ;;
  *)
    echo "usage: $0 start|stop|status|log" >&2; exit 2 ;;
esac
