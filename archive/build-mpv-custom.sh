#!/usr/bin/env bash
# ==============================================================================
# The Definitive Custom mpv + libplacebo Build Script for macOS
# ==============================================================================
# Builds a customized mpv and libplacebo from source entirely inside an isolated,
# self-contained directory under: ~/.config/mpv/custom-build-<timestamp>-<label>/
#
# You can edit the default configuration directly in the CONFIG section below,
# or override settings via command-line arguments when running the script.
# Boolean settings accept true/false, yes/no, 1/0 and on/off (case-sensitive);
# anything else is rejected up front instead of being run as a shell command.
#
# After the build the script runs a functional verification pass (Lua scripting,
# VapourSynth bridge, libplacebo provenance, bundle env wiring, feature probes).
# Re-run just the verification against any prefix with: --verify-only=<prefix>
# ==============================================================================

set -Eeuo pipefail

# Absolute path of this script, so messages stay runnable after we cd elsewhere.
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
    /*) ;;
    *) SCRIPT_PATH="$PWD/${SCRIPT_PATH#./}" ;;
esac

# ==============================================================================
# USER CONFIGURATION
# (Change your defaults here as you like!)
# ==============================================================================

# Custom Features requested:
PATCH_ITM=true            # Apply SDR->HDR inverse-tone-mapping chroma patch to libplacebo
ENABLE_BLURAY=true        # Blu-ray disc & directory playback (libbluray)
ENABLE_DVD=true           # DVD navigation & playback (libdvdnav + libdvdread)
ENABLE_VAPOURSYNTH="auto" # VapourSynth bridge (mpv --vf=vapoursynth); "auto" = on when headers found
VAPOURSYNTH_PREFIX="$HOME/.config/mpv/VapourSynth"   # Your own VapourSynth bundle (any dir containing VapourSynth4.h somewhere under it); "" = use brew's

# Standard mpv core defaults (needed so normal mpv builds and works without breaking):
ENABLE_METAL=false       # Apple Metal native GPU backend via libplacebo (no MoltenVK)
ENABLE_VULKAN=true        # Vulkan / MoltenVK GPU rendering
ENABLE_LUA=true           # Lua scripting for mpv user scripts
# "luajit" (Homebrew) or "lua51" (Lua 5.1.5 built from source).
# LuaJIT is the default on purpose: it is Lua 5.1-compatible *and* provides the
# extensions real-world mpv scripts rely on, such as LuaJIT's `ffi` module and
# the `goto` statement (modernx.lua uses `goto continue`, which plain Lua 5.1
# rejects with "syntax error near 'continue'"). Homebrew's `lua` formula is
# 5.4/5.5, which mpv rejects, so LuaJIT is the only packaged choice.
LUA_FLAVOR="luajit"
ENABLE_LCMS2=true         # Color management (LittleCMS 2)
ENABLE_LIBARCHIVE=true    # Archive / compressed file reading (.zip, etc.)
ENABLE_UCHARDET=true      # Subtitle charset auto-detection
ENABLE_ZIMG=true          # High-quality zimg software scaler
BUILD_CPLAYER=true        # mpv command-line binary
BUILD_BUNDLE=true         # mpv.app standalone macOS bundle

# Optional extras (OFF by default — change to true here or pass CLI flags to enable):
ENABLE_RUBBERBAND=false   # librubberband audio pitch-shifting / time-stretching
ENABLE_JS=false           # MuJS JavaScript engine
ENABLE_LIBMPV=false       # libmpv dynamic shared library (.dylib)
ENABLE_CACA=false         # libcaca ASCII color video output
ENABLE_SIXEL=false        # Sixel terminal graphics output
ENABLE_DEMOS=false        # libplacebo demo utilities

# macOS UI integration (auto detects Xcode/Swift tools):
ENABLE_SWIFT="auto"
ENABLE_MACOS_MEDIA_PLAYER="auto"
ENABLE_MACOS_TOUCHBAR="auto"

# Build versions:
MPV_MODE="dev"            # stable (v0.42.0) or dev (master)
LIBPLACEBO_DEV=true       # Build libplacebo from master HEAD
MPV_CUSTOM_REF=""         # Optional custom mpv git ref (e.g. "v0.42.0", "master", or commit)
LIBPLACEBO_CUSTOM_REF=""  # Optional custom libplacebo git ref (e.g. "v7.360.1", "master")

# Build environment & performance:
SKIP_BREW=false           # Set to true to skip automatic 'brew install' check
BUILD_TYPE="release"      # release, debug, debugoptimized
EXTRA_MPV_MESON_ARGS=""   # Additional custom meson flags for mpv
EXTRA_LIBPLACEBO_MESON_ARGS="" # Additional custom meson flags for libplacebo
JOBS=""                   # Number of parallel ninja jobs (empty = all CPU cores)

# Toolchain:
# Empty means "use the host macOS version", which matches the deployment target of
# the Homebrew libraries we link against and silences the ld "built for newer
# macOS" warnings. Override with --deployment-target=<ver> for a portable binary.
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}"
ENABLE_DOCUTILS=true      # brew install docutils so rst2man exists and man pages build

# Verification & runtime wiring:
VERIFY=true               # Run the post-build functional verification
VERIFY_ONLY_DIR=""        # --verify-only=<prefix>: skip building, just verify
VSS_APP_ENV=true          # Put VSSCRIPT_PATH into mpv.app's Info.plist (LSEnvironment),
                          # so VapourSynth works when the app is opened from Finder/Dock
VSS_LAUNCHCTL=false       # Also export VSSCRIPT_PATH globally via launchctl (+ LaunchAgent)
FIX_VS_TOML=false         # Repair ~/.config/vapoursynth/vapoursynth.toml entries whose
                          # Python framework library no longer exists (brew upgrades)

# ==============================================================================
# Help Screen
# ==============================================================================
show_help() {
    cat << 'EOF'
Usage: ./build-mpv-custom.sh [OPTIONS]

Note: You can also edit all defaults directly in the CONFIG section at the
top of this script!

BUILD VERSIONS:
  --stable                  Build stable tags for both (mpv v0.42.0, libplacebo v7.360.1) [default]
  --dev                     Build both mpv and libplacebo from git master HEAD
  --mpv-mode=<stable|dev>   Set the mpv version policy
  --mpv-dev                 Build mpv from git master HEAD
  --mpv-stable              Build the stable mpv tag (v0.42.0)
  --libplacebo-dev          Build libplacebo from git master HEAD
  --libplacebo-stable       Build the stable libplacebo tag
  --mpv-ref=<ref>           Build specific mpv tag, branch, or commit hash
  --libplacebo-ref=<ref>    Build specific libplacebo tag, branch, or commit hash

OPTIONAL EXTRAS (Off by default, pass flag to turn on):
  --vapoursynth             Enable the VapourSynth bridge (--vf=vapoursynth)
  --no-vapoursynth          Disable the VapourSynth bridge
  --vapoursynth-prefix=<dir>  Build against headers under <dir> (implies --vapoursynth);
                            pass '' for brew's VapourSynth
  --rubberband              Enable librubberband audio pitch correction
  --js, --javascript        Enable MuJS JavaScript backend
  --lua51                   Build Lua 5.1.5 from source into the prefix instead of
                            LuaJIT. Note: scripts using `ffi` or `goto` (e.g. modernx)
                            will NOT load with this
  --luajit                  Use LuaJIT instead of Lua 5.1 (default)
  --libmpv                  Build libmpv shared library (.dylib)
  --caca                    Enable libcaca ASCII video output
  --sixel                   Enable Sixel terminal graphics output
  --demos                   Build libplacebo demo programs
  --metal                   Enable native Apple Metal GPU backend (libplacebo Metal branch)
  --no-metal                Disable native Apple Metal GPU backend
  --no-itm-patch            Do not patch libplacebo for SDR->HDR inverse tone mapping

BUILD SETTINGS:
  --skip-brew               Skip automatic Homebrew dependency check
  --no-docutils             Do not install docutils (no man page)
  --buildtype=<type>        Meson build type (release, debug, debugoptimized) [default: release]
  --deployment-target=<ver> MACOSX_DEPLOYMENT_TARGET to build for (default: host macOS version)
  --mpv-meson-args="<args>" Extra Meson flags for mpv
  --libplacebo-meson-args="<args>"
                            Extra Meson flags for libplacebo
  -j<N>, --jobs=<N>         Parallel compiler jobs for Ninja (default: all cores)

RUNTIME WIRING (VapourSynth / mpv.app):
  --no-vss-app-env          Do not write VSSCRIPT_PATH into mpv.app's Info.plist
  --vss-launchctl           Also set VSSCRIPT_PATH in the launchd session (persistent
                            LaunchAgent), for apps that ignore LSEnvironment
  --no-vss-launchctl        Do not touch launchd (default)
  --fix-vapoursynth-toml    Repair ~/.config/vapoursynth/vapoursynth.toml entries whose
                            Python framework path no longer exists (e.g. after a
                            Homebrew python upgrade). Writes a .bak when it changes
                            anything.

VERIFICATION:
  --no-verify               Skip the post-build functional verification
  --verify-only=<prefix>    Skip building; verify an existing prefix (e.g.
                            ~/.config/mpv/custom-build-latest/custom_prefix)
  -h, --help                Show this help message and exit

EXAMPLES:
  # Run with defaults configured at the top of the script:
  ./build-mpv-custom.sh

  # Build dev master HEAD with rubberband enabled:
  ./build-mpv-custom.sh --dev --rubberband

  # Build a specific mpv commit:
  ./build-mpv-custom.sh --mpv-ref=6c092d9

  # Re-check an existing build without recompiling:
  ./build-mpv-custom.sh --verify-only=~/.config/mpv/custom-build-latest/custom_prefix
EOF
}

# ==============================================================================
# CLI Argument Parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)
            MPV_MODE="stable"; LIBPLACEBO_DEV=false ;;
        --dev)
            MPV_MODE="dev"; LIBPLACEBO_DEV=true ;;
        --stable)
            MPV_MODE="stable"; LIBPLACEBO_DEV=false ;;
        --mpv-mode=*)
            MPV_MODE="${1#*=}" ;;
        --mpv-mode)
            shift; MPV_MODE="$1" ;;
        --mpv-dev)
            MPV_MODE="dev" ;;
        --mpv-stable)
            MPV_MODE="stable" ;;
        --mpv-ref=*)
            MPV_CUSTOM_REF="${1#*=}" ;;
        --mpv-ref)
            shift; MPV_CUSTOM_REF="$1" ;;
        --libplacebo-dev)
            LIBPLACEBO_DEV=true ;;
        --libplacebo-stable)
            LIBPLACEBO_DEV=false ;;
        --libplacebo-ref=*)
            LIBPLACEBO_CUSTOM_REF="${1#*=}" ;;
        --libplacebo-ref)
            shift; LIBPLACEBO_CUSTOM_REF="$1" ;;
        --vapoursynth)
            ENABLE_VAPOURSYNTH=true ;;
        --no-vapoursynth)
            ENABLE_VAPOURSYNTH=false ;;
        --vapoursynth-prefix=*)
            VAPOURSYNTH_PREFIX="${1#*=}"; ENABLE_VAPOURSYNTH=true ;;
        --vapoursynth-prefix)
            shift; VAPOURSYNTH_PREFIX="$1"; ENABLE_VAPOURSYNTH=true ;;
        --rubberband)
            ENABLE_RUBBERBAND=true ;;
        --js|--javascript)
            ENABLE_JS=true ;;
        --lua51)
            LUA_FLAVOR="lua51" ;;
        --luajit)
            LUA_FLAVOR="luajit" ;;
        --libmpv)
            ENABLE_LIBMPV=true ;;
        --caca)
            ENABLE_CACA=true ;;
        --sixel)
            ENABLE_SIXEL=true ;;
        --demos)
            ENABLE_DEMOS=true ;;
        --metal)
            ENABLE_METAL=true ;;
        --no-metal)
            ENABLE_METAL=false ;;
        --no-itm-patch)
            PATCH_ITM=false ;;
        --skip-brew)
            SKIP_BREW=true ;;
        --no-docutils)
            ENABLE_DOCUTILS=false ;;
        --no-verify)
            VERIFY=false ;;
        --verify-only=*)
            VERIFY_ONLY_DIR="${1#*=}" ;;
        --verify-only)
            shift; VERIFY_ONLY_DIR="$1" ;;
        --no-vss-app-env)
            VSS_APP_ENV=false ;;
        --vss-launchctl)
            VSS_LAUNCHCTL=true ;;
        --no-vss-launchctl)
            VSS_LAUNCHCTL=false ;;
        --fix-vapoursynth-toml)
            FIX_VS_TOML=true ;;
        --buildtype=*)
            BUILD_TYPE="${1#*=}" ;;
        --buildtype)
            shift; BUILD_TYPE="$1" ;;
        --deployment-target=*)
            MACOSX_DEPLOYMENT_TARGET="${1#*=}" ;;
        --deployment-target)
            shift; MACOSX_DEPLOYMENT_TARGET="$1" ;;
        --mpv-meson-args=*)
            EXTRA_MPV_MESON_ARGS="${1#*=}" ;;
        --mpv-meson-args)
            shift; EXTRA_MPV_MESON_ARGS="$1" ;;
        --libplacebo-meson-args=*)
            EXTRA_LIBPLACEBO_MESON_ARGS="${1#*=}" ;;
        --libplacebo-meson-args)
            shift; EXTRA_LIBPLACEBO_MESON_ARGS="$1" ;;
        -j*)
            JOBS="${1#-j}" ;;
        --jobs=*)
            JOBS="${1#*=}" ;;
        --jobs)
            shift; JOBS="$1" ;;
        --help|-h)
            show_help
            exit 0 ;;
        *)
            echo "Unknown option: $1 (run with --help for options)"
            exit 1 ;;
    esac
    shift
done

# ==============================================================================
# Normalize the switches, then sanity-check the combinations
# ==============================================================================
# The values below are compared against the literal "true", so they are
# normalized to exactly true/false once, here. Otherwise `ENABLE_CACA=yes` (or
# =1) would silently mean "disabled" -- and the original code, which ran the
# value as a command, would execute /usr/bin/yes and hang the build forever.
normalize_bool() {  # normalize_bool <varname>
    local name="$1" value="${!1}"
    case "$value" in
        true|yes|1|on)   printf -v "$name" '%s' true ;;
        false|no|0|off)  printf -v "$name" '%s' false ;;
        *) echo "Invalid value for $name: '$value' (use true/false, yes/no, 1/0, on/off)"
           exit 1 ;;
    esac
}

normalize_tristate() {  # normalize_tristate <varname>; allows auto/true/false
    local name="$1" value="${!1}"
    case "$value" in
        auto)            printf -v "$name" '%s' auto ;;
        true|yes|1|on)   printf -v "$name" '%s' true ;;
        false|no|0|off)  printf -v "$name" '%s' false ;;
        *) echo "Invalid value for $name: '$value' (use auto, true or false)"
           exit 1 ;;
    esac
}

for _bool in PATCH_ITM ENABLE_BLURAY ENABLE_DVD ENABLE_VULKAN ENABLE_LUA \
             ENABLE_LCMS2 ENABLE_LIBARCHIVE ENABLE_UCHARDET ENABLE_ZIMG \
             BUILD_CPLAYER BUILD_BUNDLE ENABLE_RUBBERBAND ENABLE_JS ENABLE_LIBMPV \
             ENABLE_CACA ENABLE_SIXEL ENABLE_DEMOS SKIP_BREW ENABLE_DOCUTILS \
             VERIFY VSS_APP_ENV VSS_LAUNCHCTL FIX_VS_TOML LIBPLACEBO_DEV \
             ENABLE_METAL; do
    normalize_bool "$_bool"
done
unset _bool

normalize_tristate ENABLE_VAPOURSYNTH
for _tri in ENABLE_SWIFT ENABLE_MACOS_MEDIA_PLAYER ENABLE_MACOS_TOUCHBAR; do
    normalize_tristate "$_tri"
done
unset _tri

# Preflight: every enabled patch must exist, so a missing patches/ directory is
# caught now and not after a long build.
PATCH_DIR="${PATCH_DIR:-${SCRIPT_PATH%/*}/patches}"
_need_patch() {
    if [ ! -f "$PATCH_DIR/$1" ]; then
        echo "!!! Missing patch file: $PATCH_DIR/$1"
        echo "!!! Keep the patches/ directory next to this script, set PATCH_DIR=<dir>,"
        echo "!!! or disable the patch (see --help)."
        exit 1
    fi
}
if [ "$PATCH_ITM" = "true" ]; then _need_patch libplacebo/lp-0001-itm-desaturation.patch; fi
if [ "$ENABLE_METAL" = "true" ]; then
    _need_patch libplacebo/lp-0002-metal-gpu-timer.patch
    _need_patch mpv/mpv-0001-coreaudio-channel-map.patch
    _need_patch mpv/mpv-0002-metal-backend-context.patch
fi
_need_patch libplacebo/lp-0003-python314-utils-gen.patch
unset -f _need_patch


case "$LUA_FLAVOR" in
    lua51|luajit) ;;
    *) echo "Invalid LUA_FLAVOR '$LUA_FLAVOR' (use lua51 or luajit; mpv 0.41 rejects Lua >= 5.3)"; exit 1 ;;
esac

case "$MPV_MODE" in
    stable|dev) ;;
    auto) MPV_MODE="stable" ;;
    *) echo "Invalid MPV_MODE '$MPV_MODE' (use stable or dev)"; exit 1 ;;
esac

if [ "$BUILD_BUNDLE" = "true" ] && [ "$BUILD_CPLAYER" != "true" ]; then
    echo "!!! BUILD_BUNDLE=true requires BUILD_CPLAYER=true: the .app wraps the cplayer binary."
    echo "!!! Either build the cplayer (default) or pass --no-bundle (BUILD_BUNDLE=false)."
    exit 1
fi

# ==============================================================================
# Toolchain: deployment target
# ==============================================================================
if [ -z "$MACOSX_DEPLOYMENT_TARGET" ]; then
    MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion 2>/dev/null || true)"
fi
if [ -n "$MACOSX_DEPLOYMENT_TARGET" ]; then
    export MACOSX_DEPLOYMENT_TARGET
fi

# ==============================================================================
# VapourSynth capability probe
# ==============================================================================
# Locates the runtime VSScript library that mpv dlopen()s.
VS_HEADER=""
VS_INC=""
VS_VER=""
VS_SCRIPT_PC=""
VSSCRIPT_DYLIB=""

# Resolved once here and reused for the dependency list and PKG_CONFIG_PATH;
# an empty value means Homebrew is missing, which is reported before any work.
BREW_PREFIX=""
if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
fi

vs_find() {  # vs_find <root> <filename> -> first match or empty
    [ -d "$1" ] || return 0
    find "$1" -name "$2" 2>/dev/null | head -n 1 || true
}

probe_vapoursynth() {
    local c vsopt
    if [ -n "$VAPOURSYNTH_PREFIX" ]; then
        VS_HEADER="$(vs_find "$VAPOURSYNTH_PREFIX" 'VapourSynth4.h')"
        VS_SCRIPT_PC="$(vs_find "$VAPOURSYNTH_PREFIX" 'vapoursynth-script.pc')"
        for c in "$VAPOURSYNTH_PREFIX/lib/libvsscript.dylib" \
                 "$VAPOURSYNTH_PREFIX/lib/libvapoursynth-script.dylib" \
                 "$VAPOURSYNTH_PREFIX/libexec/libvsscript.dylib"; do
            [ -f "$c" ] && { VSSCRIPT_DYLIB="$c"; break; }
        done
        [ -n "$VSSCRIPT_DYLIB" ] || VSSCRIPT_DYLIB="$(vs_find "$VAPOURSYNTH_PREFIX" 'libvsscript.dylib')"
    fi
    if [ -z "$VS_HEADER" ] && [ -n "$BREW_PREFIX" ]; then
        vsopt="$BREW_PREFIX/opt/vapoursynth"
        if [ -d "$vsopt" ]; then
            VS_HEADER="$(vs_find "$vsopt" 'VapourSynth4.h')"
            [ -n "$VS_SCRIPT_PC" ] || VS_SCRIPT_PC="$(vs_find "$vsopt" 'vapoursynth-script.pc')"
            if [ -z "$VSSCRIPT_DYLIB" ]; then
                for c in "$vsopt/lib/libvsscript.dylib" "$vsopt/lib/libvapoursynth-script.dylib"; do
                    [ -f "$c" ] && { VSSCRIPT_DYLIB="$c"; break; }
                done
            fi
        fi
    fi
}

probe_vapoursynth

# "auto" means: build the bridge when headers are actually available.
if [ "$ENABLE_VAPOURSYNTH" = "auto" ]; then
    if [ -n "$VS_HEADER" ]; then
        ENABLE_VAPOURSYNTH=true
    else
        ENABLE_VAPOURSYNTH=false
    fi
fi

# ==============================================================================
# Version & Label Resolution
# ==============================================================================
MPV_MODE_REASON=""
if [ -n "$MPV_CUSTOM_REF" ]; then
    MPV_REF="$MPV_CUSTOM_REF"
    MPV_LABEL="custom-${MPV_REF}"
elif [ "$ENABLE_METAL" = "true" ]; then
    # Pinned last working commit that compiles cleanly with the ab300819/libplacebo metal fork
    MPV_REF="19901208db46f8a9b9d402f168b6c5ce8ed95637"
    MPV_LABEL="metal"
    MPV_MODE_REASON="pinned working commit for libplacebo metal fork"
elif [ "$MPV_MODE" = "dev" ]; then
    MPV_REF="master"
    MPV_LABEL="dev"
    MPV_MODE_REASON="explicitly requested"
else
    MPV_REF="v0.42.0"
    MPV_LABEL="stable"
    MPV_MODE_REASON="stable release (v0.42.0)"
fi

if [ -n "$LIBPLACEBO_CUSTOM_REF" ]; then
    LIBPLACEBO_REF="$LIBPLACEBO_CUSTOM_REF"
    LIBPLACEBO_REPO="https://code.videolan.org/videolan/libplacebo.git"
    LP_LABEL="custom-${LIBPLACEBO_REF}"
elif [ "$ENABLE_METAL" = "true" ]; then
    LIBPLACEBO_REPO="https://github.com/ab300819/libplacebo.git"
    # Fork branch was renamed metal-backend -> metal-absorb; pinned to its tip commit
    # so future renames/force-pushes can't break the clone.
    LIBPLACEBO_REF="ba3cd3da6e8a7210c543ede69c8a68f5cf37ecc2"
    LP_LABEL="metal"
elif [ "$LIBPLACEBO_DEV" = "true" ]; then
    LIBPLACEBO_REPO="https://code.videolan.org/videolan/libplacebo.git"
    LIBPLACEBO_REF="master"
    LP_LABEL="dev"
else
    LIBPLACEBO_REPO="https://code.videolan.org/videolan/libplacebo.git"
    LIBPLACEBO_REF="v7.360.1"
    LP_LABEL="stable"
fi

BUILD_LABEL="mpv${MPV_LABEL}-lp${LP_LABEL}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ROOT="$HOME/.config/mpv/custom-build-${TIMESTAMP}-${BUILD_LABEL}"
LOG="$ROOT/build.log"
PREFIX="$ROOT/custom_prefix"

# ------------------------------------------------------------------------------
# --verify-only: run the verification against an existing prefix and stop.
# ------------------------------------------------------------------------------
if [ -n "$VERIFY_ONLY_DIR" ]; then
    case "$VERIFY_ONLY_DIR" in
        '~'/*) VERIFY_ONLY_DIR="$HOME/${VERIFY_ONLY_DIR#\~/}" ;;
    esac
    VERIFY_ONLY_DIR="$(cd "$VERIFY_ONLY_DIR" 2>/dev/null && pwd || true)"
    if [ -z "$VERIFY_ONLY_DIR" ] || [ ! -d "$VERIFY_ONLY_DIR" ]; then
        echo "!!! --verify-only: directory not found"
        exit 1
    fi
fi

# --verify-only must not create a build directory or a build log.
if [ -z "$VERIFY_ONLY_DIR" ]; then
    mkdir -p "$ROOT" "$PREFIX"
    # Mirror all terminal output live into build.log
    exec > >(tee -a "$LOG") 2>&1
fi

fail() {
    echo ""
    echo "================================================================="
    echo "!!! BUILD FAILED at: $1"
    if [ -f "$LOG" ]; then
        echo "!!! Full log is saved at: $LOG"
    fi
    # The one failure that is easy to hit by picking a different mpv ref: mpv
    # v0.41.x needs vapoursynth-script.pc, which VapourSynth R74+ removed.
    if [ -f "$LOG" ] && tail -n 40 "$LOG" 2>/dev/null | grep -q 'vapoursynth-script'; then
        echo "!!! Hint: this mpv ref requires vapoursynth-script.pc (VapourSynth < R74)."
        echo "!!!       Use --mpv-dev/--auto (mpv master), or --no-vapoursynth."
    fi
    echo "================================================================="
    exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

# ==============================================================================
# Post-build verification
# ==============================================================================
# Functional checks, not just "does the file exist": Lua scripting really runs a
# script, the VapourSynth bridge really initialises VSScript, the bundle really
# carries our libplacebo, and the app bundle really exposes VSSCRIPT_PATH to a
# LaunchServices (Finder/Dock) launch.
VERIFY_FAIL=0
VERIFY_WARN=0

verify_ok()   { printf '    [ OK ] %s\n' "$1"; }
verify_warn() { printf '    [WARN] %s\n' "$1"; VERIFY_WARN=$((VERIFY_WARN + 1)); }
verify_fail() { printf '    [FAIL] %s\n' "$1"; VERIFY_FAIL=$((VERIFY_FAIL + 1)); }
verify_note() { printf '    [note] %s\n' "$1"; }

feature_present() {
    case " ${FEATURES:-} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Run a command for at most <seconds>, capturing stdout+stderr into <file>.
# macOS has no coreutils `timeout` by default, so use a watchdog subshell and
# then `wait` on the real child (which also avoids zombie/`kill -0` races).
run_capture() {  # run_capture <seconds> <outfile> <cmd...>
    local secs="$1" outfile="$2"
    shift 2
    local pid wd rc=0
    "$@" > "$outfile" 2>&1 &
    pid=$!
    ( sleep "$secs"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true ) &
    wd=$!
    wait "$pid" 2>/dev/null || rc=$?
    # Kill only the watchdog subshell: killing its `sleep` too makes bash report
    # "Terminated: 15 sleep ..." for the job, and the leftover sleep is harmless.
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    return "$rc"
}

expect_feature() {  # expect_feature <meson feature key> <description>
    if feature_present "$1"; then
        verify_ok "$2 ($1)"
    else
        verify_fail "$2 ($1) MISSING from the build"
    fi
}

verify_build() {
    local MPV_BIN="$PREFIX/bin/mpv"
    local APP_BUNDLE="$PREFIX/mpv.app"
    local APP_BIN="$APP_BUNDLE/Contents/MacOS/mpv"
    local PROBE_BIN="" out="" rc=0 lpver="" expect_hash=""
    local VERIFY_DIR run_out vpy src lua_probe tmpcfg log bad soft seen vserr
    local bundle_lps need_jit before_pids pid

    VERIFY_DIR="${TMPDIR:-/tmp}"
    VERIFY_DIR="${VERIFY_DIR%/}/mpv-custom-verify.$$"
    mkdir -p "$VERIFY_DIR"
    run_out="$VERIFY_DIR/run.log"

    echo ""
    echo "================================================================="
    echo "==> POST-BUILD VERIFICATION"
    echo "================================================================="

    # --- artifacts ------------------------------------------------------------
    echo "==> Artifacts"
    if [ "$BUILD_CPLAYER" != "false" ]; then
        if [ -x "$MPV_BIN" ]; then
            verify_ok "cplayer binary: $MPV_BIN"
        else
            verify_fail "cplayer binary missing: $MPV_BIN"
        fi
    fi
    if [ "$BUILD_BUNDLE" != "false" ]; then
        if [ -x "$APP_BIN" ]; then
            verify_ok "app bundle: $APP_BUNDLE"
        else
            verify_fail "app bundle missing: $APP_BUNDLE"
        fi
    fi

    if [ -x "$MPV_BIN" ]; then
        PROBE_BIN="$MPV_BIN"
    elif [ -x "$APP_BIN" ]; then
        PROBE_BIN="$APP_BIN"
    else
        verify_fail "no mpv binary available to verify"
        return 1
    fi

    # --- enabled features -----------------------------------------------------
    echo "==> Compiled-in features"
    run_capture 8 "$run_out" "$PROBE_BIN" --no-config --idle --msg-level=all=v \
        --no-input-terminal
    out="$(cat "$run_out")"
    FEATURES="$(printf '%s\n' "$out" | sed -n 's/.*List of enabled features: //p')"
    if [ -n "$FEATURES" ]; then
        verify_note "enabled features: $FEATURES"
    else
        verify_warn "could not read the feature list from mpv"
    fi

    if [ "$ENABLE_LUA" = "true" ]; then
        # mpv reports the pkg-config `Name:` for lua51 builds and `luajit` for
        # LuaJIT builds; accept anything that identifies a Lua runtime.
        case " ${FEATURES:-} " in
            *" lua "*|*" Lua "*|*" lua51 "*|*" lua5.1 "*|*" lua-5.1 "*|*" lua52 "*|*" lua5.2 "*|*" lua-5.2 "*|*" luajit "*)
                verify_ok "Lua scripting compiled in" ;;
            *)
                verify_fail "Lua scripting not in the feature list" ;;
        esac
    fi
    [ "$ENABLE_BLURAY" = "true" ]    && expect_feature libbluray "Blu-ray playback"
    [ "$ENABLE_DVD" = "true" ]       && expect_feature dvdnav    "DVD navigation"
    [ "$ENABLE_DVD" = "true" ]       && expect_feature dvda      "DVD-Audio"
    # No vapoursynth assertion here: the VapourSynth section below proves it
    # twice (--vf=help and a real .vpy run), which is stronger and clearer.
    [ "$ENABLE_VULKAN" = "true" ]    && expect_feature vulkan    "Vulkan rendering"
    [ "$ENABLE_LCMS2" = "true" ]     && expect_feature lcms2     "LittleCMS2 color management"
    [ "$ENABLE_LIBARCHIVE" = "true" ] && expect_feature libarchive "libarchive (.zip etc.)"
    [ "$ENABLE_UCHARDET" = "true" ]  && expect_feature uchardet  "uchardet subtitle charset detection"
    [ "$ENABLE_ZIMG" = "true" ]      && expect_feature zimg      "zimg scaler"
    [ "$ENABLE_RUBBERBAND" = "true" ] && expect_feature rubberband "librubberband"
    [ "$ENABLE_JS" = "true" ]        && expect_feature javascript "MuJS JavaScript"
    [ "$ENABLE_CACA" = "true" ]      && expect_feature caca      "libcaca output"
    [ "$ENABLE_SIXEL" = "true" ]     && expect_feature sixel     "Sixel output"
    # These are 'auto' by default, so a missing one is a warning, not a failure.
    if [ "$ENABLE_SWIFT" != "false" ]; then
        feature_present swift && verify_ok "Swift macOS integration (swift)" \
            || verify_warn "Swift macOS integration (swift) not enabled"
    fi
    if [ "$ENABLE_MACOS_MEDIA_PLAYER" != "false" ]; then
        feature_present macos-media-player && verify_ok "macOS media player integration" \
            || verify_warn "macOS media player integration not enabled"
    fi
    if [ "$ENABLE_MACOS_TOUCHBAR" != "false" ]; then
        feature_present macos-touchbar && verify_ok "macOS Touch Bar support" \
            || verify_warn "macOS Touch Bar support not enabled"
    fi

    if [ "$ENABLE_BLURAY" = "true" ] || [ "$ENABLE_DVD" = "true" ]; then
        out="$("$PROBE_BIN" --no-config --list-protocols 2>/dev/null || true)"
        if [ "$ENABLE_BLURAY" = "true" ]; then
            printf '%s\n' "$out" | grep -q '^ bluray://' \
                && verify_ok "bluray:// protocol registered" \
                || verify_fail "bluray:// protocol NOT registered"
        fi
        if [ "$ENABLE_DVD" = "true" ]; then
            printf '%s\n' "$out" | grep -q '^ dvdnav://' \
                && verify_ok "dvd://, dvdnav:// and dvda:// protocols registered" \
                || verify_fail "dvd:// protocol NOT registered"
        fi
    fi

    if [ "$ENABLE_VULKAN" = "true" ]; then
        out="$("$PROBE_BIN" --no-config --gpu-api=help 2>&1 || true)"
        printf '%s\n' "$out" | grep -q '^  vulkan' \
            && verify_ok "gpu-api=vulkan available" \
            || verify_fail "gpu-api=vulkan NOT available"
    fi

    if [ "$ENABLE_METAL" = "true" ]; then
        out="$("$PROBE_BIN" --no-config --gpu-api=help 2>&1 || true)"
        printf '%s\n' "$out" | grep -q '^  metal' \
            && verify_ok "gpu-api=metal available" \
            || verify_fail "gpu-api=metal NOT available"
    fi

    # --- Lua: the scripts the user actually cares about -----------------------
    echo "==> Lua scripting (mpv user scripts)"
    if [ "$ENABLE_LUA" = "true" ]; then
        lua_probe="$VERIFY_DIR/lua_probe.lua"
        printf 'mp.msg.error("MPV_LUA_PROBE_OK")\nmp.commandv("quit")\n' > "$lua_probe"
        run_capture 15 "$run_out" "$PROBE_BIN" --no-config --idle --script="$lua_probe" \
            --msg-level=all=error --no-input-terminal
        out="$(cat "$run_out")"
        if printf '%s\n' "$out" | grep -q 'MPV_LUA_PROBE_OK'; then
            verify_ok "Lua engine runs --script files"
        else
            verify_fail "Lua engine did NOT run a script -> no user script can load"
        fi

        # Auto-loading from a config dir's scripts/ subdirectory (the mechanism
        # that picks up ~/.config/mpv/scripts/*.lua).
        tmpcfg="$VERIFY_DIR/probe-config"
        mkdir -p "$tmpcfg/scripts"
        printf 'mp.msg.error("MPV_AUTOLOAD_PROBE_OK")\nmp.commandv("quit")\n' \
            > "$tmpcfg/scripts/autoload_probe.lua"
        run_capture 15 "$run_out" "$PROBE_BIN" --config-dir="$tmpcfg" --idle \
            --msg-level=all=error --no-input-terminal
        out="$(cat "$run_out")"
        if printf '%s\n' "$out" | grep -q 'MPV_AUTOLOAD_PROBE_OK'; then
            verify_ok "scripts/ auto-loading works (config-dir/scripts/*.lua)"
        else
            verify_fail "scripts/ auto-loading is broken -> ~/.config/mpv/scripts is ignored"
        fi

        # Some mpv scripts need LuaJIT extensions (`ffi`, `goto`); those cannot
        # run on Lua 5.1.5. Detect it up front so the cause is obvious instead
        # of "my scripts just do nothing".
        if [ -d "$HOME/.config/mpv/scripts" ]; then
            need_jit="$(grep -rlE "require\(?['\"]ffi|require\(?['\"]jit[.'\"]|^[[:space:]]*goto[[:space:]]|::[a-zA-Z_][a-zA-Z0-9_]*::" \
                        "$HOME/.config/mpv/scripts" 2>/dev/null || true)"
            if [ -n "$need_jit" ] && [ "$LUA_FLAVOR" = "lua51" ]; then
                verify_fail "these scripts need LuaJIT (ffi/goto) and cannot run on Lua 5.1.5:"
                printf '%s\n' "$need_jit" | sed 's/^/           /'
                verify_note "build with --luajit (the default) to run them"
            elif [ -n "$need_jit" ]; then
                verify_ok "LuaJIT-only scripts found, and this build uses LuaJIT"
            fi
        fi

        # Now the real thing: run with the user's own config and report problems.
        if [ -d "$HOME/.config/mpv/scripts" ]; then
            run_capture 20 "$run_out" "$PROBE_BIN" --idle --vo=null --ao=null \
                --force-window=no --msg-level=all=info --no-input-terminal
            out="$(cat "$run_out")"
            bad="$(printf '%s\n' "$out" | grep -E "Lua error|Error loading script|Failed to load script|script error" || true)"
            soft="$(printf '%s\n' "$out" | grep -E "Can't load unknown script" || true)"
            if [ -n "$bad" ]; then
                verify_fail "some of your ~/.config/mpv/scripts failed to load:"
                printf '%s\n' "$bad" | sed 's/^/           /'
            elif [ -n "$soft" ]; then
                verify_warn "non-script file(s) in ~/.config/mpv/scripts are ignored by mpv:"
                printf '%s\n' "$soft" | sed 's/^/           /'
            else
                verify_ok "your ~/.config/mpv/scripts loaded without reported errors"
            fi
            seen="$(printf '%s\n' "$out" | sed -n 's/^\[\([a-zA-Z0-9_.-]*\)\].*/\1/p' | sort -u | tr '\n' ' ' || true)"
            [ -n "$seen" ] && verify_note "scripts that logged something: $seen"
        fi
    fi

    # --- VapourSynth ----------------------------------------------------------
    if [ "$ENABLE_VAPOURSYNTH" = "true" ]; then
        echo "==> VapourSynth"
        # NB: capture first, then grep. `mpv ... | grep -q` looks fine but with
        # `set -o pipefail` the early exit of `grep -q` SIGPIPEs mpv, so the
        # pipeline reports failure even on a match.
        out="$("$PROBE_BIN" --no-config --vf=help 2>&1 || true)"
        if printf '%s\n' "$out" | grep -q '^  vapoursynth'; then
            verify_ok "vapoursynth filter is compiled in (--vf=vapoursynth)"
        else
            verify_fail "vapoursynth filter is NOT in the binary"
        fi

        if [ -n "$VSSCRIPT_DYLIB" ] && [ -f "$VSSCRIPT_DYLIB" ]; then
            verify_note "VSScript runtime library: $VSSCRIPT_DYLIB"
        else
            verify_warn "could not locate libvsscript.dylib for runtime wiring"
        fi

        vpy="$VERIFY_DIR/probe.vpy"
        # mpv reads the clip from output node 0, so the script must call
        # set_output(); a bare `video_out = clip` variable is not enough.
        cat > "$vpy" << 'VPYEOF'
