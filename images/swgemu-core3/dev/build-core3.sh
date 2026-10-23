#!/usr/bin/env bash
# build-core3.sh — Incremental build of Core3 plus our patches (../patches/) for the local test server
# Keeps a pristine Core3 checkout at CORE3_REF and a patched build tree in $CORE3_DEV_WORK. Each run syncs the
# patches into the tree touching only files whose content changed, so ninja rebuilds only what our change affects.
# Compiles in the Dockerfile's deps stage (same clang and CPU flags as production, plus -DDEBUG_AI), then packs the
# binary into a local image for dev/docker-compose.yml. Builds take turns through a lock (several agents may call it).
#
# Usage: bash dev/build-core3.sh            # then: CORE3_IMAGE=ghcr.io/azskylab/swgemu-core3:dev-bots docker compose up -d
#        JOBS=16 bash dev/build-core3.sh    # fewer compile jobs

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
img=$(dirname "$here")
WORK=${CORE3_DEV_WORK:-$HOME/.cache/swgemu-scratch/core3-dev}
JOBS=${JOBS:-24}
REF=$(grep -oP 'CORE3_REF=\K[0-9a-f]+' "$img/Dockerfile")
DEPS_IMAGE=swgemu-core3-deps:local
BASE_IMAGE=${CORE3_DEV_BASE:-ghcr.io/azskylab/swgemu-core3:dev-debug-ai}
OUT_IMAGE=${CORE3_DEV_IMAGE:-ghcr.io/azskylab/swgemu-core3:dev-bots}

mkdir -p "$WORK"
exec 9>"$WORK/build.lock"
echo "Waiting for the build lock..." >&2
flock 9

# --- Pristine checkout at CORE3_REF ---
if [[ ! -d $WORK/pristine/.git ]]; then
    git init -q "$WORK/pristine"
    git -C "$WORK/pristine" remote add origin https://github.com/swgemu/Core3.git
fi
if [[ $(git -C "$WORK/pristine" rev-parse HEAD 2>/dev/null) != "$REF" ]]; then
    git -C "$WORK/pristine" fetch -q --depth 50 origin "$REF"
    git -C "$WORK/pristine" checkout -q -f FETCH_HEAD
    git -C "$WORK/pristine" submodule update --init --recursive --depth 1
fi

# --- Stage: pristine + our patches, then sync into the build tree by content ---
rsync -a --delete --exclude .git "$WORK/pristine/" "$WORK/stage/"
cp -r "$img/patches/bots" "$WORK/stage/MMOCoreORB/src/server/zone/managers/bot"
for p in "$img"/patches/*.patch; do
    [[ -e $p ]] || continue
    git -C "$WORK/stage" apply --whitespace=nowarn "$p" || { echo "Patch doesn't apply: $p" >&2; exit 1; }
done
mkdir -p "$WORK/src"
# Generated in the tree by the build (IDL output, engine3's library): keep them, or everything recompiles.
# --no-times: rsync -a would otherwise reset the mtime of files whose content didn't change, and ninja rebuilds them
rsync -a --no-times --checksum --delete \
    --exclude /MMOCoreORB/build/ --exclude /MMOCoreORB/bin/core3 \
    --exclude /MMOCoreORB/src/autogen/ --exclude /MMOCoreORB/utils/engine3/MMOEngine/lib/ \
    "$WORK/stage/" "$WORK/src/"

# CMake globs source files at configure time: configure again when our file list changes
botfiles=$(cd "$WORK/src/MMOCoreORB/src/server/zone/managers/bot" && ls | sort | tr '\n' ' ')
reconfigure=0
[[ $botfiles == "$(cat "$WORK/botfiles.stamp" 2>/dev/null)" ]] || reconfigure=1

# --- Toolchain image (the Dockerfile's deps stage) ---
docker build -q --target deps -t "$DEPS_IMAGE" "$img" >/dev/null

# --- Compile ---
mkdir -p "$WORK/src/MMOCoreORB/build/unix/ninja"   # made here, or docker makes it as root
docker run --rm --user "$(id -u):$(id -g)" -v "$WORK/src:/core3" -w /core3/MMOCoreORB/build/unix/ninja \
    -e HOME=/tmp "$DEPS_IMAGE" sh -euxc "
        [ -f build.ninja ] || cmake -G Ninja ../../.. \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_FLAGS='-march=sandybridge -mtune=sandybridge' \
            -DCMAKE_CXX_FLAGS='-march=sandybridge -mtune=sandybridge -DDEBUG_AI' \
            -DENABLE_NATIVE=OFF -DCOMPILE_TESTS=OFF -DENABLE_BUILD_CLIENT=OFF -DENABLE_CCACHE=OFF -DRUN_GIT=OFF
        [ $reconfigure = 0 ] || cmake .
        ninja -j$JOBS core3
    "
echo "$botfiles" > "$WORK/botfiles.stamp"

# --- Pack the binary into a dev image for docker-compose ---
mkdir -p "$WORK/out"
cp "$WORK/src/MMOCoreORB/build/unix/ninja/src/core3" "$WORK/out/core3"
printf 'FROM %s\nCOPY core3 /opt/swgemu/bin/core3\n' "$BASE_IMAGE" | docker build -q -t "$OUT_IMAGE" -f - "$WORK/out" >/dev/null
echo "Built $OUT_IMAGE"
