# patches/

Applied by `build-mpv-custom.sh` (it looks for this folder next to itself;
override with `PATCH_DIR=<dir>`). Each patch is applied all-or-nothing, and a
patch that no longer fits a revision is reported and skipped, never fatal.

| File | Applied to | Switch |
|---|---|---|
| `libplacebo/lp-0001-itm-desaturation.patch` | colorspace.c (SDR->HDR inverse tone mapping) | `PATCH_ITM` / `--no-itm-patch` |
| `libplacebo/lp-0002-metal-gpu-timer.patch` | Metal GPU timers (gpu.h, gpu.cc, gpu_pass.cc) | `ENABLE_METAL` |
| `libplacebo/lp-0003-python314-utils-gen.patch` | vulkan/utils_gen.py, Python 3.14+ | always (if file exists) |
| `mpv/mpv-0001-coreaudio-channel-map.patch` | audio/out/ao_coreaudio.c (upstream fix for macOS 15+ / 27) | `ENABLE_METAL` |
| `mpv/mpv-0002-metal-backend-context.patch` | new video/out/metal/*, meson.build, gpu + gpu_next context.c | `ENABLE_METAL` |

Order matters for mpv: 0001, 0002.

## Changing or adding a patch
1. Check out the same ref the build uses, apply the existing patches, edit.
2. `git add -N <new files>` then `git diff > patches/<repo>/NNNN-name.patch`.
3. Test: `git apply --check patches/<repo>/NNNN-name.patch` on a clean checkout.
4. Register it in the script: copy the pattern of an existing `apply_patch` call
   and add a `_need_patch` line to the preflight.