import vapoursynth as vs
core = vs.core
clip = video_in
clip = core.std.SetFrameProp(clip, prop="_MpvProbe", intval=1)
clip.set_output()
VPYEOF

        src=""
        if command -v ffmpeg >/dev/null 2>&1; then
            if ffmpeg -hide_banner -loglevel error -f lavfi \
                 -i "testsrc=size=128x128:rate=5:duration=1" \
                 -c:v libx264 -pix_fmt yuv420p "$VERIFY_DIR/probe_src.mkv" -y >/dev/null 2>&1; then
                [ -s "$VERIFY_DIR/probe_src.mkv" ] && src="$VERIFY_DIR/probe_src.mkv"
            fi
        fi
        [ -n "$src" ] || src="av://lavfi:testsrc=size=128x128:rate=5"

        rc=0
        if [ -n "$VSSCRIPT_DYLIB" ] && [ -f "$VSSCRIPT_DYLIB" ]; then
            run_capture 60 "$run_out" env -u DYLD_LIBRARY_PATH \
                VSSCRIPT_PATH="$VSSCRIPT_DYLIB" \
                "$PROBE_BIN" --no-config --vo=null --ao=null --frames=2 \
                --vf="vapoursynth=$vpy" --msg-level=all=info \
                --no-input-terminal "$src" || rc=$?
        else
            run_capture 60 "$run_out" env -u DYLD_LIBRARY_PATH \
                "$PROBE_BIN" --no-config --vo=null --ao=null --frames=2 \
                --vf="vapoursynth=$vpy" --msg-level=all=info \
                --no-input-terminal "$src" || rc=$?
        fi
        out="$(cat "$run_out")"
        if [ "$rc" -eq 0 ]; then
            verify_ok "VapourSynth bridge runs a real .vpy filter end to end"
        else
            vserr="$(printf '%s\n' "$out" | grep -iE 'vapoursynth|vsscript' | head -n 3 || true)"
            if printf '%s\n' "$out" | grep -q 'Failed to load VapourSynth VSScript library'; then
                verify_fail "VSScript library could not be loaded (runtime wiring)"
                printf '%s\n' "$vserr" | sed 's/^/           /'
                verify_note "fix: point VSSCRIPT_PATH at an existing libvsscript.dylib"
            elif printf '%s\n' "$out" | grep -q 'Failed to initialize VapourSynth VSScript library'; then
                verify_fail "VSScript loaded but could not initialise (VapourSynth/Python setup)"
                printf '%s\n' "$vserr" | sed 's/^/           /'
                verify_note "check ~/.config/vapoursynth/vapoursynth.toml: its libvsscript.dylib -> Python library path must exist"
                verify_note "re-run with --fix-vapoursynth-toml to repair stale Python framework paths"
            elif printf '%s\n' "$out" | grep -q "Creating filter 'vapoursynth' failed"; then
                verify_fail "the vapoursynth filter was compiled in but failed to initialise"
                printf '%s\n' "$vserr" | sed 's/^/           /'
            else
                verify_warn "VapourSynth bridge did not complete (rc=$rc)"
                printf '%s\n' "$vserr" | sed 's/^/           /'
            fi
        fi
    fi

    # --- libplacebo provenance ------------------------------------------------
    echo "==> libplacebo"
    out="$("$PROBE_BIN" --no-config --version 2>/dev/null || true)"
    lpver="$(printf '%s\n' "$out" | sed -n 's/^libplacebo version: //p')"
    expect_hash="$(printf '%s' "${LIBPLACEBO_COMMIT:-}" | cut -c1-9)"
    if [ -z "${LIBPLACEBO_COMMIT:-}" ]; then
        # --verify-only: the prefix may have been built with any ref.
        if [ -n "$lpver" ]; then
            verify_note "libplacebo version: $lpver (prefix built separately; exact ref not checked)"
        else
            verify_fail "could not read the libplacebo version"
        fi
    elif printf '%s' "$lpver" | grep -q "$expect_hash"; then
        verify_ok "libplacebo is this build's ($lpver)"
    elif [ -n "${LIBPLACEBO_REF:-}" ] && printf '%s' "$lpver" | grep -q "${LIBPLACEBO_REF#v}"; then
        verify_ok "libplacebo is this build's ($lpver)"
    elif [ -n "$lpver" ]; then
        verify_warn "libplacebo version '$lpver' does not obviously match ${LIBPLACEBO_REF:-this build}"
    else
        verify_fail "could not read the libplacebo version"
    fi
    if [ "$PATCH_ITM" = "true" ] && [ -n "${ITM_PATCH_STATUS:-}" ]; then
        verify_note "ITM patch status: $ITM_PATCH_STATUS"
    fi

    if [ -x "$MPV_BIN" ]; then
        out="$(otool -L "$MPV_BIN" 2>/dev/null | grep libplacebo || true)"
        if printf '%s\n' "$out" | grep -q "$PREFIX"; then
            verify_ok "cplayer links this build's libplacebo"
        elif [ -n "$out" ]; then
            verify_warn "cplayer links a libplacebo outside this prefix: $out"
        else
            verify_warn "cplayer does not link libplacebo dynamically"
        fi
    fi

    if [ -x "$APP_BIN" ]; then
        out="$(otool -L "$APP_BIN" 2>/dev/null | grep libplacebo || true)"
        if printf '%s\n' "$out" | grep -q '@executable_path/lib/libplacebo'; then
            verify_ok "app bundle links its own bundled libplacebo"
        elif [ -n "$out" ]; then
            verify_warn "app bundle libplacebo link looks unexpected: $out"
        else
            verify_warn "app bundle does not link libplacebo dynamically"
        fi

        bundle_lps=( "$APP_BUNDLE"/Contents/MacOS/lib/libplacebo.*.dylib )
        if [ -f "${bundle_lps[0]}" ]; then
            verify_ok "app bundle contains $(basename "${bundle_lps[0]}")"
            out="$("$APP_BIN" --no-config --version 2>/dev/null | sed -n 's/^libplacebo version: //p')"
            if [ -n "$out" ] && [ "$out" = "$lpver" ]; then
                verify_ok "app bundle reports the same libplacebo as the cplayer ($out)"
            else
                verify_warn "app bundle libplacebo version '$out' differs from cplayer '$lpver'"
            fi
        else
            verify_fail "app bundle has no libplacebo dylib of its own"
        fi

        # LSEnvironment: the only way mpv.app sees VSSCRIPT_PATH from Finder/Dock.
        if [ "$ENABLE_VAPOURSYNTH" = "true" ] && [ "$VSS_APP_ENV" = "true" ]; then
            echo "==> mpv.app runtime environment (Finder/Dock launches)"
            out="$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:VSSCRIPT_PATH' \
                      "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
            if [ -n "$out" ]; then
                verify_ok "Info.plist LSEnvironment.VSSCRIPT_PATH=$out"
            else
                verify_warn "Info.plist has no LSEnvironment.VSSCRIPT_PATH"
            fi

            # Ask the app itself what it sees. The caller's environment is
            # scrubbed so that LSEnvironment is the only possible source, which
            # is exactly the Finder/Dock situation.
            log="$VERIFY_DIR/app_env.log"
            lua_probe="$VERIFY_DIR/app_env_probe.lua"
            cat > "$lua_probe" << 'LUAEOF'
