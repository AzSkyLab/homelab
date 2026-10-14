#!/usr/bin/env bash
# Starts, stops or reports on the local AI 3D service (ComfyUI on 127.0.0.1:8188, this machine only).
#   ai3d.sh start | stop | status | log
# Starts offline (HF_HUB_OFFLINE=1) so nothing downloads new weights or remote code at run time; setup.sh pins them.
set -euo pipefail
AI3D_HOME="${AI3D_HOME:-$HOME/ai-3d}"
PORT="${AI3D_PORT:-8188}"
LOG="$AI3D_HOME/comfyui.log"
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
    HF_HUB_OFFLINE=1 nohup "$AI3D_HOME/venv/bin/python" main.py --listen 127.0.0.1 --port "$PORT" >"$LOG" 2>&1 &
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
