#!/usr/bin/env bash
# Sets up the local AI 3D service on the workstation (RTX 5090): ComfyUI with TRELLIS.2 (image to textured mesh) and
# SDXL with OpenPose/depth ControlNets (concept images in a given pose). Everything heavy goes in $AI3D_HOME (default
# ~/ai-3d), outside any repo. Re-running is safe: finished steps are skipped. Every version is pinned below; see
# models.md for what each piece is for and its licence.
set -euo pipefail

AI3D_HOME="${AI3D_HOME:-$HOME/ai-3d}"
PYTHON_VERSION=3.12
TORCH_INDEX=https://download.pytorch.org/whl/cu128          # cu128 has Blackwell (sm_120) kernels
TORCH_PKGS="torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0"
COMFY_REPO=https://github.com/comfyanonymous/ComfyUI.git
COMFY_TAG=v0.40.0                                            # 3541246a9c997f4b8c32f9f88f3c985d02021c79
NODES=(
  "ComfyUI-TRELLIS2 https://github.com/PozzettiAndrea/ComfyUI-TRELLIS2.git 3e696f2cf174dba141c9efce0205e9a2d87e908a"
  "ComfyUI-GeometryPack https://github.com/PozzettiAndrea/ComfyUI-GeometryPack 1cbd14431bc88df27e5368f3e375b6bafd09006e"
)
SA3_REV=75aad8836271cb5a5123fb58304fae5d3bb4b0f9            # Stable Audio 3 (sound effects, tools/ai_audio in the game repo)
# repo  revision  file-or-pattern  destination (relative to ComfyUI/models)  [size in bytes: a file of another size is fetched again]
MODELS=(
  "stabilityai/stable-diffusion-xl-base-1.0 462165984030d82259a11f4367a4eed129e94a7b sd_xl_base_1.0.safetensors checkpoints/sd_xl_base_1.0.safetensors"
  "xinsir/controlnet-openpose-sdxl-1.0 23f966cd5cfdd3f7729c903e243d87152162d2b7 diffusion_pytorch_model.safetensors controlnet/xinsir_openpose_sdxl.safetensors"
  "xinsir/controlnet-depth-sdxl-1.0 961552fa2913e3aa82cdfb32cb51bf182d95207c diffusion_pytorch_model.safetensors controlnet/xinsir_depth_sdxl.safetensors"
  "PIA-SPACE-LAB/dinov3-vitl-pretrain-lvd1689m de90c8877a44ba5c7aa5a6a7ffd747c367c3dd6a model.safetensors dinov3/model.safetensors"
  "Comfy-Org/stable-audio-3 $SA3_REV checkpoints/stable_audio_3_small_sfx.safetensors checkpoints/stable_audio_3_small_sfx.safetensors 2270384940"
  "Comfy-Org/stable-audio-3 $SA3_REV checkpoints/stable_audio_3_medium.safetensors checkpoints/stable_audio_3_medium.safetensors 9222116660"
  "Comfy-Org/stable-audio-3 $SA3_REV text_encoders/t5gemma_b_b_ul2.safetensors text_encoders/t5gemma_b_b_ul2.safetensors 1187264003"
)
TRELLIS_REPO=microsoft/TRELLIS.2-4B
TRELLIS_REV=af44b45f2e35a493886929c6d786e563ec68364d
BIREFNET_REPO=ZhengPeng7/BiRefNet
BIREFNET_REV=e2bf8e4460fc8fa32bba5ea4d94b3233d367b0e4      # runs remote code: pinned, and ai3d.sh starts offline

say() { printf '\n== %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need uv; need git; need nvidia-smi

mkdir -p "$AI3D_HOME"
cd "$AI3D_HOME"

say "Python $PYTHON_VERSION venv"
[ -x venv/bin/python ] || uv venv --python "$PYTHON_VERSION" venv
PY="$AI3D_HOME/venv/bin/python"

say "PyTorch ($TORCH_PKGS)"
uv pip install --python "$PY" $TORCH_PKGS --index-url "$TORCH_INDEX"

say "ComfyUI $COMFY_TAG"
[ -d ComfyUI/.git ] || git clone "$COMFY_REPO" ComfyUI
git -C ComfyUI fetch --tags -q
git -C ComfyUI checkout -q "$COMFY_TAG"
uv pip install --python "$PY" -r ComfyUI/requirements.txt

say "Custom nodes"
for entry in "${NODES[@]}"; do
  read -r name url rev <<<"$entry"
  dir="ComfyUI/custom_nodes/$name"
  [ -d "$dir/.git" ] || git clone "$url" "$dir"
  git -C "$dir" fetch -q origin
  git -C "$dir" checkout -q "$rev"
done
# The TRELLIS.2 node builds an isolated pixi env in ~/.ce (about 22 GB) with prebuilt CUDA wheels
# (flash-attn, sageattention, cumesh, o-voxel, flex-gemm, drtk) from github.com/PozzettiAndrea/cuda-wheels.
uv pip install --python "$PY" -r ComfyUI/custom_nodes/ComfyUI-TRELLIS2/requirements.txt
(cd ComfyUI/custom_nodes/ComfyUI-TRELLIS2 && "$PY" install.py)

say "Models (pinned revisions)"
"$PY" - "$AI3D_HOME/ComfyUI/models" "${MODELS[@]}" <<'PYEOF'
import os, shutil, sys
from huggingface_hub import hf_hub_download
models = sys.argv[1]
for entry in sys.argv[2:]:
    repo, rev, fname, dest, *size = entry.split()
    out = os.path.join(models, dest)
    if os.path.exists(out) and (not size or os.path.getsize(out) == int(size[0])):
        print("have", dest); continue
    os.makedirs(os.path.dirname(out), exist_ok=True)
    path = hf_hub_download(repo, fname, revision=rev, local_dir=os.path.join(models, ".dl", repo.replace("/", "--")))
    shutil.move(path, out)
    print("got", dest)
shutil.rmtree(os.path.join(models, ".dl"), ignore_errors=True)
PYEOF
"$PY" - "$AI3D_HOME/ComfyUI/models" "$TRELLIS_REPO" "$TRELLIS_REV" "$BIREFNET_REPO" "$BIREFNET_REV" <<'PYEOF'
import os, sys
from huggingface_hub import snapshot_download
models, trepo, trev, brepo, brev = sys.argv[1:]
# TRELLIS.2 weights in the layout the node expects (models/trellis2/pipeline.json, ckpts/...).
snapshot_download(trepo, revision=trev, local_dir=os.path.join(models, "trellis2"), allow_patterns=["pipeline.json", "ckpts/*"])
# BiRefNet (background removal) into the cache the node reads; the node loads it with trust_remote_code.
snapshot_download(brepo, revision=brev, cache_dir=os.path.join(models, "birefnet"))
ref = os.path.join(models, "birefnet", "models--" + brepo.replace("/", "--"), "refs", "main")
os.makedirs(os.path.dirname(ref), exist_ok=True)
open(ref, "w").write(brev)  # offline loads resolve "main" to the pinned revision
print("trellis2 and birefnet ready")
PYEOF

say "Check"
"$PY" -c "import torch; print(torch.__version__, torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0))"
echo "Done. Start with: $(dirname "$(readlink -f "$0")")/ai3d.sh start"