local v = os.getenv("VSSCRIPT_PATH")
mp.msg.error("ENV_PROBE VSSCRIPT_PATH=[" .. tostring(v) .. "]")
mp.commandv("quit")
LUAEOF
            rm -f "$log"
            # Remember which instances already exist so we only ever kill the
            # one this probe starts, never an mpv you are already using.
            before_pids="$(pgrep -f "$APP_BUNDLE/Contents/MacOS/mpv" 2>/dev/null | tr '\n' ' ' || true)"
            env -u VSSCRIPT_PATH -u DYLD_LIBRARY_PATH \
                open -n -a "$APP_BUNDLE" --args --no-config --idle --no-input-terminal \
                --script="$lua_probe" --log-file="$log" --msg-level=all=error \
                >/dev/null 2>&1 || true
            local waited=0
            while [ "$waited" -lt 40 ]; do
                grep -q 'ENV_PROBE' "$log" 2>/dev/null && break
                sleep 0.25
                waited=$((waited + 1))
            done
            # Don't leave an idle instance behind if the probe never ran.
            for pid in $(pgrep -f "$APP_BUNDLE/Contents/MacOS/mpv" 2>/dev/null || true); do
                case " $before_pids " in
                    *" $pid "*) ;;
                    *) kill -TERM "$pid" 2>/dev/null || true ;;
                esac
            done
            out="$(sed -n 's/.*ENV_PROBE VSSCRIPT_PATH=\[\(.*\)\]/\1/p' "$log" 2>/dev/null || true)"
            if [ -n "$VSSCRIPT_DYLIB" ] && [ "$out" = "$VSSCRIPT_DYLIB" ]; then
                verify_ok "mpv.app really sees VSSCRIPT_PATH via LaunchServices (Finder/Dock)"
            elif [ -n "$out" ] && [ "$out" != "nil" ]; then
                verify_warn "mpv.app sees VSSCRIPT_PATH='$out' instead of '$VSSCRIPT_DYLIB'"
                verify_note "a launchd-wide VSSCRIPT_PATH (launchctl setenv) is overriding the bundle's LSEnvironment"
            else
                verify_warn "mpv.app did not inherit LSEnvironment.VSSCRIPT_PATH; use --vss-launchctl"
            fi
        fi
    fi

    if [ "$ENABLE_LIBMPV" = "true" ]; then
        echo "==> libmpv"
        if [ -f "$PREFIX/lib/libmpv.dylib" ] || [ -f "$PREFIX/lib/libmpv.2.dylib" ]; then
            verify_ok "libmpv.dylib present"
        else
            verify_fail "libmpv.dylib missing"
        fi
    fi

    echo ""
    if [ "$VERIFY_FAIL" -gt 0 ]; then
        echo "==> VERIFICATION FAILED: $VERIFY_FAIL failure(s), $VERIFY_WARN warning(s)"
    elif [ "$VERIFY_WARN" -gt 0 ]; then
        echo "==> VERIFICATION PASSED with $VERIFY_WARN warning(s)"
    else
        echo "==> VERIFICATION PASSED: every check succeeded"
    fi
    echo "==> Raw probe output (mpv logs) kept in: $VERIFY_DIR"
    echo ""

    [ "$VERIFY_FAIL" -eq 0 ]
}

