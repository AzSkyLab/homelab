#!/usr/bin/env bash
# swgemu-talk-key.sh — Create the LiteLLM key for the SWGEmu talk bridge and give it to the cluster
# Makes a LiteLLM virtual key that can only use the talk model, stores it in pass (homelab/swgemu/litellm-key) and in
# the swgemu-secrets Secret (litellm-key). Safe to run again: an existing key in pass is reused.
# Run it before swgemu-deploy.sh: the bridge reads the key when the pod starts.
#
# Usage: bash scripts/swgemu-talk-key.sh   (in a terminal: pass asks for the GPG passphrase)

set -euo pipefail

LITELLM="https://llm.home.lab"
MODEL="vm/qwen3.8:27b"
ALIAS="swgemu-talk"
PASS_PATH="homelab/swgemu/litellm-key"
PASS_FILE="${PASSWORD_STORE_DIR:-$HOME/.password-store}/$PASS_PATH.gpg"

echo "=== SWGEmu talk bridge key ==="

if [[ -f $PASS_FILE ]]; then
    echo "Key already in pass ($PASS_PATH), reusing it."
    key=$(pass show "$PASS_PATH" | head -1)
else
    echo "Reading the LiteLLM master key from pass..."
    master=$(pass show homelab/litellm/master-key | head -1)

    existing=$(curl -fsS "$LITELLM/key/list?key_alias=$ALIAS" -H "Authorization: Bearer $master" | jq -r '.total_count // 0')
    if [[ $existing != 0 ]]; then
        echo "LiteLLM already has a key named $ALIAS, but it isn't in pass, so its value is lost." >&2
        echo "Delete it in the LiteLLM UI ($LITELLM/ui, Virtual Keys), then run this again." >&2
        exit 1
    fi

    echo "Creating key $ALIAS for $MODEL..."
    resp=$(curl -fsS "$LITELLM/key/generate" -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
        -d "{\"models\": [\"$MODEL\"], \"key_alias\": \"$ALIAS\", \"metadata\": {\"purpose\": \"SWGEmu talk bridge\"}}")
    key=$(jq -r '.key // empty' <<<"$resp")
    if [[ -z $key ]]; then
        echo "LiteLLM didn't return a key:" >&2
        jq -c 'del(.key)' <<<"$resp" >&2
        exit 1
    fi

    printf '%s\n' "$key" | pass insert -e "$PASS_PATH" >/dev/null
    echo "Stored in pass: $PASS_PATH"
fi

echo "Checking the key (a cold model can take ~30 s)..."
models=$(curl -fsS "$LITELLM/v1/models" -H "Authorization: Bearer $key" | jq -r '[.data[].id] | join(", ")')
echo "  models it can use: $models"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 "$LITELLM/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hi.\"}], \"max_tokens\": 5, \"think\": false}")
echo "  test reply: HTTP $code"
[[ $code == 200 ]] || { echo "The key doesn't work against $MODEL; not touching the cluster." >&2; exit 1; }

kubectl -n swgemu patch secret swgemu-secrets --type merge -p "{\"stringData\":{\"litellm-key\":\"$key\"}}"

# The bridge only reads the key at start: restart now if the pod already runs it.
if kubectl -n swgemu get deploy core3 -o jsonpath='{.spec.template.spec.containers[*].name}' | grep -qw talk; then
    read -r -p "The server already runs the talk bridge. Restart core3 now so it picks up the key? [y/N] " reply
    if [[ $reply == [yY]* ]]; then
        kubectl -n swgemu rollout restart deploy/core3
        kubectl -n swgemu rollout status deploy/core3 --timeout=15m
    else
        echo "Later: kubectl -n swgemu rollout restart deploy/core3"
    fi
else
    echo "Done. Next: bash scripts/swgemu-deploy.sh"
fi
