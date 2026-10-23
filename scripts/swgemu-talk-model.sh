#!/usr/bin/env bash
# swgemu-talk-model.sh — Switch the model the SWGEmu crowd and bot players talk with
# Lets the talk bridge's LiteLLM key (swgemu-talk) use the model, checks the model answers through it, sets TALK_MODEL
# on the talk container in core3.yml, commits and pushes main. ArgoCD then restarts the core3 pod (~80 s save, ~1 min
# boot), since an env change recreates the pod. Safe to rerun.
#
# Usage: bash scripts/swgemu-talk-model.sh vm/qwen3.6-abliterated:27b   (in a terminal: pass asks for the GPG passphrase)

set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

MODEL=${1:?usage: $0 <litellm model name, e.g. vm/qwen3.6-abliterated:27b>}
LITELLM="https://llm.home.lab"
MANIFEST="kubernetes/manifests/swgemu/core3.yml"
STATUS_HOST="10.0.20.84"

confirm() { read -r -p "$1 [y/N] " reply; [[ $reply == [yY]* ]]; }

echo "=== SWGEmu talk model: $MODEL ==="

branch=$(git branch --show-current)
[[ $branch == main ]] || { echo "On branch $branch; deploys go from main." >&2; exit 1; }
git diff --quiet HEAD -- "$MANIFEST" || { echo "$MANIFEST has uncommitted changes; commit them first." >&2; exit 1; }

current=$(grep -A1 'name: TALK_MODEL' "$MANIFEST" | grep -oP 'value: \K\S+')
echo "Current model: $current"

players=$(timeout 5 bash -c "exec 3<>/dev/tcp/$STATUS_HOST/44455; cat <&3" 2>/dev/null \
    | grep -oP '<connected>\K[0-9]+' || true)
if [[ -n $players && $players != 0 ]]; then
    confirm "$players player(s) online; the pod restart kicks them. Go on?" || exit 1
fi

# --- The key: allow the new model (keep the old one so switching back needs no key change) ---
echo "Reading keys from pass..."
master=$(pass show homelab/litellm/master-key | head -1)
key=$(pass show homelab/swgemu/litellm-key | head -1)
models=$(curl -fsS "$LITELLM/key/info?key=$key" -H "Authorization: Bearer $master" | jq -c --arg m "$MODEL" '(.info.models // []) + [$m] | unique')
curl -fsS "$LITELLM/key/update" -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
    -d "{\"key\": \"$key\", \"models\": $models}" >/dev/null
echo "Key swgemu-talk now allows: $models"

echo "Checking the model through the key (a cold model can take ~30 s)..."
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 "$LITELLM/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hi.\"}], \"max_tokens\": 5, \"think\": false}")
echo "  test reply: HTTP $code"
[[ $code == 200 ]] || { echo "The model doesn't answer through the key; not changing the server." >&2; exit 1; }

# --- The manifest ---
if [[ $current == "$MODEL" ]]; then
    echo "core3.yml already uses $MODEL; nothing to deploy."
    exit 0
fi
sed -i "/name: TALK_MODEL/{n;s#value: .*#value: $MODEL#}" "$MANIFEST"
grep -A1 'name: TALK_MODEL' "$MANIFEST"
git commit -q -m "SWGEmu: talk model $MODEL" -- "$MANIFEST"
git push origin main

# --- Rollout ---
kubectl -n argocd annotate application swgemu argocd.argoproj.io/refresh=normal --overwrite >/dev/null || true
echo "Waiting for ArgoCD to apply it..."
applied=""
for _ in $(seq 60); do
    applied=$(kubectl -n swgemu get deploy core3 -o json \
        | jq -r '.spec.template.spec.containers[] | select(.name == "talk") | .env[] | select(.name == "TALK_MODEL") | .value')
    [[ $applied == "$MODEL" ]] && break
    sleep 5
done
[[ $applied == "$MODEL" ]] || { echo "ArgoCD hasn't applied it after 5 minutes. Check: kubectl -n argocd get app swgemu" >&2; exit 1; }
kubectl -n swgemu rollout status deploy/core3 --timeout=15m
echo
kubectl -n swgemu logs deploy/core3 -c talk | grep 'talk bridge up' | tail -1
echo "Talk model is now $MODEL."