# ------------------------------------------------------------------------------
# --verify-only short-circuit
# ------------------------------------------------------------------------------
if [ -n "$VERIFY_ONLY_DIR" ]; then
    PREFIX="$VERIFY_ONLY_DIR"
    trap - ERR
    set +e
    verify_build
    rc=$?
    echo "==> Prefix:            $PREFIX"
    echo "==> Verified without building."
    exit "$rc"
fi

echo "================================================================="
echo "==> CUSTOM MPV & LIBPLACEBO COMPILATION"
echo "================================================================="
echo "==> Destination:   $ROOT"
echo "==> Prefix:        $PREFIX"
echo "==> Log file:      $LOG"
echo "==> mpv ref:       $MPV_REF ($MPV_LABEL)"
echo "==>   chosen by:   $MPV_MODE_REASON"
echo "==> libplacebo:    $LIBPLACEBO_REF ($LP_LABEL)"
echo "==> Deployment tgt: ${MACOSX_DEPLOYMENT_TARGET:-<toolchain default>}"
echo "==> Configured Features:"
echo "      ITM Patch:        $PATCH_ITM"
echo "      Blu-ray:          $ENABLE_BLURAY"
echo "      DVD:              $ENABLE_DVD"
echo "      VapourSynth:      $ENABLE_VAPOURSYNTH${VAPOURSYNTH_PREFIX:+ ($VAPOURSYNTH_PREFIX)}"
if [ "$ENABLE_VAPOURSYNTH" = "true" ]; then
    echo "      VS headers:       ${VS_HEADER:-<not found>}"
    echo "      VS VSScript lib:  ${VSSCRIPT_DYLIB:-<not found>}"
    echo "      VS script.pc:     ${VS_SCRIPT_PC:-<absent, R74+>}"
    echo "      App VS env:       $VSS_APP_ENV (LSEnvironment)  launchctl: $VSS_LAUNCHCTL"
