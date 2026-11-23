#!/usr/bin/env python3
import sys as _sys, shutil as _shutil, os as _os

# ── 1. Redirect __pycache__ to the central mpv cache dir ─────────────────────
_PYCACHE_DIR = _os.path.expanduser("~/.config/mpv/cache/.pycache")
_os.makedirs(_PYCACHE_DIR, exist_ok=True)
import importlib.util as _iutil

_orig_cache_from_source = _iutil.cache_from_source  # keep original

def _patched_cache_from_source(path, debug_override=None, optimization=None, source_hash=None):
    filename = _os.path.splitext(_os.path.basename(path))[0]
    tag = _sys.implementation.cache_tag
    suffix = ".pyc" if not optimization else f".opt-{optimization}.pyc"
    return _os.path.join(_PYCACHE_DIR, filename + "." + tag + suffix)

_iutil.cache_from_source = _patched_cache_from_source

# ── 2. Load bundled patched smartcut_lib with highest priority ────────────────
_script_dir = _os.path.dirname(_os.path.abspath(__file__))
_local_lib = _os.path.join(_script_dir, "smartcut_lib")
if _os.path.isdir(_local_lib):
    # Insert script dir so 'import smartcut_lib' resolves to our bundled copy
    if _script_dir not in _sys.path:
        _sys.path.insert(0, _script_dir)
    # Evict any cached 'smartcut' that doesn't point to our lib
    for _k in list(_sys.modules):
        if _k == "smartcut" or _k.startswith("smartcut."):
            del _sys.modules[_k]
    import smartcut_lib as _sc_pkg
    _sys.modules["smartcut"] = _sc_pkg
    for _sub in ("cut_video", "media_container", "media_utils", "nal_tools", "parse_h265", "misc_data"):
        _mod = _os.path.join(_local_lib, _sub + ".py")
        if _os.path.isfile(_mod):
            import importlib as _imp
            _m = _imp.import_module(f"smartcut_lib.{_sub}")
            _sys.modules[f"smartcut.{_sub}"] = _m

# ── 3. Fallback: pipx / system-installed smartcut for binary-only deps ────────
_sc_bin = _shutil.which("smartcut") or _os.path.expanduser("~/.local/bin/smartcut")
if _sc_bin and _os.path.isfile(_sc_bin):
    _venv = _os.path.dirname(_os.path.dirname(_os.path.realpath(_sc_bin)))
    _lib = _os.path.join(_venv, "lib")
    if _os.path.isdir(_lib):
        for _d in _os.listdir(_lib):
            _sp = _os.path.join(_lib, _d, "site-packages")
            if _os.path.isdir(_sp) and _sp not in _sys.path:
                _sys.path.append(_sp)  # append — our bundled copy takes priority
                break

from bisect import bisect_left
import argparse, glob, os, sys, shutil, tempfile, struct, subprocess, json, time, traceback
import numpy as np
from PIL import Image

_SC_API_AVAILABLE = False
_sc_import_err: Exception | None = None
from fractions import Fraction as _SCFrac
_EPSILON = _SCFrac(1, 1_000_000)  # < one frame, > float noise: pushes a cut end just past a frame's exact PTS

try:
    from smartcut.cut_video import (smart_cut as _sc_api, VideoSettings as _SCVideoSettings,
                                    AudioExportInfo as _SCAudioExportInfo,
                                    AudioExportSettings as _SCAudioExportSettings,
                                    VideoCutter as _SCVideoCutter,
                                    # Take the enums from cut_video, not media_utils: smartcut_lib
                                    # ends up with two copies of media_utils, and enum members from
                                    # the other copy are not recognised by the lib (it then silently
                                    # falls back to CRF 18).
                                    VideoExportMode as _SCMode, VideoExportQuality as _SCQuality)
    from smartcut.media_container import MediaContainer as _SCMediaContainer
    _SC_API_AVAILABLE = True
except Exception as _e:
    _sc_import_err = _e

def _find_bin(name, required=True):
    """Find a binary on PATH, falling back to common macOS/Homebrew locations.
    Returns None instead of raising when required=False."""
    path = shutil.which(name)
    if path:
        return path
    for prefix in ("/opt/homebrew/bin/", "/usr/local/bin/"):
        candidate = prefix + name
        if os.path.isfile(candidate):
            return candidate
    if not required:
        return None
    raise RuntimeError(
        f"Could not find '{name}' on PATH or in common locations. "
        f"Install it or add its directory to PATH."
    )


FFMPEG_BIN = _find_bin("ffmpeg")
FFPROBE_BIN = _find_bin("ffprobe")
MKVPROPEDIT_BIN = _find_bin("mkvpropedit", required=False)  # optional: brew install mkvtoolnix

# ============================== USER CONFIG ==============================
# Defaults. Any of these can be overridden in
#   ~/.config/mpv/script-opts/smartcut.conf
# (same names, lower-case, e.g. `gif_fps=15`) - see _load_conf() below.
# Values set in the .conf always win; these are the fallbacks.

# --- Smart Cut: how mpv's A/B marks become cut points ---
# "frames"    : use mpv's frame numbers (estimated-frame-number). If a frame
#               number lands more than FRAME_CHECK_TOLERANCE frames away from
#               mpv's own timestamp for that mark, it is ignored and the
#               timestamp is used instead (a warning is logged).
# "timestamp" : always use mpv's time-pos timestamps, snapped to the nearest
#               real frame. Never looks at frame numbers.
CUT_MARKS = "frames"
FRAME_CHECK_TOLERANCE = 1           # max allowed frame-number vs timestamp disagreement, in frames
# Timestamp mode only: frames added after the frame found at mark B's timestamp.
# mpv's time-pos reads behind the frame on screen, so 1 is the usual value.
# 0 = cut ends on the frame at the timestamp itself; use it if cuts end 1 frame late.
# Frame-number mode never adds any.
END_FRAME_OFFSET = 1

# --- After each Smart Cut ---
SELF_CHECK = True                   # verify the result: keyframe start, frame count, audio/video alignment
STRIP_STALE_TAGS = True             # remove the source file's leftover duration/frame-count/bitrate tags (needs mkvpropedit)

# --- Smart Cut: encoder for the re-encoded parts (the GOP-edge slivers, and the
# whole range when a cut sits inside a single GOP). Everything else is stream-copied.
# None = keep smartcut_lib's built-in "normal" setting: CRF 18 (22 for HEVC/AV1/VP9),
# x264/x265 at the encoder's default preset (medium), SVT-AV1 at preset 7.
SMARTCUT_CRF = None                 # 0-63, lower = better/bigger; applied as-is for every codec
SMARTCUT_PRESET = None              # x264/x265 preset name, ultrafast ... placebo
SMARTCUT_PRESET_AV1 = None          # AV1 preset: SVT-AV1 0-13 (lower = slower/better), libaom cpu-used 0-8

# --- Compress (plain full re-encode of the marked range, .compressed.mkv) ---
# Unlike Smart Cut (which stream-copies most of the range and only
# re-encodes only the sliver-thin GOP edges), Compress
# re-encodes the whole marked range at a normal delivery CRF/preset - much
# smaller output, same frame-accurate A/B cut, just not archival quality.
COMPRESS_CRF = 10
COMPRESS_PRESET = "slower"
COMPRESS_PRESET_AV1 = 4
COMPRESS_ENCODER = "libsvtav1"      # force this encoder for Compress mode regardless of source codec.
                                     # Set to None to match the source codec instead (same behavior as Smart Cut).
                                     # Options: "libx264", "libx265", "libsvtav1", "libvpx-vp9"

