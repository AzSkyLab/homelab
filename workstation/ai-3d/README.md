# AI 3D service (workstation)

Local image and 3D generation on the workstation's RTX 5090, used by the game repo's art tools
(`~/github/videogame/tools/ai_assets/`). Nothing here is exposed on the network: ComfyUI listens on 127.0.0.1 only.

## Use

```bash
workstation/ai-3d/setup.sh          # once (and after changing a pin): about 50 GB in ~/ai-3d and ~/.ce
workstation/ai-3d/ai3d.sh start     # ComfyUI at http://127.0.0.1:8188 (offline: no downloads at run time)
workstation/ai-3d/ai3d.sh status    # running? warns if Ollama holds VRAM
workstation/ai-3d/ai3d.sh stop
```

Before TRELLIS.2 runs (about 24 GB VRAM), unload Ollama models: `ollama ps`, then `ollama stop <model>`.

`ai3d.sh start` keeps the models on the GPU between jobs (`AI3D_VRAM=high`, ComfyUI's `--highvram`): in ComfyUI's default
mode the TRELLIS.2 worker parked about 17 GB of weights in system RAM between jobs. That holds the card's memory while the
service runs, so Ollama (the LiteLLM backend on this card) has little room; when you need Ollama while ComfyUI runs, start it
with `AI3D_VRAM=normal workstation/ai-3d/ai3d.sh start` (models go back to RAM after each job).
SDXL alone needs about 8 GB and can share the card with a small Ollama model.

## Layout

| Path | What |
|---|---|
| `workstation/ai-3d/` (this repo) | `setup.sh`, `ai3d.sh`, `models.md` (pins and licences), this README |
| `~/ai-3d/venv` | Python 3.12 venv (uv) with PyTorch cu128 and ComfyUI's requirements |
| `~/ai-3d/ComfyUI` | ComfyUI at a pinned tag, custom nodes in `custom_nodes/`, weights in `models/` |
| `~/.ce` | The TRELLIS2 node's isolated pixi env (made by `comfy-env`) |

## How the game uses it

The game repo's scripts post graphs to `http://127.0.0.1:8188/prompt` and read results from `/history`:
an OpenPose skeleton or depth render from the game's rig -> SDXL + ControlNet concept image -> TRELLIS.2 textured
mesh (remeshed to a target face count, inner faces removed) -> Blender fit to the game skeleton.
See `models.md` before adding or updating a model.