fi
echo "      Vulkan:           $ENABLE_VULKAN"
echo "      Lua:              $LUA_FLAVOR"
echo "      LCMS2:            $ENABLE_LCMS2"
echo "      libarchive:       $ENABLE_LIBARCHIVE"
echo "      uchardet:         $ENABLE_UCHARDET"
echo "      zimg:             $ENABLE_ZIMG"
echo "      rubberband:       $ENABLE_RUBBERBAND"
echo "      JavaScript:       $ENABLE_JS"
echo "      libmpv dylib:     $ENABLE_LIBMPV"
echo "      App Bundle:       $BUILD_BUNDLE"
echo "      cplayer binary:   $BUILD_CPLAYER"
echo "================================================================="
echo ""

cd "$ROOT"

# ==============================================================================
# Homebrew Dependencies
# ==============================================================================
if ! [ "$SKIP_BREW" != "true" ]; then
    echo "==> Checking and installing build dependencies via Homebrew..."
    BREW_DEPS=(
        meson ninja pkg-config cmake python
        ffmpeg libass freetype harfbuzz fribidi
        jpeg-turbo
    )
    # nasm is only used for x86 assembly; Apple Silicon builds never invoke it.
    if [ "$(uname -m)" = "x86_64" ]; then
        BREW_DEPS+=(nasm)
    fi

    if [ "$ENABLE_VULKAN" = "true" ]; then
        BREW_DEPS+=(vulkan-headers vulkan-loader molten-vk shaderc spirv-cross glslang)
    fi
    if [ "$ENABLE_BLURAY" = "true" ]; then
        BREW_DEPS+=(libbluray)
    fi
    if [ "$ENABLE_DVD" = "true" ]; then
        BREW_DEPS+=(libdvdnav libdvdread libdvdcss)
    fi
    if [ "$ENABLE_VAPOURSYNTH" = "true" ] && [ -z "$VAPOURSYNTH_PREFIX" ]; then
        BREW_DEPS+=(vapoursynth)
    fi
    if [ "$ENABLE_LUA" = "true" ]; then
        if [ "$LUA_FLAVOR" = "luajit" ]; then BREW_DEPS+=(luajit); fi
    fi
    if [ "$ENABLE_LCMS2" = "true" ]; then
        BREW_DEPS+=(little-cms2)
    fi
    if [ "$ENABLE_LIBARCHIVE" = "true" ]; then
        BREW_DEPS+=(libarchive)
    fi
    if [ "$ENABLE_UCHARDET" = "true" ]; then
        BREW_DEPS+=(uchardet)
    fi
    if [ "$ENABLE_RUBBERBAND" = "true" ]; then
        BREW_DEPS+=(rubberband)
    fi
    if [ "$ENABLE_ZIMG" = "true" ]; then
        BREW_DEPS+=(zimg)
    fi
    if [ "$ENABLE_CACA" = "true" ]; then
        BREW_DEPS+=(libcaca)
    fi
    if [ "$ENABLE_SIXEL" = "true" ]; then
        BREW_DEPS+=(libsixel)
    fi
    if [ "$ENABLE_JS" = "true" ]; then
        BREW_DEPS+=(mujs)
    fi
    if [ "$ENABLE_DOCUTILS" = "true" ] && ! command -v rst2man >/dev/null 2>&1; then
        BREW_DEPS+=(docutils)   # provides rst2man, so mpv builds its man page
    fi

    # Don't auto-update brew or upgrade your other outdated formulae mid-build.
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
    export HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1

    MISSING_DEPS=()
    for dep in "${BREW_DEPS[@]}"; do
        brew list --formula "$dep" &>/dev/null || MISSING_DEPS+=("$dep")
    done
    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        echo "    Installing missing: ${MISSING_DEPS[*]}"
        brew install "${MISSING_DEPS[@]}"
    else
        echo "    All ${#BREW_DEPS[@]} dependencies already installed."
    fi
else
    echo "==> Skipping Homebrew installation check (--skip-brew specified)."
fi

# ==============================================================================
# PKG_CONFIG_PATH Setup
# ==============================================================================
if [ -z "$BREW_PREFIX" ]; then
    echo "Homebrew not found in PATH (needed for the build dependencies)"
    exit 1
fi
mkdir -p "${PREFIX}/lib/pkgconfig"   # must exist so our libplacebo/lua win over brew copies
PKG_CONFIG_DIRS=(
    "${PREFIX}/lib/pkgconfig"
    "${PREFIX}/share/pkgconfig"
    "${BREW_PREFIX}/opt/ffmpeg-full/lib/pkgconfig"
    "${BREW_PREFIX}/lib/pkgconfig"
    "${BREW_PREFIX}/share/pkgconfig"
    "${BREW_PREFIX}/opt/libarchive/lib/pkgconfig"
    "${BREW_PREFIX}/opt/jpeg-turbo/lib/pkgconfig"
    "${BREW_PREFIX}/opt/little-cms2/lib/pkgconfig"
    "${BREW_PREFIX}/opt/vapoursynth/lib/pkgconfig"
    "${BREW_PREFIX}/opt/libdvdnav/lib/pkgconfig"
    "${BREW_PREFIX}/opt/libdvdread/lib/pkgconfig"
    "${BREW_PREFIX}/opt/libbluray/lib/pkgconfig"
    "${BREW_PREFIX}/opt/luajit/lib/pkgconfig"
    "${BREW_PREFIX}/opt/rubberband/lib/pkgconfig"
    "${BREW_PREFIX}/opt/mujs/lib/pkgconfig"
    "${BREW_PREFIX}/opt/zimg/lib/pkgconfig"
    "${BREW_PREFIX}/opt/uchardet/lib/pkgconfig"
    "${BREW_PREFIX}/opt/libsixel/lib/pkgconfig"
    "${BREW_PREFIX}/opt/libcaca/lib/pkgconfig"
)

EXISTING_PKG_DIRS=()
for dir in "${PKG_CONFIG_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    EXISTING_PKG_DIRS+=("$dir")
done
export PKG_CONFIG_PATH="$(IFS=:; printf '%s' "${EXISTING_PKG_DIRS[*]}")${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