# --- Pan Smash (slit-scan/panorama composite, .panorama.png) ---
# Some BD/encode masters carry a genuine few-pixel-wide dark defect right
# at the left/right frame edges (crop/pad leftover from mastering, not a
# stitching artifact). Trim it off every frame before tracking or
# compositing so it never enters the pipeline. 4px is a conservative
# default; raise it if a defect is still visible after this fix.
EDGE_TRIM = 4
# If the total measured pan span (across every good frame) is at or below
# this many pixels, the shot is treated as static: only the anchor plus the
# first/last good frames get composited instead of every single frame.
# At this small a span the difference is visually meaningless, so this
# just saves the redundant paste work.
PAN_MINOR_PX = 12.0
# Otherwise (a real pan), a frame is only pasted onto the canvas if it has
# moved at least this many pixels from the last *pasted* frame. This skips
# near-duplicate in-between frames (the "overkill" merging) while still
# guaranteeing every bit of new content gets composited - canvas bounds are
# always computed from the full frame set regardless, and the existing
# nearest-column-fill safety net still patches any gap this leaves behind.
PAN_STEP_PX = 6.0
# PIL PNG compression level for the composited output: 0 (fastest, biggest)
# to 9 (slowest, smallest). This is lossless either way - just an
# encode-time/size tradeoff.
PNG_COMPRESS_LEVEL = 9

# --- GIF mode (.pan.gif) ---
GIF_FPS = 12
GIF_MAX_WIDTH = 960              # long-edge cap in px; 0/None = keep source width
GIF_COLORS = 256                 # palette size, 2-256 (256 = GIF's hard max)
GIF_DITHER = "sierra2_4a"        # ffmpeg paletteuse dither algo (bayer, sierra2, sierra2_4a, none, ...)
GIF_LOOP = 0                     # 0 = loop forever, -1 = no loop, N = loop N times
# Unlike pan_smash's frame extraction (a bare -pix_fmt conversion with no
# filtergraph, which needs a manual 16-235 -> 0-255 stretch - see
# load_stretched below), this path runs through an actual -filter_complex
# graph, which engages ffmpeg's normal color-aware range expansion on its
# own - same as regular playback. So the frames feeding palettegen here are
# most likely already full-range, and this stretch would double-expand them
# (crushed/oversaturated colors). Left here, OFF by default, in case a
# future source doesn't get auto-expanded and genuinely needs it - if a GIF
# ever comes out looking pale again, flip this on and compare.
GIF_LEVELS_STRETCH = False

# ===========================================================================

EPSILON = 1e-3  # internal tolerance (seconds), not a user option


def log(msg):
    print(msg, flush=True)


# ── Overrides from smartcut.conf ─────────────────────────────────────────────
_CONF_PATH = os.path.expanduser("~/.config/mpv/script-opts/smartcut.conf")
_CONF_OPTIONS = (
    "CUT_MARKS", "FRAME_CHECK_TOLERANCE", "END_FRAME_OFFSET", "SELF_CHECK", "STRIP_STALE_TAGS",
    "SMARTCUT_CRF", "SMARTCUT_PRESET", "SMARTCUT_PRESET_AV1",
    "COMPRESS_CRF", "COMPRESS_PRESET", "COMPRESS_PRESET_AV1", "COMPRESS_ENCODER",
    "EDGE_TRIM", "PAN_MINOR_PX", "PAN_STEP_PX", "PNG_COMPRESS_LEVEL",
    "GIF_FPS", "GIF_MAX_WIDTH", "GIF_COLORS", "GIF_DITHER", "GIF_LOOP",
    "GIF_LEVELS_STRETCH",
)
_CONF_NONE_OK = ("COMPRESS_ENCODER", "SMARTCUT_CRF", "SMARTCUT_PRESET", "SMARTCUT_PRESET_AV1")
                                                      # these accept "auto"/"none" -> None (keep the default)
_CONF_TYPES = {"SMARTCUT_CRF": int, "SMARTCUT_PRESET": str, "SMARTCUT_PRESET_AV1": int}  # defaults are None
_CONF_RANGES = {"SMARTCUT_CRF": (0, 63), "SMARTCUT_PRESET_AV1": (0, 13), "END_FRAME_OFFSET": (0, 5)}
_CONF_CHOICES = {
    "CUT_MARKS": ("frames", "timestamp"),
    "SMARTCUT_PRESET": ("ultrafast", "superfast", "veryfast", "faster", "fast",
                        "medium", "slow", "slower", "veryslow", "placebo"),
}


