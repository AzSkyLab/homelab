#!/usr/bin/env bash
# swgemu-deploy.sh — Build, push and deploy the SWGEmu Core3 image from homelab main
# Builds ghcr.io/azskylab/swgemu-core3:<core3 sha8>-<homelab sha7> (skipped if it's already built here), pushes it,
# sets that tag on every image: line in core3.yml, commits it and pushes main. ArgoCD then restarts the pod (~80 s
# save, ~1 min boot). Waits for the new pod and shows the Living Cities and talk bridge start lines.
# The image goes up before the manifest: core3 uses Recreate, so a tag nobody can pull means downtime.
#
# Usage: bash scripts/swgemu-deploy.sh

set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

IMAGE="ghcr.io/azskylab/swgemu-core3"
MANIFEST="kubernetes/manifests/swgemu/core3.yml"
STATUS_HOST="10.0.20.84"

confirm() { read -r -p "$1 [y/N] " reply; [[ $reply == [yY]* ]]; }

echo "=== SWGEmu deploy ==="

# --- Preconditions ---
branch=$(git branch --show-current)
[[ $branch == main ]] || { echo "On branch $branch; deploys go from main." >&2; exit 1; }
dirty=$(git status --porcelain -- images/swgemu-core3 "$MANIFEST" | grep -v __pycache__ || true)
if [[ -n $dirty ]]; then
    echo "Uncommitted server files (they'd go into the image under the wrong tag); commit them first:" >&2
    echo "$dirty" >&2
    exit 1
fi

tag="$(grep -oP 'CORE3_REF=\K.{8}' images/swgemu-core3/Dockerfile)-$(git log -1 --format=%h -- images/swgemu-core3)"
echo "Image: $IMAGE:$tag"

players=$(timeout 5 bash -c "exec 3<>/dev/tcp/$STATUS_HOST/44455; cat <&3" 2>/dev/null \
    | grep -oP '<connected>\K[0-9]+' || true)
if [[ -z $players ]]; then
    echo "Status port isn't answering (server down or booting)."
elif [[ $players != 0 ]]; then
    confirm "$players player(s) online; the restart kicks them. Deploy anyway?" || exit 1
else
    echo "Players online: 0"
fi

if [[ -z $(kubectl -n swgemu get secret swgemu-secrets -o jsonpath='{.data.litellm-key}') ]]; then
    echo "No LiteLLM key in swgemu-secrets: the NPCs will only give canned lines (run scripts/swgemu-talk-key.sh)."
    confirm "Deploy without it?" || exit 1
fi

# --- Image ---
if docker image inspect "$IMAGE:$tag" >/dev/null 2>&1; then
    echo "Already built here."
else
    (cd images/swgemu-core3 && docker build --build-arg JOBS=24 -t "$IMAGE:$tag" .)
fi
docker push "$IMAGE:$tag"

# --- Manifest ---
sed -i "s#$IMAGE:[0-9a-f-]*#$IMAGE:$tag#" "$MANIFEST"
if [[ $(grep -c "$IMAGE:" "$MANIFEST") != $(grep -c "$IMAGE:$tag\$" "$MANIFEST") ]]; then
    echo "Not every image: line in $MANIFEST got the tag:" >&2
    grep -n "$IMAGE:" "$MANIFEST" >&2
    exit 1
fi
if ! git diff --quiet -- "$MANIFEST"; then
    git commit -q -m "SWGEmu: image $tag" -- "$MANIFEST"
    echo "Committed: SWGEmu: image $tag"
fi
git push origin main

# --- Rollout ---
kubectl -n argocd annotate application swgemu argocd.argoproj.io/refresh=normal --overwrite >/dev/null || true
echo "Waiting for ArgoCD to apply the new tag..."
current=""
for _ in $(seq 60); do
    current=$(kubectl -n swgemu get deploy core3 -o jsonpath='{.spec.template.spec.containers[0].image}')
    [[ $current == "$IMAGE:$tag" ]] && break
    sleep 5
done
if [[ $current != "$IMAGE:$tag" ]]; then
    echo "ArgoCD hasn't applied it after 5 minutes (deployment still on $current). Check: kubectl -n argocd get app swgemu" >&2
    exit 1
fi
echo "Applied. Old pod saving, then the new one boots..."
kubectl -n swgemu rollout status deploy/core3 --timeout=15m

echo
echo "--- Our screenplays ---"
kubectl -n swgemu logs deploy/core3 -c core3 | grep -E 'LivingCities|LivingTalk' | tail -20 || echo "(no start lines yet)"
errors=$(kubectl -n swgemu logs deploy/core3 -c core3 | grep -iE 'lua.*error|error.*lua' || true)
if [[ -n $errors ]]; then
    echo "--- Lua errors ---"
    head -20 <<<"$errors"
else
    echo "No Lua errors."
fi
if kubectl -n swgemu get deploy core3 -o jsonpath='{.spec.template.spec.containers[*].name}' | grep -qw talk; then
    echo "--- Talk bridge ---"
    kubectl -n swgemu logs deploy/core3 -c talk | tail -5
fi
echo
echo "Deployed $tag."