# Custom VapourSynth bundle: mpv (master) only needs VapourSynth's headers at build time
# (VSScript is dlopen'ed at runtime). Generate a vapoursynth.pc pointing at your headers.
ITM_PATCH_STATUS="skipped"
if [ "$ENABLE_VAPOURSYNTH" = "true" ]; then
    if [ -z "$VS_HEADER" ]; then
        echo "!!! VapourSynth is enabled but no VapourSynth4.h was found."
        echo "!!! Set VAPOURSYNTH_PREFIX to your bundle, or pass --no-vapoursynth."
        exit 1
    fi
    VS_INC="$(dirname "$VS_HEADER")"
    VS_PC_FILE="$(vs_find "$VS_INC/.." 'vapoursynth.pc')"
    [ -n "$VS_PC_FILE" ] || VS_PC_FILE="$(vs_find "${VAPOURSYNTH_PREFIX:-/nonexistent}" 'vapoursynth.pc')"
    if [ -n "$VS_PC_FILE" ]; then
        VS_VER="$(sed -n 's/^Version:[[:space:]]*//p' "$VS_PC_FILE" 2>/dev/null | head -n 1 || true)"
    fi
    mkdir -p "$PREFIX/include"
    ln -sfn "$VS_INC" "$PREFIX/include/vapoursynth"   # supports both <VSScript4.h> and <vapoursynth/VSScript4.h>
    cat > "$PREFIX/lib/pkgconfig/vapoursynth.pc" << VSPC
prefix=$PREFIX
includedir=\${prefix}/include

Name: vapoursynth
Description: VapourSynth headers (from custom bundle)
Version: ${VS_VER:-77}
Cflags: -I\${includedir}/vapoursynth -I\${includedir}
VSPC
    # Pre-R74 VapourSynth ships vapoursynth-script.pc, which stable mpv also needs.
    # Expose it through our pkgconfig dir so the stable path can work too.
    if [ -n "$VS_SCRIPT_PC" ] && [ -f "$VS_SCRIPT_PC" ]; then
        cp -f "$VS_SCRIPT_PC" "$PREFIX/lib/pkgconfig/vapoursynth-script.pc"
        echo "==> VapourSynth script pc: $VS_SCRIPT_PC (exposed for stable mpv)"
    fi
    echo "==> VapourSynth headers: $VS_INC (version ${VS_VER:-unknown})"
fi

# mpv v0.41.0 hard-requires vapoursynth-script.pc, which VapourSynth R74+ removed.
# Support landed in mpv master only, so fail early instead of after the libplacebo
# build. Keyed on the resolved ref (not the label), so --mpv-ref=v0.41.0 is caught
# too; other strict refs are reported by the meson error + the hint in fail().
if [ "$ENABLE_VAPOURSYNTH" = "true" ] && [ "$MPV_REF" = "v0.41.0" ] \
   && ! pkg-config --exists vapoursynth-script; then
    echo "!!! The detected VapourSynth has no vapoursynth-script.pc (R74+), which mpv $MPV_REF requires."
    echo "!!! Use --mpv-dev (or --auto), or pass --no-vapoursynth."
    exit 1
fi

# ------------------------------------------------------------------------------
# VapourSynth runtime config repair (opt-in)
# ------------------------------------------------------------------------------
# vapoursynth.toml maps each libvsscript.dylib to [python-executable,
# python-library]. A Homebrew python upgrade moves the framework, so the entry
# keeps pointing at a path that no longer exists; the symptom is
# "Python library failed to load from ..." and every --vf=vapoursynth fails.
# This rewrites only entries whose python library is missing.
fix_vapoursynth_toml() {
    local toml="$HOME/.config/vapoursynth/vapoursynth.toml"
    local pyver="" pylib="" venv_py
    if [ ! -f "$toml" ]; then
        echo "==> --fix-vapoursynth-toml: $toml does not exist; nothing to repair."
        return 0
    fi
    if [ -n "$VAPOURSYNTH_PREFIX" ] && [ -x "$VAPOURSYNTH_PREFIX/venv/bin/python3" ]; then
        venv_py="$VAPOURSYNTH_PREFIX/venv/bin/python3"
    fi
    [ -n "$venv_py" ] && pyver="$("$venv_py" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)"
    [ -n "$pyver" ] || pyver="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)"
    [ -n "$pyver" ] && pylib="$(ls "${BREW_PREFIX:-/opt/homebrew}/Cellar/python@${pyver}"/*/Frameworks/Python.framework/Versions/"${pyver}"/Python 2>/dev/null | tail -n 1 || true)"
    [ -n "$pylib" ] || pylib="$(ls /Library/Frameworks/Python.framework/Versions/"${pyver}"/Python 2>/dev/null | tail -n 1 || true)"
    echo "==> Repairing $toml (python $pyver -> ${pylib:-<not found>})"
    python3 - "$toml" "$pylib" << 'PYEOF'
import os
import re
import shutil
import sys
import time

toml, newlib = sys.argv[1], sys.argv[2]
lines = open(toml).read().splitlines()
changes, out = [], []
for line in lines:
    m = re.match(r'^(\s*"([^"]+)"\s*=\s*)\[([^\]]*)\]\s*$', line)
    if m:
        key, inner = m.group(2), m.group(3)
        items = re.findall(r'"([^"]*)"', inner)
        if (len(items) >= 2 and "Python.framework" in items[1]
                and not os.path.exists(items[1]) and os.path.exists(newlib)):
            items[1] = newlib
            newline = m.group(1) + "[" + ", ".join('"%s"' % i for i in items) + "]"
            changes.append((key, newline))
            out.append(newline)
            continue
    out.append(line)

if not changes:
    print("    no stale Python framework paths found")
elif not newlib:
    print("    no usable replacement python library found; leaving the file alone")
else:
    bak = toml + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(toml, bak)
    open(toml, "w").write("\n".join(out) + "\n")
    print("    backup: " + bak)
    for key, newline in changes:
        print("    repaired: " + key)
        print("        -> " + newline)
PYEOF
}

if [ "$FIX_VS_TOML" = "true" ]; then
    fix_vapoursynth_toml
fi

# ------------------------------------------------------------------------------
# Patches live in $PATCH_DIR (default: patches/ next to this script):
#   patches/libplacebo/*.patch   applied inside the libplacebo checkout
#   patches/mpv/*.patch          applied inside the mpv checkout
# See patches/README.md. Override the location with PATCH_DIR=<dir>.
# ------------------------------------------------------------------------------
# apply_patch <repo-dir> <patch-file>
# Prints exactly one status line, for the caller to capture:
#   "applied cleanly" | "already applied" | "patch file missing: ..." |
#   "does not apply to this revision (upstream changed)" | "git apply failed"
# A patch is applied completely or not at all (checked first), and a patch that
# does not apply never aborts the build, same as the inline patchers it replaced.
apply_patch() {
    local dir="$1" patch="$2"
    if [ ! -f "$patch" ]; then
        echo "patch file missing: $patch"
    elif git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "already applied"
    elif git -C "$dir" apply --check "$patch" >/dev/null 2>&1; then
        if git -C "$dir" apply "$patch" >/dev/null 2>&1; then echo "applied cleanly"; else echo "git apply failed"; fi
    else
        echo "does not apply to this revision (upstream changed)"
    fi
}

# Clone <url> into <dir> at <ref>. Shallow for tags/branches; falls back to a
# shallow commit fetch for raw commit hashes, and finally full clone with retries.
clone_ref() {
    local url="$1" dir="$2" ref="$3"
    # 1. Try shallow clone by branch / tag
    if git clone --depth 1 --branch "$ref" --recurse-submodules --shallow-submodules "$url" "$dir" 2>/dev/null; then
        return 0
    fi
    rm -rf "$dir"

    # 2. Try shallow fetch of commit hash (fast, avoids downloading entire repo history)
    mkdir -p "$dir"
    if (
        cd "$dir" &&
        git init -q &&
        git remote add origin "$url" &&
        git fetch --depth 1 origin "$ref" &&
        git checkout -q FETCH_HEAD &&
        git submodule update --init --recursive
    ) 2>/dev/null; then
        return 0
    fi
    rm -rf "$dir"

    # 3. Fallback: full clone with retry loop
    local attempt=1 max_attempts=3
    while [ $attempt -le $max_attempts ]; do
        echo "    Clone attempt $attempt of $max_attempts..."
        if git clone --no-recurse-submodules "$url" "$dir"; then
            git -C "$dir" checkout "$ref"
            git -C "$dir" submodule update --init --recursive
            return 0
        fi
        rm -rf "$dir"
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

# ------------------------------------------------------------------------------
# 0. Lua 5.1 (mpv 0.41 needs Lua <= 5.2; Homebrew only ships 5.4+/5.5 now)
# ------------------------------------------------------------------------------
if [ "$ENABLE_LUA" = "true" ] && [ "$LUA_FLAVOR" = "lua51" ]; then
    echo ""
    echo "==> [0/2] Building Lua 5.1.5 from source..."
    curl -fL --retry 3 -o lua-5.1.5.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz
    tar xzf lua-5.1.5.tar.gz
    ( cd lua-5.1.5 \
      && make -C src all CC=cc MYCFLAGS="-O2 -DLUA_USE_POSIX -DLUA_USE_DLOPEN" \
      && make install INSTALL_TOP="$PREFIX" )
    cat > "$PREFIX/lib/pkgconfig/lua5.1.pc" << LUAPC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: Lua
Description: Lua 5.1.5 scripting language
Version: 5.1.5
Libs: -L\${libdir} -llua -lm
Cflags: -I\${includedir}
LUAPC
    ln -sf lua5.1.pc "$PREFIX/lib/pkgconfig/lua-5.1.pc"
    ln -sf lua5.1.pc "$PREFIX/lib/pkgconfig/lua51.pc"   # mpv looks up the -Dlua value verbatim as the pkg-config name
    # LuaJIT-free check: make sure pkg-config actually resolves what mpv will ask for.
    if pkg-config --exists lua51; then
        echo "    pkg-config resolves lua51 -> version $(pkg-config --modversion lua51)"
    else
        echo "!!! pkg-config cannot resolve lua51 after building Lua 5.1.5"
        exit 1
    fi
fi

# ==============================================================================
# 1. Build libplacebo
# ==============================================================================
echo ""
echo "==> [1/2] Cloning and configuring libplacebo (${LIBPLACEBO_REF})..."
clone_ref "$LIBPLACEBO_REPO" libplacebo "$LIBPLACEBO_REF"
cd libplacebo
LIBPLACEBO_COMMIT="$(git rev-parse HEAD)"
echo "    libplacebo commit: $LIBPLACEBO_COMMIT"

# ITM Desaturation Patch  ->  patches/libplacebo/lp-0001-itm-desaturation.patch
if [ "$PATCH_ITM" = "true" ]; then
    echo "==> Applying inverse-tone-mapping desaturation patch to libplacebo"
    ITM_PATCH_STATUS="$(apply_patch "$ROOT/libplacebo" "$PATCH_DIR/libplacebo/lp-0001-itm-desaturation.patch")"
    case "$ITM_PATCH_STATUS" in
        "applied cleanly")
            echo "    ITM patch applied cleanly." ;;
        "already applied")
            echo "    ITM patch is already applied." ;;
        *)
            echo "    !! NOTE: ITM patch not applied: $ITM_PATCH_STATUS"
            echo "    !! The built libplacebo is unpatched in that regard; the build continues."
            echo "    !! Pin libplacebo with --libplacebo-ref=v7.360.1 if you need the patch."
            ;;
    esac
