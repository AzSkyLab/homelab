# AI 3D service: models, nodes and licences

Everything `setup.sh` installs, pinned to the revision it was tested with (2026-10-14). Licences were read on that date.
Update a pin only after re-reading the licence and re-running a test generation.

| Piece | Source and revision | Used for | Licence | Notes |
|---|---|---|---|---|
| ComfyUI | `comfyanonymous/ComfyUI` tag `v0.40.0` | Runs the graphs, HTTP API on 127.0.0.1:8188 | GPL-3.0 | Dev tool only; nothing ships with the game |
| PyTorch | `torch 2.11.0+cu128` (download.pytorch.org cu128) | GPU maths | BSD-3 | cu128 has RTX 50 (sm_120) kernels |
| ComfyUI-TRELLIS2 node | `PozzettiAndrea/ComfyUI-TRELLIS2` @ `3e696f2` | TRELLIS.2 in ComfyUI | MIT | Uses `comfy-env` 0.3.89: builds a pixi env in `~/.ce` (about 22 GB) and installs prebuilt CUDA wheels from `PozzettiAndrea/cuda-wheels` (third-party binaries) |
| ComfyUI-GeometryPack node | `PozzettiAndrea/ComfyUI-GeometryPack` @ `1cbd144` | Mesh helpers the TRELLIS2 node depends on | see repo | Pulled in by the TRELLIS2 node |
| TRELLIS.2-4B | `microsoft/TRELLIS.2-4B` @ `af44b45` | Image to textured 3D mesh (PBR) | MIT | Needs about 24 GB VRAM; unload Ollama models first |
| DINOv3 ViT-L/16 | `PIA-SPACE-LAB/dinov3-vitl-pretrain-lvd1689m` @ `de90c88` (re-upload of `facebook/dinov3-vitl16-pretrain-lvd1689m`) | Image encoder inside TRELLIS.2 | DINOv3 License (Meta) | Royalty-free, no user threshold; bars military, weapons, nuclear and espionage use; redistribution needs the licence and "Built with DINOv3". The official repo is gated: accept the licence there once (owner to-do); we only run it locally |
| BiRefNet | `ZhengPeng7/BiRefNet` @ `e2bf8e4` | Background removal before TRELLIS.2 | MIT | Loaded with `trust_remote_code`: pinned, and `ai3d.sh` starts with `HF_HUB_OFFLINE=1` so new code is never fetched |
| SDXL base 1.0 | `stabilityai/stable-diffusion-xl-base-1.0` @ `4621659` | Concept images | CreativeML OpenRAIL++-M | Licensor claims no rights in output; use limits (Attachment A) don't touch game art |
| ControlNet OpenPose SDXL | `xinsir/controlnet-openpose-sdxl-1.0` @ `23f966c` | Holds a character to a drawn skeleton (T-pose) | Apache-2.0 | Thick limb lines work best |
| ControlNet Depth SDXL | `xinsir/controlnet-depth-sdxl-1.0` @ `961552f` | Draws gear on a depth render of the base body; props from a depth render | Apache-2.0 | |
| Stable Audio 3 Small SFX | `Comfy-Org/stable-audio-3` @ `75aad88` (`checkpoints/stable_audio_3_small_sfx.safetensors`, 2.3 GB) | Sound effects for the game (`tools/ai_audio`) | Stability AI Community License | Free under USD 1M annual revenue; outputs are ours; <https://stability.ai/license>. Distilled: 8 steps, cfg 1, sampler `lcm`, scheduler `simple`; ComfyUI built-in nodes since v0.40.0 (`CheckpointLoaderSimple`, `CLIPLoader` type `stable_audio`, `EmptyLatentAudio`, `KSampler`, `VAEDecodeAudio`, `SaveAudio`); 0.2 to 0.4 s a take |
| Stable Audio 3 Medium | `Comfy-Org/stable-audio-3` @ `75aad88` (`checkpoints/stable_audio_3_medium.safetensors`, 9.2 GB) | Sound effects for the game (`tools/ai_audio`) | Stability AI Community License | As above; same graph with another file name |
| T5Gemma b-b UL2 | `Comfy-Org/stable-audio-3` @ `75aad88` (`text_encoders/t5gemma_b_b_ul2.safetensors`, 1.2 GB) | Text encoder for Stable Audio 3 | Gemma Terms of Use | |

Not installed, considered: Hunyuan3D 2.1 (better textures; Tencent licence excludes the EU, UK and South Korea),
Rodin and Meshy (cloud; Rodin's MCP is connected in Claude Code but can't force a T-pose),
MOSS-SoundEffect v2.0 (Apache-2.0; tried in the 2026-10-19 sound bake-off against Stable Audio 3 and dropped to keep one pipeline).
