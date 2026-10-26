#!/usr/bin/env bash
# model-tests.sh — The Phase 9b checks that need the language model, and the talk bridge for the local test server
# Reads the swgemu LiteLLM key from pass, runs the plan question set (alone and with crowd chat in flight) and the crew's
# order and lesson questions against the model, then starts the talk bridge on this host against the local server's
# /run/talk (docker-compose.yml), with the doctrines in the same data directory. Results and the bridge log go to
# ~/.cache/swgemu-scratch/model-tests/. Safe to rerun: a bridge already running is stopped first.
#
# Usage: bash dev/model-tests.sh          (in a terminal: pass asks for the GPG passphrase)
#        bash dev/model-tests.sh stop     (stop the bridge)

set -euo pipefail

cd "$(dirname "$0")"

DATA=${CORE3_DEV_DATA:-$HOME/.cache/swgemu-scratch/data}
OUT=$HOME/.cache/swgemu-scratch/model-tests
PIDFILE=$OUT/bridge.pid
mkdir -p "$OUT"

stop_bridge() {
    if [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")"
        echo "Stopped the bridge ($(cat "$PIDFILE"))."
    fi
    rm -f "$PIDFILE"
}

if [[ ${1:-} == stop ]]; then
    stop_bridge
    exit 0
fi

echo "Reading the key from pass..."
export LITELLM_KEY
LITELLM_KEY=$(pass show homelab/swgemu/litellm-key | head -1)
export LITELLM_URL=https://llm.home.lab/v1
export TALK_MODEL=vm/qwen3.6-abliterated:27b

echo "=== Plans, alone ($OUT/plans.txt) ==="
python3 plan_questions.py >"$OUT/plans.txt" 2>&1 || echo "  (some plans were invalid: see the file)"
tail -4 "$OUT/plans.txt"
echo "=== Plans, with crowd chat in flight ($OUT/plans-chat.txt) ==="
python3 plan_questions.py --with-chat 2 >"$OUT/plans-chat.txt" 2>&1 || echo "  (some plans were invalid: see the file)"
tail -4 "$OUT/plans-chat.txt"
echo "=== The crew's questions, orders and lessons included ($OUT/crew-questions.md) ==="
python3 bot_questions.py --jobs tank,rifleman,medic,ranger,squadleader,entertainer,commando >"$OUT/crew-questions.md" 2>&1 \
    || echo "  (below the bar: see the file)"
tail -6 "$OUT/crew-questions.md"

echo "=== The bridge for the local server ($OUT/bridge.log) ==="
stop_bridge
mkdir -p "$DATA/talk" "$DATA/doctrine"
TALK_DIR=$DATA/talk TALK_DOCTRINE_DIR=$DATA/doctrine PYTHONUNBUFFERED=1 \
    nohup python3 ../talk/talk_bridge.py >"$OUT/bridge.log" 2>&1 &
echo $! >"$PIDFILE"
sleep 3
head -5 "$OUT/bridge.log"
echo "Bridge running (pid $(cat "$PIDFILE")). Stop it with: bash dev/model-tests.sh stop"