else
    echo "==> Skipping ITM patch (PATCH_ITM=false)."
    ITM_PATCH_STATUS="disabled"
fi

# ------------------------------------------------------------------------------
# Metal GPU timer patch: replace the zero-returning CPU-fallback timestamps with
# native MTLCounterSampleBuffer queries so vo-passes shows real GPU timings.
# Applied unconditionally when the Metal backend is enabled.
#   -> patches/libplacebo/lp-0002-metal-gpu-timer.patch (gpu.h, gpu.cc, gpu_pass.cc;
#      applied all-or-nothing, since the three files depend on each other)
# ------------------------------------------------------------------------------
if [ "$ENABLE_METAL" = "true" ]; then
    echo "==> Applying Metal GPU timer (MTLCounterSampleBuffer) patch to libplacebo"
    echo "    Metal timer patch: $(apply_patch "$ROOT/libplacebo" "$PATCH_DIR/libplacebo/lp-0002-metal-gpu-timer.patch")"
fi

# Compatibility patch for Python 3.14+ in utils_gen.py  ->  patches/libplacebo/lp-0003-python314-utils-gen.patch
if [ -f "$ROOT/libplacebo/src/vulkan/utils_gen.py" ]; then
    echo "==> Patching src/vulkan/utils_gen.py for Python 3.14+ compatibility"
    echo "    $(apply_patch "$ROOT/libplacebo" "$PATCH_DIR/libplacebo/lp-0003-python314-utils-gen.patch")"
fi

# ------------------------------------------------------------------------------
# Meson flag helpers
# ------------------------------------------------------------------------------
# Every feature switch below is an on/off meson feature option. These helpers
# keep the argument list readable instead of repeating `if ... enabled/disabled`
# for ~30 options, and they take the normalized true/false values.
mpv_flag() {  # mpv_flag <meson-option> <true|false>
    if [ "$2" = "true" ]; then
        MPV_MESON_ARGS+=("-D$1=enabled")
    else
        MPV_MESON_ARGS+=("-D$1=disabled")
    fi
}

lp_flag() {   # lp_flag <meson-option> <true|false>
    if [ "$2" = "true" ]; then
        LP_MESON_ARGS+=("-D$1=enabled")
    else
        LP_MESON_ARGS+=("-D$1=disabled")
    fi
}

mpv_tristate() {  # mpv_tristate <meson-option> <auto|true|false>
    case "$2" in
        true)  MPV_MESON_ARGS+=("-D$1=enabled") ;;
        false) MPV_MESON_ARGS+=("-D$1=disabled") ;;
        *)     MPV_MESON_ARGS+=("-D$1=auto") ;;
    esac
}

# libplacebo meson configuration
LP_MESON_ARGS=(
    --prefix="$PREFIX"
    --buildtype="$BUILD_TYPE"
)
# `demos` is a *boolean* option in libplacebo, not a feature option, so it takes
# true/false rather than enabled/disabled.
LP_MESON_ARGS+=("-Ddemos=${ENABLE_DEMOS}")

lp_flag vulkan "$ENABLE_VULKAN"
lp_flag vk-proc-addr "$ENABLE_VULKAN"
lp_flag shaderc "$ENABLE_VULKAN"
lp_flag lcms "$ENABLE_LCMS2"
# `metal` only exists in the Metal fork; upstream libplacebo rejects the option
# entirely (even =disabled), so pass it only when Metal is enabled.
if [ "$ENABLE_METAL" = "true" ]; then
    lp_flag metal true
fi

if [ -n "$EXTRA_LIBPLACEBO_MESON_ARGS" ]; then
    eval "LP_MESON_ARGS+=($EXTRA_LIBPLACEBO_MESON_ARGS)"
fi

echo "==> Configuring libplacebo with meson..."
meson setup build "${LP_MESON_ARGS[@]}"

echo "==> Compiling & installing libplacebo..."
ninja ${JOBS:+-j "$JOBS"} -C build
ninja -C build install
cd "$ROOT"

# ==============================================================================
# 2. Build mpv
# ==============================================================================
echo ""
echo "==> [2/2] Cloning and configuring mpv (${MPV_REF})..."
clone_ref https://github.com/mpv-player/mpv.git mpv "$MPV_REF"
cd mpv
MPV_COMMIT="$(git rev-parse HEAD)"
echo "    mpv commit: $MPV_COMMIT"

COREAUDIO_PATCH_STATUS="skipped"
if [ "$ENABLE_METAL" = "true" ]; then
    # CoreAudio channel-map fix from upstream mpv (PR #15622 / commit 3dae21b1e).
    # Fixes CoreAudio initialization failure on macOS 15+ / 27 for the pinned Metal commit.
    echo "==> Applying upstream CoreAudio channel-map fix to mpv..."
    COREAUDIO_PATCH_STATUS="$(apply_patch "$ROOT/mpv" "$PATCH_DIR/mpv/mpv-0001-coreaudio-channel-map.patch")"
    case "$COREAUDIO_PATCH_STATUS" in
        "applied cleanly"|"already applied")
            echo "    CoreAudio fix: $COREAUDIO_PATCH_STATUS." ;;
        *)
            echo "    !! NOTE: CoreAudio fix not applied: $COREAUDIO_PATCH_STATUS" ;;
    esac

    # Native Apple Metal backend for mpv: new video/out/metal/{context.h,context_mac.m}
    # plus the meson.build / gpu/context.c / gpu_next/context.c wiring.
    #   -> patches/mpv/mpv-0002-metal-backend-context.patch (all-or-nothing)
    echo "==> Injecting and wiring native Apple Metal backend into mpv..."
    METAL_WIRING_STATUS="$(apply_patch "$ROOT/mpv" "$PATCH_DIR/mpv/mpv-0002-metal-backend-context.patch")"
    case "$METAL_WIRING_STATUS" in
        "applied cleanly"|"already applied")
            echo "    Metal backend wiring: $METAL_WIRING_STATUS." ;;
        *)
            echo "    !! WARNING: Metal backend wiring NOT applied: $METAL_WIRING_STATUS"
            echo "    !! mpv will build without the native Metal backend; the build continues."
            ;;
    esac
fi

# mpv meson configuration
MPV_MESON_ARGS=(
    --prefix="$PREFIX"
    --buildtype="$BUILD_TYPE"
)
# cplayer/libmpv are *boolean* options in mpv (not feature options), so they
# take true/false rather than enabled/disabled.
MPV_MESON_ARGS+=("-Dcplayer=${BUILD_CPLAYER}" "-Dlibmpv=${ENABLE_LIBMPV}")

# Blu-ray
mpv_flag libbluray "$ENABLE_BLURAY"

# DVD (dvda only exists in refs that still carry that option)
mpv_flag dvdnav "$ENABLE_DVD"
if grep -q "'dvda'" meson.options 2>/dev/null; then
    mpv_flag dvda "$ENABLE_DVD"
fi

# VapourSynth
mpv_flag vapoursynth "$ENABLE_VAPOURSYNTH"

# Lua: a combo option, not a feature option ("lua51" -> lua5.1.pc, "luajit" -> luajit.pc)
if [ "$ENABLE_LUA" = "true" ]; then
    MPV_MESON_ARGS+=("-Dlua=${LUA_FLAVOR}")
else
    MPV_MESON_ARGS+=("-Dlua=disabled")
fi

# JavaScript (MuJS)
mpv_flag javascript "$ENABLE_JS"

# Vulkan & shaders: spirv-cross stays on "auto" so a missing converter is not fatal
mpv_flag vulkan "$ENABLE_VULKAN"
if [ "$ENABLE_VULKAN" = "true" ]; then
    MPV_MESON_ARGS+=("-Dspirv-cross=auto")   # mpv only uses shaderc on win32 (-Dshaderc=enabled errors elsewhere)
else
    MPV_MESON_ARGS+=("-Dspirv-cross=disabled")
fi

# Scalers, formats & audio
mpv_flag zimg "$ENABLE_ZIMG"
mpv_flag lcms2 "$ENABLE_LCMS2"
mpv_flag libarchive "$ENABLE_LIBARCHIVE"
mpv_flag uchardet "$ENABLE_UCHARDET"
mpv_flag rubberband "$ENABLE_RUBBERBAND"
mpv_flag caca "$ENABLE_CACA"
mpv_flag sixel "$ENABLE_SIXEL"

# macOS integration ("auto" lets meson detect Xcode/Swift)
mpv_tristate swift-build "$ENABLE_SWIFT"
mpv_tristate macos-media-player "$ENABLE_MACOS_MEDIA_PLAYER"
mpv_tristate macos-touchbar "$ENABLE_MACOS_TOUCHBAR"

# Extra flags are intentionally shell-parsed, so quoted values like
# --foo="a b" survive as one argument.
if [ -n "$EXTRA_MPV_MESON_ARGS" ]; then
    eval "MPV_MESON_ARGS+=($EXTRA_MPV_MESON_ARGS)"
fi

echo "==> Configuring mpv with meson..."
meson setup build "${MPV_MESON_ARGS[@]}"

echo "==> Compiling & installing mpv..."
ninja ${JOBS:+-j "$JOBS"} -C build
ninja -C build install

# Make sure the installed binary can find our custom libplacebo at runtime
if [ "$BUILD_CPLAYER" = "true" ]; then
    MPV_BIN="$PREFIX/bin/mpv"
    if ! "$MPV_BIN" --version >/dev/null 2>&1; then
        echo "==> mpv can't load its libs; adding rpath $PREFIX/lib"
        # Capture instead of piping into `grep -q`: see the pipefail note below.
        MPV_LOAD_CMDS="$(otool -l "$MPV_BIN" 2>/dev/null || true)"
        case "$MPV_LOAD_CMDS" in
            *"path $PREFIX/lib "*) ;;
            *)
                install_name_tool -add_rpath "$PREFIX/lib" "$MPV_BIN"
                ;;
        esac
        codesign --force -s - "$MPV_BIN"
    fi
fi

