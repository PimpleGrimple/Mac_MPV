# Anime4K Shaders (Categorized & Enhanced)

This directory contains the complete set of Anime4K v4.x shaders with enhanced models and categorized subdirectories for organized reference and mpv integration.

---

## Directory Structure

```text
Anime4K/
├── All-in-One/            # Unified multi-stage pipeline shaders
│   └── Anime4K_AIO_optQ.glsl
│
├── Restore/               # Artifact removal, line reconstruction & de-ringing
│   ├── Anime4K_Clamp_Highlights.glsl
│   ├── Anime4K_Restore_CNN_{S, M, L, VL, UL}.glsl
│   ├── Anime4K_Restore_CNN_Soft_{S, M, L, VL, UL}.glsl
│   ├── Anime4K_Restore_GAN_UL.glsl       (Original raw GAN)
│   ├── Anime4K_Restore_GAN_UL_CC.glsl    (Color-corrected with chaiNNer cfix)
│   └── Anime4K_Restore_GAN_UUL.glsl
│
├── Upscale/               # Real-time neural network upscaling
│   ├── Anime4K_AutoDownscalePre_{x2, x4}.glsl (Resolution guards)
│   ├── Anime4K_Upscale_CNN_x2_{S, M, L, VL, UL}.glsl
│   ├── Anime4K_Upscale_GAN_x2_{S, M, UL}.glsl
│   ├── Anime4K_Upscale_GAN_x3_{L, VL}.glsl
│   ├── Anime4K_Upscale_GAN_x4_{UL, UUL}.glsl
│   ├── Anime4K_Upscale_DTD_x2.glsl
│   ├── Anime4K_Upscale_Deblur_DoG_x2.glsl
│   ├── Anime4K_Upscale_Deblur_Original_x2.glsl
│   ├── Anime4K_Upscale_DoG_x2.glsl
│   ├── Anime4K_Upscale_Original_x2.glsl
│   └── Anime4K_3DGraphics_{AA_}Upscale_x2_US.glsl
│
├── Upscale+Denoise/       # Combined upscaling and noise reduction
│   └── Anime4K_Upscale_Denoise_CNN_x2_{S, M, L, VL, UL}.glsl
│
├── Denoise/               # Standalone bilateral noise filters
│   ├── Anime4K_Denoise_Bilateral_Mean.glsl
│   ├── Anime4K_Denoise_Bilateral_Median.glsl
│   └── Anime4K_Denoise_Bilateral_Mode.glsl
│
├── Deblur/                # Standalone deblurring filters
│   ├── Anime4K_Deblur_DoG.glsl
│   └── Anime4K_Deblur_Original.glsl
│
├── Experimental-Effects/  # Stylistic post-processing
│   ├── Anime4K_Darken_{Fast, HQ, VeryFast}.glsl
│   └── Anime4K_Thin_{Fast, HQ, VeryFast}.glsl
│
└── Docs/                  # Official documentation and platform guides
    ├── GLSL_Instructions.md
    ├── GLSL_Instructions_Advanced.md
    └── GLSL_Instructions_Mac_MPV.md (and others)
```

---

## Model Sizes & Performance Tiers

| Size Tag | Full Name | Target GPU Class | Description |
| :--- | :--- | :--- | :--- |
| **S** | Small | Integrated Graphics (Intel UHD / Vega) | Fastest, minimal overhead |
| **M** | Medium | Mid-range laptops / Entry GPUs | Balanced speed and quality |
| **L** | Large | Dedicated mid-range GPUs (GTX 1650, RTX 3050) | High fidelity line recovery |
| **VL** | Very Large | Performance GPUs (RTX 3060 / 4060, Apple M Pro) | Very high quality, heavier compute |
| **UL** | Ultra Large | High-end GPUs (RTX 3070+, Apple M Max) | Maximum precision neural network |
| **UUL** | Ultra Ultra Large | Enthusiast GPUs (RTX 3080/4080/4090) | Extreme compute, deepest network |

---

## Enhancements in this Set

1. **`Anime4K_Restore_GAN_UL_CC.glsl`**: Color-corrected model using average color correction (`cfix`), eliminating subtle color shifts produced by raw GAN restoration.
2. **`Anime4K_AIO_optQ.glsl`**: All-in-one optimized pipeline chaining highlight clamping, restoration, and upscaling into a single unified shader pass.
3. **`Anime4K_Upscale_GAN_x2_UL.glsl`**: 2x Ultra Large GAN model included.
4. **Clean OSD metadata**: Shader description tags display standardized names in MPV OSD and script menus.