def _load_conf():
    """Apply `key=value` lines from smartcut.conf over the defaults above.
    Whole-line `#` comments only. Bad keys/values are logged and ignored."""
    try:
        with open(_CONF_PATH, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return  # no conf file: defaults apply
    g = globals()
    for n, line in enumerate(lines, 1):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, raw = line.partition("=")
        key, raw = key.strip(), raw.strip()
        name = key.upper()
        if name not in _CONF_OPTIONS:
            log(f"  [warn] smartcut.conf line {n}: unknown option '{key}' ignored")
            continue
        default = g[name]
        try:
            if name in _CONF_NONE_OK and raw.lower() in ("none", "auto"):
                value = None
            elif name in _CONF_TYPES:
                value = _CONF_TYPES[name](raw)
            elif isinstance(default, bool):
                if raw.lower() in ("yes", "true", "on", "1"):
                    value = True
                elif raw.lower() in ("no", "false", "off", "0"):
                    value = False
                else:
                    raise ValueError
            elif isinstance(default, int):
                value = int(raw)
            elif isinstance(default, float):
                value = float(raw)
            else:
                value = raw
            if isinstance(value, str) and name in _CONF_CHOICES:
                value = value.lower()
                if value not in _CONF_CHOICES[name]:
                    raise ValueError
            if value is not None and name in _CONF_RANGES and not _CONF_RANGES[name][0] <= value <= _CONF_RANGES[name][1]:
                raise ValueError
        except ValueError:
            log(f"  [warn] smartcut.conf line {n}: invalid value '{raw}' for '{key}' "
                f"(keeping {default!r})")
            continue
        g[name] = value


_load_conf()


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def run_live(cmd):
    """Like run(), but streams the child's combined stdout/stderr through our
    own stdout AS IT ARRIVES, instead of buffering silently until the process
    exits. Our stdout is already redirected to the log file smartcut.lua
    tails every second, so this is what actually makes ffmpeg's -stats line
    and smartcut's own progress output show up live instead of dumping all
    at once at the end (or only on failure).

    Splits on '\\r' as well as '\\n' since progress redraws (tqdm, ffmpeg
    -stats) use carriage returns rather than newlines - each redraw becomes
    its own log line rather than being swallowed until a real newline shows up.

    Returns (returncode, last_output_str) - last_output_str is the tail of
    output, for embedding in an error message on failure.
    """
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    tail = []
    buf = ""
    while True:
        chunk = proc.stdout.read(1024)
        if not chunk:
            break
        buf += chunk
        while True:
            nl, cr = buf.find("\n"), buf.find("\r")
            candidates = [i for i in (nl, cr) if i != -1]
            if not candidates:
                break
            idx = min(candidates)
            line, buf = buf[:idx], buf[idx + 1:]
            if line.strip():
                print(line, flush=True)
                tail.append(line)
                if len(tail) > 200:
                    tail.pop(0)
    if buf.strip():
        print(buf, flush=True)
        tail.append(buf)
    proc.wait()
    return proc.returncode, "\n".join(tail[-40:])


def ffprobe_json(args):
    r = run([FFPROBE_BIN, "-v", "error", "-of", "json"] + args)
    if r.returncode != 0: raise RuntimeError(f"ffprobe failed: {r.stderr.strip()}")
    return json.loads(r.stdout or "{}")


def probe_streams(input_path):
    data = ffprobe_json(["-show_entries", "stream=index,codec_type,codec_name,pix_fmt,profile,width,height,sample_rate,channels,channel_layout,color_primaries,color_trc,colorspace,color_range,avg_frame_rate,r_frame_rate", input_path])
    streams = data.get("streams", [])
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    audios = [s for s in streams if s.get("codec_type") == "audio"]
    subtitles = [s for s in streams if s.get("codec_type") == "subtitle"]
    if video is None: raise RuntimeError("No video stream found")
    return video, audios, subtitles


def get_pts_offset(input_path, video_index):
    """Raw container PTS of the video stream's first packet. mpv's time-pos
    (what start/end are given in) is rebased to 0 by default, but ffprobe's
    packet pts_time is not - BDMV .m2ts clips in particular often don't
    start at PTS 0. Subtract this offset from every ffprobe timestamp to
    line them up with mpv's clock."""
    r = run([FFPROBE_BIN, "-v", "error", "-show_entries", "format=start_time", "-of", "default=nk=1:nw=1", input_path])
    val = r.stdout.strip()
    try: return float(val) if val and val != "N/A" else 0.0
    except ValueError: return 0.0


def get_keyframes(input_path, t_from, t_to, video_index, offset=0.0):
    r = run([FFPROBE_BIN, "-v", "error", "-fflags", "+genpts", "-select_streams", str(video_index), "-show_entries", "packet=pts_time,flags", "-read_intervals", f"{max(0.0, t_from + offset):.6f}%{t_to + offset:.6f}", "-of", "csv=p=0", input_path])
    kfs = []
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line or "," not in line or "K" not in line.split(",")[1]:
            continue
        ts_str = line.split(",")[0]
        if ts_str == "N/A":
            continue
        try:
            pts = float(ts_str) - offset
            if pts >= 0.0:
                kfs.append(pts)
        except ValueError:
            continue
    return sorted(set(kfs))





def build_color_args(video):
    args = []
    for key, flag in (("color_primaries", "-color_primaries"), ("color_trc", "-color_trc"), ("colorspace", "-colorspace"), ("color_range", "-color_range")):
        val = video.get(key)
        if val and val not in ("unknown", "unspecified"): args += [flag, val]
    return args


FORCE_10BIT = True  # encode at 10-bit precision even from 8-bit sources: reduces
                     # banding/quantization error and is usually MORE compression-
                     # efficient at equal quality, not less. Set False to keep source bit depth as-is.

# Which encoders this actually applies to. libx264 is excluded by default -
# Homebrew's ffmpeg ships x264 built 8-bit-only (confirmed via
# `ffmpeg -h encoder=libx264`, no high10/bit-depth flag present), so forcing
# 10-bit there fails outright. libx265/libsvtav1/libvpx-vp9 all support
# 10-bit in their standard Homebrew builds. If you rebuild x264 with
# --bit-depth=10 (e.g. via the x264-10bit tap) add "libx264" to this set.
FORCE_10BIT_ENCODERS = {"libx265", "libsvtav1", "libvpx-vp9", "libx264"}

PIX_FMT_8_TO_10 = {
    "yuv420p": "yuv420p10le", "yuvj420p": "yuv420p10le",
    "yuv422p": "yuv422p10le", "yuvj422p": "yuv422p10le",
    "yuv444p": "yuv444p10le", "yuvj444p": "yuv444p10le",
}


def resolve_pix_fmt(video, encoder):
    fmt = video.get("pix_fmt", "yuv420p")
    if FORCE_10BIT and encoder in FORCE_10BIT_ENCODERS:
        fmt = PIX_FMT_8_TO_10.get(fmt, fmt)  # no-op if already 10/12-bit or an unrecognized format
    return fmt


def encode_video_args(video, crf, preset, av1_preset=COMPRESS_PRESET_AV1, force_encoder=None):
    codec = video.get("codec_name")
    encoder = force_encoder or {"h264": "libx264", "hevc": "libx265", "av1": "libsvtav1", "vp9": "libvpx-vp9",
                                 "mpeg2video": "mpeg2video", "mpeg4": "mpeg4"}.get(codec)
    if not encoder: raise RuntimeError(f"Unsupported codec '{codec}'.")
    args = ["-c:v", encoder, "-pix_fmt", resolve_pix_fmt(video, encoder)]
    if encoder in ("mpeg2video", "mpeg4"):
        args += ["-q:v", "2"]
    elif encoder == "libsvtav1":
        preset_val = str(av1_preset)
        args += ["-crf", str(crf), "-preset", preset_val]
    else:
        preset_val = preset or "fast"
        args += ["-crf", str(crf), "-preset", preset_val]
    args += build_color_args(video)
    return args


# Matroska has no codec tag for these raw/disc-native PCM variants, so
# stream-copying them into an .mkv fails outright ("No wav codec tag
# found..."). Transcode losslessly to a PCM flavor MKV does support instead.
MKV_INCOMPATIBLE_AUDIO = {"pcm_bluray": "pcm_s24le", "pcm_dvd": "pcm_s16le"}


def audio_codec_args(audio):
    if audio is None: return []
    replacement = MKV_INCOMPATIBLE_AUDIO.get(audio.get("codec_name"))
    return ["-c:a", replacement] if replacement else ["-c:a", "copy"]


# The external `smartcut` CLI (used by smart_cut() below) only ever passes
# audio through untouched - it has no re-encode path at all. So the same
# disc-native LPCM tracks that break stream-copy into .mkv (see
# MKV_INCOMPATIBLE_AUDIO above) make the smartcut binary itself fail
# outright, with no CLI flag to work around it. Fix: before handing the
# file to smartcut, pre-convert just those audio track(s) to FLAC via a
# plain ffmpeg remux with -c:v copy (video bytes untouched, so the
# GOP/keyframe timestamps smartcut relies on for bracketing stay
# identical). FLAC is lossless and universally mkv-safe, so smartcut can
# then passthru it normally.
MKV_PASSTHRU_BROKEN_AUDIO = {"pcm_bluray", "pcm_dvd"}

# Padding (seconds) on each side of the cut for the audio pre-conversion
# window. Needs to cover smartcut's own GOP bracketing (BD GOPs are ~0.5–2s).
# 15s is generous headroom without extracting unnecessary video.
AUDIO_PRECONVERT_PAD = 15.0


def preconvert_broken_audio_to_flac(input_path, tmpdir, start, end, audios=None,
                                    pad=AUDIO_PRECONVERT_PAD,
                                    start_frame=None, end_frame=None):
    """If input_path has any disc-native LPCM track that smartcut can't
    passthru into mkv, remux JUST the [start-pad, end+pad] window to a temp
    file with those tracks losslessly transcoded to FLAC, and return
    (tmp_path, adj_start, adj_end, adj_start_frame, adj_end_frame).
    Returns (input_path, start, end, start_frame, end_frame) for normal sources.

    When preconvert IS needed, frame numbers are always returned as None:
    the windowed temp file has fewer frames than the original, so mpv's
    frame numbers don't map to it without a complex offset calculation.
    The timestamp path (adj_start/adj_end) is used instead, which is correct.
    """
    if audios is None:
        _, audios, _ = probe_streams(input_path)

    if not any(a.get("codec_name") in MKV_PASSTHRU_BROKEN_AUDIO for a in audios):
        # No preconvert needed: original file goes straight to smartcut,
        # so mpv's frame numbers directly index into it. Pass them through.
        return input_path, start, end, start_frame, end_frame

    broken = sorted({a.get("codec_name") for a in audios if a.get("codec_name") in MKV_PASSTHRU_BROKEN_AUDIO})
    window_start = max(0.0, start - pad)
    window_dur = (end - window_start) + pad
    log(f"  [info] Disc-native LPCM audio detected ({', '.join(broken)}) — "
        f"pre-converting cut window to FLAC "
        f"({_format_ts(window_start)} → {_format_ts(window_start + window_dur)})...")

    tmp_path = os.path.join(tmpdir, "smartcut_flac_source.mkv")
    cmd = [FFMPEG_BIN, "-nostdin", "-y", "-loglevel", "error", "-stats",
           "-ss", f"{window_start:.6f}", "-i", input_path, "-t", f"{window_dur:.6f}",
           "-map", "0", "-map_metadata", "0",
           "-c:v", "copy", "-c:s", "copy"]
    for a_rel_idx, a in enumerate(audios):
        codec = "flac" if a.get("codec_name") in MKV_PASSTHRU_BROKEN_AUDIO else "copy"
        cmd += [f"-c:a:{a_rel_idx}", codec]
    cmd += [tmp_path]

    rc, tail = run_live(cmd)
    if rc != 0:
        raise RuntimeError(f"Audio pre-conversion to FLAC failed:\n{tail}")

    adj_start = start - window_start
    adj_end = end - window_start
    # Frame numbers from mpv index the ORIGINAL file; the temp file has fewer
    # frames (windowed subset). Use None to force timestamp mode for this path.
    return tmp_path, adj_start, adj_end, None, None




def count_frames_between(input_path, t_from, t_to, video_index, offset=0.0, margin=2.0):
    r = run([FFPROBE_BIN, "-v", "error", "-fflags", "+genpts", "-select_streams", str(video_index), "-show_entries", "packet=pts_time,flags", "-read_intervals", f"{max(0.0, t_from - margin + offset):.6f}%{t_to + margin + offset:.6f}", "-of", "csv=p=0", input_path])
    count = 0
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line: continue
        ts = line.split(",")[0]
        if ts == "N/A": continue
        try:
            val = float(ts) - offset
            if t_from - EPSILON <= val < t_to - EPSILON: count += 1
        except ValueError:
            continue
    return count




def make_segment_reencode(input_path, seek, t_start, t_end, video, audios, crf, preset, out_path, offset=0.0, av1_preset=COMPRESS_PRESET_AV1, force_encoder=None, subtitles=None):
    """Re-encode a segment. Used by compress_cut for full-range re-encoding, and smart_cut for GOP edge slivers.

    `audios` is a list of audio-stream dicts (from probe_streams). Pass an empty list or None to suppress audio.
    `subtitles` is a list of subtitle-stream dicts (from probe_streams). Pass an empty list or None to suppress subtitles.
    """
    dur = t_end - t_start
    if dur <= 0: return False
    fast_seek = seek + offset
    slow_seek = max(0.0, t_start - seek)
    cmd = [FFMPEG_BIN, "-nostdin", "-y", "-loglevel", "error", "-stats",
           "-fflags", "+genpts",
           "-ss", f"{fast_seek:.6f}", "-i", input_path]
    if slow_seek > EPSILON:
        cmd += ["-ss", f"{slow_seek:.6f}"]
    cmd += ["-t", f"{dur:.6f}", "-fps_mode", "passthrough",
            "-map", f"0:{video['index']}", "-map_chapters", "-1"] + encode_video_args(video, crf, preset, av1_preset, force_encoder) + ["-bf", "0"]
    expected = count_frames_between(input_path, t_start, t_end, video['index'], offset)
    if expected > 0: cmd += ["-frames:v", str(expected)]
    if audios:
        for a in audios:
            cmd += ["-map", f"0:{a['index']}?"] + audio_codec_args(a)
    else:
        cmd += ["-an"]
    if subtitles:
        for s in subtitles:
            cmd += ["-map", f"0:{s['index']}?", "-c:s", "copy"]
    else:
        cmd += ["-sn"]
    cmd += ["-avoid_negative_ts", "make_zero", out_path]
    rc, tail = run_live(cmd)
    if rc != 0: raise RuntimeError(f"Re-encode failed:\n{tail}")
    return True


def _format_duration(secs):
    """Format seconds into a human-readable duration string."""
    if secs < 60:
        return f"{secs:.1f}s"
    m, s = divmod(secs, 60)
    if m < 60:
        return f"{int(m)}m {s:.1f}s"
    h, m = divmod(int(m), 60)
    return f"{int(h)}h {int(m)}m {s:.0f}s"


def _format_size(nbytes):
    """Format byte count into human-readable size."""
    for unit in ("B", "KB", "MB", "GB"):
        if nbytes < 1024:
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TB"


def _format_ts(secs):
    """Format timestamp as MM:SS.mmm or HH:MM:SS.mmm."""
    h = int(secs // 3600)
    m = int((secs % 3600) // 60)
    s = secs % 60
    if h > 0:
        return f"{h}:{m:02d}:{s:06.3f}"
    return f"{m:02d}:{s:06.3f}"


def verify_cut(path, expected_frames):
    """Sanity-check a finished smart cut and log the result.
    Problems are logged as '[check] WARN ...' (main.lua shows an OSD hint)."""
    problems = []
    try:
        first = (ffprobe_json(["-select_streams", "v:0", "-read_intervals", "%+#1",
                               "-show_entries", "packet=flags", path]).get("packets") or [{}])[0]
        info = ffprobe_json(["-show_entries", "stream=index,codec_type,start_time,r_frame_rate:format=duration", path])
        streams, dur = info["streams"], float(info["format"]["duration"])
        v = next(s for s in streams if s["codec_type"] == "video")
        tol = 2 * float(1 / _SCFrac(v["r_frame_rate"]))  # audio packets are coarser than frames
        if "K" not in (first.get("flags") or ""):
            problems.append("first video packet is not a keyframe (some players show a gray/black start)")
        # (-count_packets reads the whole file; Matroska has no per-stream durations,
        # so stream ends come from the packets in the last 2 seconds.)
        n = int(ffprobe_json(["-select_streams", "v:0", "-count_packets", "-show_entries",
                              "stream=nb_read_packets", path])["streams"][0]["nb_read_packets"])
        if n != expected_frames:
            problems.append(f"{n} video frames, expected {expected_frames}")
        end = {}
        for pk in ffprobe_json(["-read_intervals", f"{max(dur - 2, 0)}%", "-show_entries",
                                "packet=stream_index,pts_time,duration_time", path]).get("packets", []):
            end[pk["stream_index"]] = max(end.get(pk["stream_index"], 0.0),
                                          float(pk["pts_time"]) + float(pk.get("duration_time") or 0))
        offsets = []
        for i, a in enumerate(s for s in streams if s["codec_type"] == "audio"):
            d_start = float(a["start_time"]) - float(v["start_time"])
            d_end = end[a["index"]] - end[v["index"]] if a["index"] in end and v["index"] in end else None
            offsets.append((d_start, d_end))
            if abs(d_start) > tol:
                problems.append(f"audio track {i + 1} starts {d_start * 1000:+.0f} ms vs video")
            if d_end is not None and abs(d_end) > tol:
                problems.append(f"audio track {i + 1} ends {d_end * 1000:+.0f} ms vs video")
    except Exception as e:
        log(f"  [check] skipped ({e})")
        return
    if problems:
        for msg in problems:
            log(f"  [check] WARN {msg}")
    else:
        sync = ""
        if offsets and offsets[0][1] is not None:
            sync = f", audio/video aligned (start {offsets[0][0] * 1000:+.0f} ms, end {offsets[0][1] * 1000:+.0f} ms)"
        log(f"  [check] OK  starts on a keyframe, {n} frames as expected{sync}")


def strip_stale_tags(path):
    """smartcut_lib copies the source's mkvmerge statistics tags (duration, frame
    count, bitrate, size of the WHOLE movie) into the clip, where they are wrong.
    mkvpropedit deletes them in place (header edit only; no remux, data untouched)."""
    if not MKVPROPEDIT_BIN:
        log("  [tags] stale source tags left in place (brew install mkvtoolnix to strip them)")
        return
    r = run([MKVPROPEDIT_BIN, path, "--delete-track-statistics-tags"])
    if r.returncode in (0, 1):
        log("  [tags] removed stale source statistics tags")
    else:
        log(f"  [tags] mkvpropedit failed (exit {r.returncode}); tags left in place")


def _install_seam_encoder_overrides():
    """Apply SMARTCUT_CRF / SMARTCUT_PRESET / SMARTCUT_PRESET_AV1 to the encoder
    smartcut_lib uses for re-encoded video, which the lib hardcodes. Wraps
    VideoCutter.init_encoder at runtime; smartcut_lib itself is not modified."""
    if not _SC_API_AVAILABLE:
        return
    _orig_init_encoder = _SCVideoCutter.init_encoder

    def init_encoder(self):
        _orig_init_encoder(self)
        opts, codec = self.encoding_options, self.codec_name or ""
        if SMARTCUT_CRF is not None:
            opts["crf"] = str(SMARTCUT_CRF)
        if "svtav1" in codec:
            if SMARTCUT_PRESET_AV1 is not None:
                opts["preset"] = str(SMARTCUT_PRESET_AV1)
        elif "aom" in codec:
            if SMARTCUT_PRESET_AV1 is not None:
                opts["cpu-used"] = str(SMARTCUT_PRESET_AV1)
        elif codec in ("h264", "hevc") and SMARTCUT_PRESET is not None:
            opts["preset"] = SMARTCUT_PRESET
        log(f"  [encode] re-encoded parts: {codec} crf {opts['crf']}, "
            f"preset {opts.get('preset', opts.get('cpu-used', 'encoder default'))}")

    _SCVideoCutter.init_encoder = init_encoder


_install_seam_encoder_overrides()


def smart_cut(input_path, start, end, output_path, start_frame=None, end_frame=None):
    """Frame-accurate smart cut using the bundled smartcut_lib (PyAV-based).

    Only the GOP-edge slivers are re-encoded (CRF/preset: see SMARTCUT_CRF /
    SMARTCUT_PRESET); everything between is stream-copied.

    start_frame / end_frame: 0-based frame indices from mpv's
    estimated-frame-number. Used only when CUT_MARKS = "frames" and they agree
    with the timestamps; otherwise the timestamps are used.
    """
    if end <= start: raise RuntimeError("end must be after start")
    if not _SC_API_AVAILABLE:
        raise RuntimeError(f"bundled smartcut_lib failed to import: {_sc_import_err}")
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)

    # --- Pre-cut diagnostics ---
    dur = end - start
    log(f"━━━ Smart Cut ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    video, audios, subtitles = probe_streams(input_path)
    try:
        codec = video.get("codec_name", "?").upper()
        w = video.get("width", "?")
        h = video.get("height", "?")
        fps_str = video.get("r_frame_rate") or video.get("avg_frame_rate") or "?"
        try:
            num, den = fps_str.split("/")
            fps_val = float(num) / float(den)
            fps_display = f"{fps_val:.3f}".rstrip("0").rstrip(".") + " fps"
        except Exception:
            fps_display = fps_str
        audio_info = f", {len(audios)} audio track{'s' if len(audios) != 1 else ''}" if audios else ", no audio"
        log(f"  Input:  {codec} {w}×{h} @ {fps_display}{audio_info}")
    except Exception:
        log(f"  Input:  {os.path.basename(input_path)}")

    log(f"  Range:  {_format_ts(start)} → {_format_ts(end)}  ({_format_duration(dur)})")

    # Analyse keyframes to describe the cut type
    try:
        offset = get_pts_offset(input_path, video['index'])
        kfs = get_keyframes(input_path, start - 5, end + 5, video['index'], offset)
        if kfs:
            kf_at_start = any(abs(k - start) < EPSILON for k in kfs)
            kf_at_end = any(abs(k - end) < EPSILON for k in kfs)
            kf_after_start = next((k for k in sorted(kfs) if k >= start - EPSILON), None)
            single_gop = kf_after_start is None or kf_after_start >= end - EPSILON

            if single_gop:
                log(f"  Type:   Single GOP — full re-encode (short cut within one keyframe interval)")
            elif kf_at_start and kf_at_end:
                log(f"  Type:   Keyframe-aligned — pure stream copy (fastest, lossless)")
            elif kf_at_start:
                log(f"  Type:   Start on keyframe, end mid-GOP — copy + re-encode tail")
            elif kf_at_end:
                log(f"  Type:   Start mid-GOP, end on keyframe — re-encode head + copy")
            else:
                log(f"  Type:   Both ends mid-GOP — re-encode head + copy + re-encode tail")
    except Exception:
        pass  # non-critical, skip if probing fails

    log(f"  Processing…")

    # --- Run smartcut ---
    tmpdir = tempfile.mkdtemp(prefix="smartcut_")
    try:
        # BD/DVD sources often carry disc-native LPCM (pcm_bluray/pcm_dvd),
        # which the smartcut binary can't passthru into .mkv at all (no
        # re-encode option of its own). Pre-convert just the cut window's
        # audio to FLAC first - no-op and returns (input_path, start, end)
        # unchanged for normal sources. For BD/DVD sources returns a temp
        # path with adjusted (0-based) start/end times.
        effective_input, eff_start, eff_end, eff_sf, eff_ef = preconvert_broken_audio_to_flac(
            input_path, tmpdir, start, end, audios,
            start_frame=start_frame, end_frame=end_frame)

        # CUT_MARKS = "frames": use mpv's frame numbers as the cut points
        # (checked against the timestamps further down). "timestamp": ignore them.
        use_frames = (CUT_MARKS == "frames"
                      and eff_sf is not None and eff_ef is not None
                      and eff_sf >= 0 and eff_ef > eff_sf)
        if use_frames:
            log(f"  [frames] Using frame-number mode: {eff_sf} → {eff_ef}")

        t0 = time.monotonic()

        try:
            _src = _SCMediaContainer(effective_input)
            try:
                _end_is_exact_frame = False  # True only when mpv's end frame number was accepted
                if use_frames:
                    _cand_start = _src.video_frame_times[min(eff_sf, len(_src.video_frame_times)-1)] - _src.start_time
                    _cand_end   = _src.video_frame_times[min(eff_ef, len(_src.video_frame_times)-1)] - _src.start_time
                    # Safety check: if a frame number is more than FRAME_CHECK_TOLERANCE
                    # frames away from mpv's timestamp for that mark, discard the frame
                    # numbers and trust the timestamps.
                    _ft = _src.video_frame_times
                    def _gap(i):  # duration of the frame at index i (seconds)
                        i = max(0, min(i, len(_ft) - 2))
                        return float(_ft[i + 1] - _ft[i])
                    _tol_s = max(_gap(eff_sf), _gap(eff_ef)) * FRAME_CHECK_TOLERANCE
                    if abs(float(_cand_start) - eff_start) > _tol_s + 1e-6 or abs(float(_cand_end) - eff_end) > _tol_s + 1e-6:
                        log(f"  [warn] Frame indices ({eff_sf}→{eff_ef}) disagree with timestamps ({eff_start:.3f}→{eff_end:.3f}s) by more than {FRAME_CHECK_TOLERANCE} frame. Using timestamps.")
                        _t_start = _SCFrac(eff_start).limit_denominator(1_000_000)
                        _t_end   = _SCFrac(eff_end).limit_denominator(1_000_000)
                    else:
                        _t_start = _cand_start
                        _t_end   = _cand_end
                        _end_is_exact_frame = True
                else:
                    _t_start = _SCFrac(eff_start).limit_denominator(1_000_000)
                    _t_end   = _SCFrac(eff_end).limit_denominator(1_000_000)

                # START: Frame-accurate cut. Snap to the exact frame at or after mark A.
                # If mark A is on a keyframe, smartcut remuxes with 0 re-encoding.
                # If mark A is mid-GOP, smartcut re-encodes only the tiny head seam at
                # the configured quality without dropping any user-selected content.
                _snap_start = _src.get_frame_time_at_or_after(_t_start)

                # END, frame-number mode: _t_end IS the exact frame the user marked, so
                # the cut ends right after it. No compensation.
                # END, timestamp mode: mpv's time-pos (and estimated-vpts) lags behind the
                # frame actually displayed on screen, so END_FRAME_OFFSET frames (default 1)
                # are added after the frame found at the timestamp.
                _last_frame = _src.get_frame_time_at_or_after(_t_end)
                if not _end_is_exact_frame:
                    for _ in range(END_FRAME_OFFSET):
                        _last_frame = _src.get_frame_time_at_or_after(_last_frame + _SCFrac(1, 1000))
                _snap_end = _last_frame + _EPSILON

                _head_ms = float(_snap_start - _t_start) * 1000
                _tail_ms = float(_snap_end - _EPSILON - _t_end) * 1000
                log(f"  [snap] start {float(_t_start):.4f}→{float(_snap_start):.4f}s "
                    f"({_head_ms:+.1f}ms)  "
                    f"end {float(_t_end):.4f}→{float(_snap_end - _EPSILON):.4f}s "
                    f"({_tail_ms:+.1f}ms)")

                _segs = [(_snap_start, _snap_end)]
                # Frames the output should contain: those with start <= pts < end.
                _expected_frames = (bisect_left(_src.video_frame_times, _snap_end)
                                    - bisect_left(_src.video_frame_times, _snap_start))


                _audio_settings = [_SCAudioExportSettings(codec='passthru')] * len(_src.audio_tracks)
                _export_info = _SCAudioExportInfo(output_tracks=_audio_settings)
                # NORMAL = the lib's CRF 18 (22 for HEVC/AV1/VP9) - what this script has
                # always actually produced. SMARTCUT_CRF / SMARTCUT_PRESET override it
                # (see _install_seam_encoder_overrides). Avoid LOSSLESS (CRF 0): it is
                # not compatible with H.264 High profile.
                _vid_settings = _SCVideoSettings(_SCMode.SMARTCUT, _SCQuality.NORMAL, 'copy')
                _exc = _sc_api(_src, _segs, output_path,
                               audio_export_info=_export_info,
                               video_settings=_vid_settings)
            finally:
                _src.close()
            if _exc is not None:
                raise _exc
        except Exception as _api_err:
            raise RuntimeError(f"smartcut API failed: {_api_err}") from _api_err

        elapsed = time.monotonic() - t0

        # --- Fix non-canonical framerate header ---
        # The smartcut library sometimes writes avg_frame_rate as a reduced
        # fraction (e.g. 293/12) instead of the proper CFR value (24000/1001).
        # mpv's display scheduler uses this hint; a wrong value causes subtle
        # stutter. Fix with a near-instant stream-copy remux - no re-encode.
        try:
            probe = ffprobe_json(["-select_streams", "v:0",
                                  "-show_entries", "stream=r_frame_rate,avg_frame_rate",
                                  output_path])
            vst = (probe.get("streams") or [{}])[0]
            r_fps = vst.get("r_frame_rate", "")
            a_fps = vst.get("avg_frame_rate", "")
            if r_fps and a_fps and r_fps != a_fps and r_fps not in ("0/0", ""):
                tmp_fix = output_path + ".fpsfix.mkv"
                fix_r = run([FFMPEG_BIN, "-nostdin", "-y", "-loglevel", "error",
                             "-i", output_path, "-c", "copy", "-r", r_fps, tmp_fix])
                if fix_r.returncode == 0:
                    os.replace(tmp_fix, output_path)
                    log(f"  [fix] Framerate header corrected: {a_fps} → {r_fps}")
        except Exception:
            pass  # non-critical
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    if SELF_CHECK:
        verify_cut(output_path, _expected_frames)  # before tag stripping: it reads the stream durations
    if STRIP_STALE_TAGS:
        strip_stale_tags(output_path)

    # --- Post-cut report ---
    try:
        out_size = os.path.getsize(output_path)
        size_str = _format_size(out_size)
    except OSError:
        size_str = "?"

    log(f"  Done in {elapsed:.1f}s  →  {size_str}")
    log(f"  SUCCESS! Output saved to: {output_path}")


def compress_cut(input_path, start, end, output_path, crf=COMPRESS_CRF, preset=COMPRESS_PRESET):
    """Plain re-encode of the whole marked range - no GOP-boundary keyframe
    bracketing or stream-copy splicing, just one clean cut re-encoded at a
    normal delivery CRF. Much smaller output than Smart Cut; use that
    instead if you need archival quality."""
    if end <= start: raise RuntimeError("end must be after start")
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    video, audios, subtitles = probe_streams(input_path)
    offset = get_pts_offset(input_path, video['index'])

    dur = end - start
    encoder = COMPRESS_ENCODER or video.get("codec_name", "?")
    log(f"━━━ Compress ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    codec = video.get("codec_name", "?").upper()
    w = video.get("width", "?")
    h = video.get("height", "?")
    log(f"  Input:  {codec} {w}×{h}")
    log(f"  Range:  {_format_ts(start)} → {_format_ts(end)}  ({_format_duration(dur)})")
    log(f"  Encode: {encoder} CRF {crf} / preset {preset}")
    log(f"  Type:   Full re-encode (all frames)")
    log(f"  Processing…")

    if abs(offset) > EPSILON:
        log(f"  [info] PTS offset: {offset:.3f}s")
    # No need for exact keyframe bracketing here since the whole range gets
    # re-encoded anyway - just seek to a coarse point a couple seconds
    # early so the decoder has warmed up by t_start.
    t0 = time.monotonic()
    seek = max(0.0, start - 2.0)
    ok = make_segment_reencode(input_path, seek, start, end, video, audios, crf, preset, output_path, offset, COMPRESS_PRESET_AV1, COMPRESS_ENCODER, subtitles=subtitles)
    elapsed = time.monotonic() - t0
    if not ok: raise RuntimeError("Compress: nothing to encode (end <= start after rounding).")

    try:
        out_size = os.path.getsize(output_path)
        size_str = _format_size(out_size)
    except OSError:
        size_str = "?"
    log(f"  Done in {elapsed:.1f}s  →  {size_str}")
    log(f"  SUCCESS! Output saved to: {output_path}")


def get_chunks(filepath):
    with open(filepath, 'rb') as f:
        if f.read(8) != b'\x89PNG\r\n\x1a\n': sys.exit(1)
        chunks = []
        while True:
            length_bytes = f.read(4)
            if not length_bytes: break
            length = struct.unpack('>I', length_bytes)[0]
            chunk_type, chunk_data, crc = f.read(4), f.read(length), f.read(4)
            chunks.append((length, chunk_type, chunk_data, crc))
            if chunk_type == b'IEND': break
        return chunks


def _hann2d(h, w):
    wy = np.hanning(h) if h > 1 else np.ones(1)
    wx = np.hanning(w) if w > 1 else np.ones(1)
    return np.outer(wy, wx).astype(np.float32)


def phase_correlate(anchor, frame, window):
    """Full-frame FFT phase correlation. Returns (dx, dy, peak_strength).

    anchor/frame: 2D float32 grayscale arrays, same shape.
    peak_strength: correlation peak height relative to background - low
    value means the match is unreliable (e.g. motion blur, compression
    noise).
    """
    h, w = anchor.shape

    a = (anchor - anchor.mean()) * window
    b = (frame - frame.mean()) * window

    Fa = np.fft.fft2(a)
    Fb = np.fft.fft2(b)

    R = Fa * np.conj(Fb)
    denom = np.abs(R)
    denom[denom < 1e-8] = 1e-8
    R /= denom

    r = np.fft.ifft2(R).real
    r = np.fft.fftshift(r)

    peak_idx = np.unravel_index(np.argmax(r), r.shape)
    peak_val = r[peak_idx]

    cy, cx = h // 2, w // 2
    py, px = peak_idx

    def parabolic_refine(f_m1, f_0, f_p1):
        denom = (f_m1 - 2 * f_0 + f_p1)
        if abs(denom) < 1e-9:
            return 0.0
        return 0.5 * (f_m1 - f_p1) / denom

    sub_y = sub_x = 0.0
    if 0 < py < h - 1:
        sub_y = parabolic_refine(r[py - 1, px], r[py, px], r[py + 1, px])
    if 0 < px < w - 1:
        sub_x = parabolic_refine(r[py, px - 1], r[py, px], r[py, px + 1])

    dy = (py - cy) + sub_y
    dx = (px - cx) + sub_x

    bg = np.mean(np.abs(r))
    strength = float(peak_val / (bg + 1e-8))

    return float(dx), float(dy), strength


def pan_smash(input_path, start_time, end_time, output_path):
    log(f"--- ANCHOR PHASE-CORRELATION PAN SMASH STARTED ---\nInput: {input_path}")

    if not os.path.isfile(FFMPEG_BIN):
        raise RuntimeError(f"ffmpeg not found at '{FFMPEG_BIN}'")

    tmpdir = tempfile.mkdtemp(prefix="pansmash_")
    keep_temp_on_fail = False
    try:
        video, _, _ = probe_streams(input_path)
        offset = get_pts_offset(input_path, video["index"])
        duration = end_time - start_time
        seek_fast = max(0.0, start_time - 5.0)
        seek_accurate = start_time - seek_fast

        cmd_extract = [
            FFMPEG_BIN, "-y", "-v", "error", "-fflags", "+genpts",
            "-ss", str(seek_fast + offset), "-i", input_path,
            "-ss", str(seek_accurate), "-t", str(duration),
            "-pix_fmt", "rgb24", os.path.join(tmpdir, "frame_%04d.png")
        ]
        log("Extracting frames with Frame-Accurate Dual Seek...")
        r = subprocess.run(cmd_extract, capture_output=True, text=True)
        if r.returncode != 0:
            log(f"Extraction failed:\n{r.stderr}")
            keep_temp_on_fail = True
            sys.exit(1)

        image_paths = sorted(glob.glob(os.path.join(tmpdir, "frame_*.png")))
        if len(image_paths) < 2:
            log("Not enough frames.")
            keep_temp_on_fail = True
            sys.exit(1)

        with Image.open(image_paths[0]) as first_img:
            raw_width, height = first_img.size

        if raw_width <= EDGE_TRIM * 4:
            log(f"[warn] Frame width ({raw_width}px) is too small relative to "
                f"EDGE_TRIM={EDGE_TRIM} - skipping edge trim.")
            trim = 0
        else:
            trim = EDGE_TRIM
        width = raw_width - 2 * trim
        log(f"Trimming {trim}px from each side of every frame (native crop/pad edge "
            f"defect, not a stitching artifact) - working width {width}px.")

        log(f"Loading {len(image_paths)} frames into memory for anchor tracking...")
        grays = [np.array(Image.open(p_).convert('L'), dtype=np.float32)[:, trim:raw_width - trim]
                 for p_ in image_paths]
        window = _hann2d(height, width)

        # Transition/fade detection, computed BEFORE tracking: phase
        # correlation discards each frame's mean brightness before matching,
        # so it tracks straight through a cross-fade or scene transition
        # without any visible anomaly in the coordinates. But if such a
        # frame's content is genuinely darker (fading to black between
        # shots, common in ED sequences), pasting its thin reveal-strip
        # into the slit-scan composite bakes that real dip in as a visible
        # dark/black sliver. This is a content problem, not a tracking
        # problem, so these frames get excluded from compositing (and from
        # ever being used as the anchor) rather than "fixed".
        brightness = np.array([g.mean() for g in grays])
        median_b = float(np.median(brightness))
        mad_b = float(np.median(np.abs(brightness - median_b))) + 1e-6
        dark_thresh = median_b - max(15.0, mad_b * 6.0)
        transition_mask = brightness < dark_thresh
        for i in np.where(transition_mask)[0]:
            log(f"[skip] Frame {i+1:03d} brightness={brightness[i]:.1f} is well below the "
                f"clip's typical brightness ({median_b:.1f}) - likely a scene transition/fade, "
                f"excluding it from canvas compositing and as a possible anchor.")

        # Pick the anchor defensively: if frame 1 itself is flagged (clip
        # opens mid-fade), every measurement in the whole clip would
        # otherwise be referenced against a bad frame - far worse than any
        # single bad measurement later on. Fall back to frame 1 only if
        # every frame is flagged (nothing better available).
        anchor_idx = 0
        if transition_mask[0]:
            good_start = np.where(~transition_mask)[0]
            if len(good_start) > 0:
                anchor_idx = int(good_start[0])
                log(f"[info] Frame 001 is flagged as a transition/fade frame - using "
                    f"frame {anchor_idx+1:03d} as the tracking anchor instead.")

        anchor = grays[anchor_idx]
        n_frames = len(grays)
        coords = [None] * n_frames
        strengths = [None] * n_frames
        coords[anchor_idx] = (0.0, 0.0)
        strengths[anchor_idx] = float('inf')

        log(f"Tracking every frame against fixed anchor (frame {anchor_idx+1:03d}) "
            f"via FFT phase correlation...")
        for i in range(n_frames):
            if i == anchor_idx:
                continue
            dx, dy, strength = phase_correlate(anchor, grays[i], window)
            coords[i] = (dx, dy)
            strengths[i] = strength
            log(f"Frame {anchor_idx+1:03d} -> {i+1:03d} | Shift: X={dx:+.2f}, Y={dy:+.2f} "
                f"| Peak Strength={strength:.2f}")

        # A low correlation-peak strength is a second, independent signal
        # that a measurement is unreliable (motion blur, compression
        # ringing) even when the frame's brightness looks perfectly normal.
        # Fold it into the same "don't trust this coordinate" pool as the
        # transition/fade frames, using the same robust MAD-based approach.
        strength_arr = np.array([s if s is not None and np.isfinite(s) else 0.0 for s in strengths])
        valid_strengths = strength_arr[~transition_mask]
        median_s = float(np.median(valid_strengths))
        mad_s = float(np.median(np.abs(valid_strengths - median_s))) + 1e-6
        low_strength_thresh = median_s - max(200.0, mad_s * 6.0)
        low_strength_mask = strength_arr < low_strength_thresh
        low_strength_mask[anchor_idx] = False
        for i in np.where(low_strength_mask & ~transition_mask)[0]:
            log(f"[warn] Frame {i+1:03d} peak strength={strength_arr[i]:.1f} is well below "
                f"typical ({median_s:.1f}) - likely motion blur or compression noise, "
                f"excluding its measurement from the pan-trend fit.")

        unreliable_mask = transition_mask | low_strength_mask

        # Robust correction pass: since this is confirmed to be a single
        # uniform pan, the true coords must lie on (near) a straight line
        # vs frame index. A raw phase-correlation miss on any one frame
        # (motion blur, compression artifact, etc.) creates a jump big
        # enough to leave a gap in canvas coverage - visible as a hard
        # black seam, since nothing gets pasted over that column.
        #
        # Fit iteratively, excluding outliers each round, then OVERRIDE
        # any outlier frame's coords with the robust line's prediction
        # rather than just warning about it. This guarantees continuous,
        # gap-free coverage instead of trusting a possibly-bad measurement.
        # Transition/fade and low-correlation-strength frames are excluded
        # from the fit itself too, since both are independent signs their
        # coordinate estimate may be noisier than usual.
        xs = np.array([c[0] for c in coords])
        ys = np.array([c[1] for c in coords])
        n = len(xs)
        if n >= 5:
            idx = np.arange(n)
            inlier_mask = ~unreliable_mask

            for _pass in range(3):
                fit_x = np.polyfit(idx[inlier_mask], xs[inlier_mask], 1)
                fit_y = np.polyfit(idx[inlier_mask], ys[inlier_mask], 1)
                pred_x = np.polyval(fit_x, idx)
                pred_y = np.polyval(fit_y, idx)
                resid = np.sqrt((xs - pred_x) ** 2 + (ys - pred_y) ** 2)
                thresh = max(3.0, float(np.median(resid[inlier_mask])) * 4.0)
                new_mask = (resid <= thresh) & ~unreliable_mask
                if np.array_equal(new_mask, inlier_mask):
                    break
                inlier_mask = new_mask

            for i in range(n):
                if not inlier_mask[i] and not unreliable_mask[i]:
                    log(f"[fixed] Frame {i+1:03d} raw measurement (X={xs[i]:+.2f}, Y={ys[i]:+.2f}) "
                        f"deviated {resid[i]:.2f}px from the robust linear pan trend "
                        f"(threshold {thresh:.2f}px) - replacing with fitted position "
                        f"(X={pred_x[i]:+.2f}, Y={pred_y[i]:+.2f}) to avoid a coverage gap.")
                    coords[i] = (float(pred_x[i]), float(pred_y[i]))

        good_indices = [i for i in range(len(coords)) if not transition_mask[i]]
        if not good_indices:
            log("CRITICAL ERROR: every frame was flagged as a transition/fade - nothing to composite.")
            keep_temp_on_fail = True
            sys.exit(1)
        first_good, last_good = good_indices[0], good_indices[-1]

        min_x = min(coords[i][0] for i in good_indices)
        max_x = max(coords[i][0] for i in good_indices)
        min_y = min(coords[i][1] for i in good_indices)
        max_y = max(coords[i][1] for i in good_indices)

        offset_x = int(round(-min_x))
        offset_y = int(round(-min_y))
        canvas_width = int(round(width + (max_x - min_x)))
        canvas_height = int(round(height + (max_y - min_y)))

        log(f"\nAlignment calculated. Canvas: {canvas_width}x{canvas_height}. "
            f"(X: {min_x:.1f} to {max_x:.1f}, Y: {min_y:.1f} to {max_y:.1f})")

        # Decide which good frames actually get pasted. Pasting every single
        # good frame is overkill when consecutive frames barely moved (a
        # near-static shot, or a real pan with lots of near-duplicate
        # in-between frames) - but naively using only first/last risks
        # clipping content if the pan is real. So: measure it and adapt.
        pan_extent = float(np.hypot(max_x - min_x, max_y - min_y))
        if pan_extent <= PAN_MINOR_PX:
            log(f"Pan extent ({pan_extent:.1f}px) is at/under the static threshold "
                f"(PAN_MINOR_PX={PAN_MINOR_PX}) - treating this as a static shot: "
                f"compositing only the anchor plus first/last good frames instead of "
                f"every frame.")
            paste_indices = sorted(set([anchor_idx, first_good, last_good]) & set(good_indices))
        else:
            log(f"Pan extent ({pan_extent:.1f}px) exceeds the static threshold - "
                f"keeping only frames that advance at least PAN_STEP_PX={PAN_STEP_PX}px "
                f"from the last kept frame (skips near-duplicate frames, keeps every "
                f"frame that actually reveals new content).")
            paste_indices = [good_indices[0]]
            last_kept = coords[good_indices[0]]
            for i in good_indices[1:]:
                step = np.hypot(coords[i][0] - last_kept[0], coords[i][1] - last_kept[1])
                if step >= PAN_STEP_PX or i == last_good:
                    paste_indices.append(i)
                    last_kept = coords[i]
            if last_good not in paste_indices:
                paste_indices.append(last_good)
        log(f"Compositing {len(paste_indices)}/{len(good_indices)} good frames "
            f"({len(good_indices) - len(paste_indices)} skipped as redundant).")

        log("Rendering Hard-Overwrite Canvas (Zero Blur)...")
        canvas = np.zeros((canvas_height, canvas_width, 3), dtype=np.uint8)
        covered = np.zeros((canvas_height, canvas_width), dtype=bool)

        def load_stretched(path):
            arr = np.array(Image.open(path).convert('RGB'), dtype=np.float32)
            arr = arr[:, trim:raw_width - trim]
            arr = np.clip((arr - 16.0) * (255.0 / (235.0 - 16.0)), 0, 255)
            return arr.astype(np.uint8)

        for i in paste_indices:
            arr = load_stretched(image_paths[i])
            dx, dy = coords[i]
            paste_x = int(round(dx)) + offset_x
            paste_y = int(round(dy)) + offset_y
            canvas[paste_y:paste_y + height, paste_x:paste_x + width] = arr
            covered[paste_y:paste_y + height, paste_x:paste_x + width] = True

        # Safety net: if any column still slipped through uncovered (e.g.
        # a gap the robust refit above didn't fully close, or a long run
        # of consecutive transition frames), duplicate the nearest covered
        # column into it rather than leaving a black seam.
        uncovered_cols = np.where(~covered.any(axis=0))[0]
        if len(uncovered_cols) > 0:
            covered_cols = np.where(covered.any(axis=0))[0]
            log(f"[warn] {len(uncovered_cols)} canvas column(s) had no frame coverage "
                f"even after robust correction and transition exclusion - patching via "
                f"nearest-column fill: {uncovered_cols.tolist()}")
            for col in uncovered_cols:
                nearest = covered_cols[np.argmin(np.abs(covered_cols - col))]
                canvas[:, col] = canvas[:, nearest]

        # Bookend patch: repaste the first and last GOOD (non-transition)
        # frames on top so the sequence's visual endpoints stay crisp.
        # Using the literal first/last index here would risk anchoring an
        # edge on a fade frame if the clip happens to start or end on one.
        log("Applying the Bookend Edge Patch...")
        first_arr = load_stretched(image_paths[first_good])
        fx, fy = coords[first_good]
        canvas[int(round(fy)) + offset_y: int(round(fy)) + offset_y + height,
               int(round(fx)) + offset_x: int(round(fx)) + offset_x + width] = first_arr

        last_arr = load_stretched(image_paths[last_good])
        lx, ly = coords[last_good]
        canvas[int(round(ly)) + offset_y: int(round(ly)) + offset_y + height,
               int(round(lx)) + offset_x: int(round(lx)) + offset_x + width] = last_arr

        raw_out = os.path.join(tmpdir, "raw_numpy_stitch.png")
        Image.fromarray(canvas).save(raw_out, "PNG", compress_level=PNG_COMPRESS_LEVEL)

        log("Injecting original color chunks...")
        color_types = {b'gAMA', b'cHRM', b'cICP', b'iCCP', b'sRGB'}
        color_chunks = [c for c in get_chunks(image_paths[0]) if c[1] in color_types]
        final_chunks = []
        for c in get_chunks(raw_out):
            if c[1] == b'IHDR':
                final_chunks.extend([c] + color_chunks)
            elif c[1] not in color_types:
                final_chunks.append(c)

        os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
        with open(output_path, 'wb') as f:
            f.write(b'\x89PNG\r\n\x1a\n')
            for length, chunk_type, chunk_data, crc in final_chunks:
                f.write(struct.pack('>I', length))
                f.write(chunk_type)
                f.write(chunk_data)
                f.write(crc)

        log(f"  SUCCESS! Output saved to: {output_path}")

    except Exception as e:
        log(f"CRITICAL ERROR: {str(e)}\n{traceback.format_exc()}")
        keep_temp_on_fail = True
        sys.exit(1)
    finally:
        if keep_temp_on_fail:
            log(f"[debug] Temp dir preserved (not deleted): {tmpdir}")
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)


def make_gif(input_path, start_time, end_time, output_path):
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)

    if not os.path.isfile(FFMPEG_BIN):
        raise RuntimeError(f"ffmpeg not found at '{FFMPEG_BIN}'")

    video, _, _ = probe_streams(input_path)
    offset = get_pts_offset(input_path, video["index"])
    duration = end_time - start_time
    seek_fast = max(0.0, start_time - 5.0)
    seek_accurate = start_time - seek_fast

    scale_filter = (f"scale='min({GIF_MAX_WIDTH},iw)':-1:flags=lanczos"
                     if GIF_MAX_WIDTH else "scale=iw:-1:flags=lanczos")
    # Optional 16-235 -> 0-255 stretch, OFF by default - testing showed this
    # was likely double-expanding already-correct data and making things
    # worse, not better. Left available in case a future source needs it.
    levels_filter = "curves=all='0/0 0.0627451/0 0.9215686/1 1/1'" if GIF_LEVELS_STRETCH else None
    chain = [f"fps={GIF_FPS}", scale_filter] + ([levels_filter] if levels_filter else []) + ["split[s0][s1]"]
    filter_complex = (
        ",".join(chain) + ";"
        f"[s0]palettegen=max_colors={GIF_COLORS}[p];"
        f"[s1][p]paletteuse=dither={GIF_DITHER}"
    )
    cmd = [
        FFMPEG_BIN, "-y", "-v", "error", "-fflags", "+genpts",
        "-ss", str(start_time + offset), "-t", str(duration), "-i", input_path,
        "-filter_complex", filter_complex,
        "-loop", str(GIF_LOOP),
        output_path,
    ]

    log(f"━━━ GIF Render ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    log(f"  Input:  {os.path.basename(input_path)}")
    log(f"  Range:  {_format_ts(start_time)} → {_format_ts(end_time)}  ({_format_duration(end_time - start_time)})")
    log(f"  Params: {GIF_FPS}fps, max {GIF_MAX_WIDTH or 'src'}px wide, {GIF_COLORS} colors, dither={GIF_DITHER}")
    log(f"  Processing…")
    rc, tail = run_live(cmd)
    if rc != 0:
        raise RuntimeError(f"GIF render failed:\n{tail}")
    try:
        size_str = _format_size(os.path.getsize(output_path))
    except OSError:
        size_str = "?"
    log(f"  Done  →  {size_str}")
    log(f"  SUCCESS! GIF saved to: {output_path}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("input")
    p.add_argument("start", type=float)
    p.add_argument("end", type=float)
    p.add_argument("output")
    p.add_argument("--start-frame", type=int, default=None,
                   help="mpv estimated-frame-number at mark A (0-based). "
                        "Used only when CUT_MARKS = \"frames\".")
    p.add_argument("--end-frame", type=int, default=None,
                   help="mpv estimated-frame-number at mark B (0-based).")
    args = p.parse_args()
    if args.output.endswith(".png"):
        pan_smash(args.input, args.start, args.end, args.output)
    elif args.output.endswith(".gif"):
        make_gif(args.input, args.start, args.end, args.output)
    elif args.output.endswith(".compressed.mkv"):
        compress_cut(args.input, args.start, args.end, args.output)
    else:
        smart_cut(args.input, args.start, args.end, args.output,
                  start_frame=args.start_frame, end_frame=args.end_frame)