# Build macOS application bundle if requested
APP_ENV_STATUS="not applicable"
if [ "$BUILD_BUNDLE" = "true" ]; then
    echo "==> Building mpv.app macOS bundle..."
    BUNDLE_TARGET="$(ninja -C build -t targets all | grep -oE '^(macos-bundle|mpv\.app)' | head -n 1 || true)"
    if [ -n "$BUNDLE_TARGET" ]; then
        ninja ${JOBS:+-j "$JOBS"} -C build "$BUNDLE_TARGET"
    elif [ -x TOOLS/osxbundle.py ]; then
        TOOLS/osxbundle.py -s build/mpv
    fi
    if [ -d build/mpv.app ]; then
        rm -rf "$PREFIX/mpv.app"
        cp -R build/mpv.app "$PREFIX/mpv.app"
        APP_BUNDLE="$PREFIX/mpv.app"
        echo "    mpv.app bundle placed at: $APP_BUNDLE"

        # Stray zero-byte placeholders make codesign print
        # "code object is not signed at all ... In subcomponent".
        find "$APP_BUNDLE" -name '.gitkeep' -delete 2>/dev/null || true

        # mpv's bundler (TOOLS/dylib_unhell.py) skips any library whose path
        # contains the binary's own name -- and our prefix lives under
        # ~/.config/mpv/, so libplacebo is never bundled and the .app would keep
        # an absolute reference into the build directory. Copy it in ourselves
        # and point the bundle at @executable_path/lib/.
        APP_BIN="$APP_BUNDLE/Contents/MacOS/mpv"
        BUNDLE_LIBDIR="$APP_BUNDLE/Contents/MacOS/lib"
        mkdir -p "$BUNDLE_LIBDIR"
        BUNDLED_PREFIX_LIBS=""
        APP_LINKS="$(otool -L "$APP_BIN" 2>/dev/null || true)"
        for lib in "$PREFIX"/lib/*.dylib; do
            [ -f "$lib" ] || continue
            base="$(basename "$lib")"
            case "$APP_LINKS" in
                *"$lib"*) ;;
                *) continue ;;
            esac
            cp -f "$lib" "$BUNDLE_LIBDIR/$base"
            install_name_tool -id "@executable_path/lib/$base" "$BUNDLE_LIBDIR/$base"
            install_name_tool -change "$lib" "@executable_path/lib/$base" "$APP_BIN"
            # Re-point this library's own dependencies at the bundle copies when
            # they are already there, so the app relies less on Homebrew paths.
            DEP_REFS="$(otool -L "$BUNDLE_LIBDIR/$base" 2>/dev/null | awk 'NR>1 {print $1}' || true)"
            while IFS= read -r dep; do
                [ -n "$dep" ] || continue
                dep_base="$(basename "$dep")"
                if [ -f "$BUNDLE_LIBDIR/$dep_base" ]; then
                    install_name_tool -change "$dep" "@executable_path/lib/$dep_base" \
                        "$BUNDLE_LIBDIR/$base" 2>/dev/null || true
                fi
            done <<< "$DEP_REFS"
            codesign --force -s - "$BUNDLE_LIBDIR/$base" >/dev/null 2>&1 || true
            BUNDLED_PREFIX_LIBS="$BUNDLED_PREFIX_LIBS $base"
            echo "    bundled $base -> @executable_path/lib/$base"
        done
        if [ -z "$BUNDLED_PREFIX_LIBS" ]; then
            echo "    note: no prefix libraries had to be copied into the bundle"
        fi

        PLIST="$APP_BUNDLE/Contents/Info.plist"
        PB=/usr/libexec/PlistBuddy
        if [ "$VSS_APP_ENV" = "true" ] && $ENABLE_VAPOURSYNTH \
           && [ -n "$VSSCRIPT_DYLIB" ] && [ -f "$VSSCRIPT_DYLIB" ]; then
            # Finder/Dock launches inherit no shell environment, so a plain
            # `export VSSCRIPT_PATH` in a terminal can never reach the .app.
            # LSEnvironment is LaunchServices' own mechanism for this. mpv's
            # bundler already puts MPVBUNDLE/MallocNanoZone there, so only our
            # own key may be replaced.
            "$PB" -c "Delete :LSEnvironment:VSSCRIPT_PATH" "$PLIST" >/dev/null 2>&1 || true
            if "$PB" -c "Add :LSEnvironment:VSSCRIPT_PATH string $VSSCRIPT_DYLIB" \
                    "$PLIST" >/dev/null 2>&1; then
                APP_ENV_STATUS="LSEnvironment.VSSCRIPT_PATH=$VSSCRIPT_DYLIB"
                echo "    mpv.app: VSSCRIPT_PATH=$VSSCRIPT_DYLIB (Info.plist LSEnvironment)"
            else
                APP_ENV_STATUS="failed to write LSEnvironment"
                echo "    !! Could not write LSEnvironment into $PLIST"
            fi
            # VAPOURSYNTH_EXTRA_PLUGIN_PATH — VS reads this when creating each
            # core instance (before any .vpy script runs) and auto-loads every
            # dylib in that directory that exports VapourSynthPluginInit2.
            # Must be in LSEnvironment for the same reason as VSSCRIPT_PATH:
            # Finder/Dock launches inherit no shell environment.
            VS_PLUGIN_DIR="$(cd "$(dirname "$VSSCRIPT_DYLIB")/../plugins" 2>/dev/null && pwd || echo "")"
            if [ -d "$VS_PLUGIN_DIR" ]; then
                "$PB" -c "Delete :LSEnvironment:VAPOURSYNTH_EXTRA_PLUGIN_PATH" "$PLIST" >/dev/null 2>&1 || true
                "$PB" -c "Add :LSEnvironment:VAPOURSYNTH_EXTRA_PLUGIN_PATH string $VS_PLUGIN_DIR" \
                    "$PLIST" >/dev/null 2>&1 \
                    && echo "    mpv.app: VAPOURSYNTH_EXTRA_PLUGIN_PATH=$VS_PLUGIN_DIR (Info.plist LSEnvironment)" \
                    || echo "    !! Could not write VAPOURSYNTH_EXTRA_PLUGIN_PATH into $PLIST"
            fi
            # NNEDI3_WEIGHTS — path to the nnedi3 weights file, required by
            # QTGMC/nnedi3. Same reason: must be in LSEnvironment.
            VS_WEIGHTS="$(dirname "$VS_PLUGIN_DIR")/weights/nnedi3_weights.bin"
            if [ -f "$VS_WEIGHTS" ]; then
                "$PB" -c "Delete :LSEnvironment:NNEDI3_WEIGHTS" "$PLIST" >/dev/null 2>&1 || true
                "$PB" -c "Add :LSEnvironment:NNEDI3_WEIGHTS string $VS_WEIGHTS" \
                    "$PLIST" >/dev/null 2>&1 \
                    && echo "    mpv.app: NNEDI3_WEIGHTS=$VS_WEIGHTS (Info.plist LSEnvironment)" \
                    || echo "    !! Could not write NNEDI3_WEIGHTS into $PLIST"
            fi
        fi

        # Info.plist / file removal invalidate the bundle signature; re-sign ad-hoc.
        if codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
            echo "    mpv.app re-signed (ad-hoc) after post-processing"
        else
            echo "    !! Warning: could not re-sign $APP_BUNDLE"
        fi
        codesign --verify "$APP_BUNDLE" >/dev/null 2>&1 \
            && echo "    mpv.app signature verifies" \
            || echo "    !! Warning: mpv.app signature does not verify"
        touch "$APP_BUNDLE"   # refresh the LaunchServices cache
    else
        echo "    !! Warning: build/mpv.app not found; check build output above."
    fi
fi

# Optional global launchd wiring (only needed if LaunchServices ignores LSEnvironment)
if [ "$ENABLE_VAPOURSYNTH" = "true" ] && [ "$VSS_LAUNCHCTL" = "true" ] \
   && [ -n "$VSSCRIPT_DYLIB" ] && [ -f "$VSSCRIPT_DYLIB" ]; then
    echo "==> Wiring VSSCRIPT_PATH into the launchd session (--vss-launchctl)"
    launchctl setenv VSSCRIPT_PATH "$VSSCRIPT_DYLIB" 2>/dev/null || true
    launchctl getenv VSSCRIPT_PATH >/dev/null 2>&1 \
        && echo "    launchctl VSSCRIPT_PATH=$(launchctl getenv VSSCRIPT_PATH 2>/dev/null)"
    AGENT_DIR="$HOME/Library/LaunchAgents"
    AGENT="$AGENT_DIR/io.mpv.vsscript-path.plist"
    mkdir -p "$AGENT_DIR"
    cat > "$AGENT" << AGENTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>io.mpv.vsscript-path</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/launchctl</string>
        <string>setenv</string>
        <string>VSSCRIPT_PATH</string>
        <string>$VSSCRIPT_DYLIB</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
AGENTEOF
    launchctl bootout "gui/$UID/io.mpv.vsscript-path" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$UID" "$AGENT" >/dev/null 2>&1 \
        || launchctl load -w "$AGENT" >/dev/null 2>&1 || true
    echo "    LaunchAgent installed: $AGENT (persists across reboots)"
fi

# ==============================================================================
# Verification
# ==============================================================================
trap - ERR
set +e
VERIFY_STATUS="skipped (--no-verify)"
if [ "$VERIFY" = "true" ]; then
    verify_build
    if [ "$VERIFY_FAIL" -gt 0 ]; then
        VERIFY_STATUS="FAILED ($VERIFY_FAIL failure(s), $VERIFY_WARN warning(s))"
    elif [ "$VERIFY_WARN" -gt 0 ]; then
        VERIFY_STATUS="passed with $VERIFY_WARN warning(s)"
    else
        VERIFY_STATUS="passed"
    fi
fi

# ==============================================================================
# Completion Summary
# ==============================================================================
echo ""
echo "================================================================="
if [ "$VERIFY_FAIL" -gt 0 ] && [ "$VERIFY" = "true" ]; then
    echo "==> BUILD COMPLETED, BUT VERIFICATION FAILED"
else
    echo "==> BUILD COMPLETED SUCCESSFULLY"
fi
echo "================================================================="
echo "==> Configuration:    ${BUILD_LABEL}"
echo "==> libplacebo ref:   ${LIBPLACEBO_COMMIT}"
echo "==> mpv ref:          ${MPV_COMMIT}"
echo "==> Verification:     ${VERIFY_STATUS}"
if [ "$PATCH_ITM" = "true" ]; then
    echo "==> ITM patch:        ${ITM_PATCH_STATUS}"
fi
if [ "$ENABLE_METAL" = "true" ]; then
    echo "==> CoreAudio fix:    ${COREAUDIO_PATCH_STATUS}"
fi
if [ "$ENABLE_LUA" = "true" ]; then
    case "$LUA_FLAVOR" in
        lua51)  echo "==> Lua:              Lua 5.1.5 built into the prefix" ;;
        luajit) echo "==> Lua:              LuaJIT (Homebrew)" ;;
    esac
fi
if [ "$BUILD_CPLAYER" = "true" ]; then
    echo "==> mpv binary:       ${PREFIX}/bin/mpv"
fi
if [ "$BUILD_BUNDLE" = "true" ] && [ -d "${PREFIX}/mpv.app" ]; then
    echo "==> mpv.app bundle:   ${PREFIX}/mpv.app"
fi
if [ "$ENABLE_LIBMPV" = "true" ]; then
    echo "==> libmpv dylib:     ${PREFIX}/lib/libmpv.dylib"
fi
echo "==> Prefix directory: ${PREFIX}"

if [ "$ENABLE_VAPOURSYNTH" = "true" ]; then
    echo ""
    echo "==> VapourSynth runtime wiring"
    echo "      VSScript library:  ${VSSCRIPT_DYLIB:-<not found>}"
    echo "      App bundle env:    ${APP_ENV_STATUS}"
    echo "      Terminal use:      export VSSCRIPT_PATH=\"${VSSCRIPT_DYLIB}\""
    echo "      Verify again with: ${SCRIPT_PATH} --verify-only=${PREFIX}"
    if [ "$VSS_LAUNCHCTL" = "true" ]; then
        echo "      To undo the launchd wiring:"
        echo "        launchctl unsetenv VSSCRIPT_PATH"
        echo "        launchctl bootout gui/\$UID/io.mpv.vsscript-path 2>/dev/null"
        echo "        rm -f ~/Library/LaunchAgents/io.mpv.vsscript-path.plist"
    fi
fi

echo "==> Elapsed:          $((SECONDS / 60))m $((SECONDS % 60))s"
echo "==> Full build log:   ${LOG}"
echo "================================================================="

if [ "$VERIFY" = "true" ] && [ "$VERIFY_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0