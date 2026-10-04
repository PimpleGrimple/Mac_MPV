# RAVU & RAISR Shaders (Categorized & Enhanced)

This directory contains the complete collection of RAVU (Rapid and Accurate Video Upscaler) and Intel RAISR shaders, organized by GPU execution pipeline and scaling model.

---

## Directory Structure

```text
RAISR/
├── Intel-RAISR/               # Intel RAISR ML upscalers and denoisers (7 shaders)
│   ├── Intel_RAISR_x1p5_denoise.glsl
│   ├── Intel_RAISR_x1p5_highres.glsl
│   ├── Intel_RAISR_x2_denoise.glsl
│   ├── Intel_RAISR_x2_{highres, lowres}.glsl
│   └── Intel_RAISR_x2_{highres, lowres}_sharp.glsl
│
└── ravu/                      # RAVU prescalers & zoom filters (52 shaders)
    ├── Compute/               # Threadgroup shared-memory compute shaders (Hooke007 set)
    │   │                      # [Fastest on Vulkan & Direct3D 11]
    │   ├── Zoom/              # Arbitrary scaling ratio directly to target output
    │   │   ├── ravu_zoom_ar_r{2,3}{,_rgb,_yuv}.glsl   (Anti-Ringing, recommended)
    │   │   ├── ravu_zoom_r{2,3}{,_chroma,_rgb,_yuv}.glsl
    │   │   └── ravu_zoom_pc_r3{,_rgb}.glsl           (Pixel-Clipped)
    │   ├── Lite/              # Lightweight fast 2x upscalers (Minimal GPU overhead)
    │   │   ├── ravu_lite_ar_r{2,3,4}.glsl            (Anti-Ringing)
    │   │   └── ravu_lite_r{2,3,4}.glsl
    │   ├── Standard-2x/       # Full 2x upscalers
    │   │   └── ravu_r{2,3,4}{,_rgb,_yuv}.glsl
    │   └── 3x/                # Dedicated 3x upscalers
    │       └── ravu_3x_r{2,3,4}{,_rgb,_yuv}.glsl
    │
    ├── Gather/                # Hardware textureGather fragment shaders (Dyphire set)
    │   │                      # [Optimal for OpenGL 4.0+ / macOS without compute]
    │   ├── ravu-lite-ar-r{2,3,4}.glsl
    │   └── ravu-zoom-ar-r{2,3}.glsl
    │
    ├── Fragment/              # Universal fallback pixel shaders (Dyphire set)
    │   │                      # [Legacy hardware compatibility]
    │   ├── ravu-lite-ar-r{2,3,4}.glsl
    │   └── ravu-zoom-ar-r{2,3}.glsl
    │
    └── Hooks/                 # Reference legacy MPV .hook files
        ├── ravu-lite-r4.hook
        └── ravu-r4.hook
```

---

## Comparison: Compute vs Gather vs Fragment

| Pipeline | Source | GPU Mechanism | Best Used When |
| :--- | :--- | :--- | :--- |
| **Compute** | Hooke007 | `//!COMPUTE 32 8`, thread-group `shared float samples[]` | Running on **Vulkan** (`gpu-api=vulkan`) or Direct3D 11. Caches texels in GPU shared memory for maximum efficiency. |
| **Gather** | Dyphire | `textureGatherOffset(HOOKED_raw, ...)` | Running on **macOS OpenGL** (`gpu-api=opengl`) or backends where compute shaders stutter. Fetches 4 texels per hardware cycle. |
| **Fragment** | Dyphire | Standard `HOOKED_tex(...)` pixel shader | Maximum universal fallback if compute and gather are unsupported. |

---

## Model Variations Explained

- **`zoom`**: Arbitrary scaling factor (`OUTPUT.w / HOOKED.w`). Replaces the standard `--scale` filter.
- **`lite`**: Simplified kernel with reduced weight calculations, optimized for speed.
- **`-ar` / `_ar`**: **Anti-Ringing**. Clamps edge overshoots, eliminating halo artifacts. Essential for animation.
- **`r2` / `r3` / `r4`**: **Radius**. 
  - `r2` = Small / Fast (Low GPU load)
  - `r3` = Medium / Balanced (**Recommended sweet spot**)
  - `r4` = Large / Maximum sharpness (High GPU load)
- **Plane suffixes**:
  - *(no suffix)* = Processes Luma (`Y`) plane only (fastest and visually most significant).
  - `_rgb` = Processes full RGB planes.
  - `_yuv` = Processes native YUV planes.
  - `_chroma` = Specialized for chroma channel reconstruction.
