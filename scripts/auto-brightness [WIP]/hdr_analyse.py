#!/usr/bin/env python3
"""
hdr_analyse.py
Universal HDR peak analyser & raw series metadata exporter for mpv.

Accelerated Modes:
  1. Dolby Vision (Profile 5, 7, 8):
     Uses `dovi_tool` to extract native RPU Level 1 max-pq/avg-pq and scene cuts
     directly from the HEVC bitstream in ~3 seconds (no video decoding).
  2. HDR10+ (SMPTE ST 2094-40):
     Uses `hdr10plus_tool` to extract per-scene dynamic MaxScl and AverageRGB
     in ~3 seconds.
  3. Fast Universal HDR10 / HLG:
     Runs headless FFmpeg with signalstats to extract YMAX/YAVG per frame.
     For software-decoded codecs (AV1 etc.) on long files, the analysis is
     split into N parallel chunks to work around dav1d's poor multi-core
     scaling on 4K input.

Scene cut handling:
  The old ffmpeg `select=gt(scene,...)` pre-pass forced a second full decode
  of the file. It has been removed -- scene cuts are now derived post-hoc
  from the per-frame luminance series produced by whichever backend ran.
  See `_derive_scene_cuts()` for the heuristic and its trade-offs.

Output:
  ~/.config/mpv/cache/scripts/hdr_analysis/<md5>.jsonl
  ~/.config/mpv/cache/scripts/hdr_analysis/<md5>.curve.json

  The .curve.json now leads with source-file identity and probe metadata,
  followed by the analysis summary (including informational peak_nits /
  peak_avg_nits fields), and finally the per-frame series array. The series
  array is required by cabc.lua's try_load_curve() and MUST NOT be removed.
  src_mtime / src_size field names are load-bearing for both the Python
  cache check below and cabc.lua's cache-validity check; do not rename.
"""

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.pycache_prefix = str(Path.home() / ".config" / "mpv" / "cache" / "__pycache__")

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).resolve().parent
CACHE_DIR  = Path.home() / ".config" / "mpv" / "cache" / "scripts" / "hdr_analysis"
MPV_CONFIG = Path.home() / ".config" / "mpv"

DOVI_TOOL      = shutil.which("dovi_tool")      or "/opt/homebrew/bin/dovi_tool"
HDR10PLUS_TOOL = shutil.which("hdr10plus_tool") or "/opt/homebrew/bin/hdr10plus_tool"
FFMPEG         = shutil.which("ffmpeg")         or "/opt/homebrew/bin/ffmpeg"
FFPROBE        = shutil.which("ffprobe")        or "/opt/homebrew/bin/ffprobe"


# ── Hardware Decode Blacklist ─────────────────────────────────────────────────
# Codec names listed here (matching ffprobe's `codec_name` field, lowercase)
# will force SOFTWARE decoding everywhere in this script. This exists to work
# around platforms where VideoToolbox advertises support for a codec but fails
# at runtime -- most notably AV1 on pre-M3 Apple Silicon (M1/M2) and most
# Intel Macs, where FFmpeg gets stuck in a per-packet retry loop:
#   [av1 @ ...] Failed setup for format videotoolbox_vld: hwaccel initialisation returned error.
#
# Common ffprobe codec_name values: "av1", "hevc", "h264", "vp9", "mpeg2video".
HWDEC_BLACKLIST = {"av1"}

# Optional: name the exact software decoder for each blacklisted codec, passed
# via -c:v BEFORE -i. The native AV1 decoder in some ffmpeg builds will try to
# negotiate videotoolbox_vld as a pixel format even with -hwaccel none, and
# naming libdav1d takes that option off the table.
SW_DECODER_OVERRIDE = {
    "av1": "libdav1d",
}

# Files longer than this (seconds) that are also on the HWDEC_BLACKLIST will
# be split into parallel chunks for the signalstats pass. Below this, the
# process-launch overhead isn't worth it.
CHUNK_MIN_DURATION = 90.0


def codec_hwdec_disabled(codec: str) -> bool:
    """True if this codec should skip hardware decoding entirely."""
    return bool(codec) and codec.strip().lower() in HWDEC_BLACKLIST


def sw_decoder_args(codec: str) -> list:
    """Returns ['-c:v', '<decoder>'] if a software decoder override exists
    for this codec, else []. Only meaningful when the codec is also on the
    HWDEC_BLACKLIST."""
    if not codec_hwdec_disabled(codec):
        return []
    dec = SW_DECODER_OVERRIDE.get(codec.strip().lower())
    return ["-c:v", dec] if dec else []


def pq_to_nits(pq: float) -> float:
    """ST.2084 EOTF: convert PQ signal (0-1) to absolute luminance in cd/m2."""
    if pq <= 0:
        return 0.0
    m1 = 0.1593017578125
    m2 = 78.84375
    c1 = 0.8359375
    c2 = 18.8515625
    c3 = 18.6875
    pq_m2 = pq ** (1.0 / m2)
    num = max(pq_m2 - c1, 0.0)
    den = c2 - c3 * pq_m2
    if den <= 0:
        return 10000.0
    return 10000.0 * (num / den) ** (1.0 / m1)


def _percentile(values: list, pct: float) -> float:
    """Linear percentile for a non-empty numeric list."""
    vals = sorted(float(v) for v in values if math.isfinite(float(v)))
    if not vals:
        raise ValueError("no finite values")
    if len(vals) == 1:
        return vals[0]
    pos = (len(vals) - 1) * (pct / 100.0)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return vals[lo]
    frac = pos - lo
    return vals[lo] + (vals[hi] - vals[lo]) * frac


def summarize_content_peak(series_data: list) -> dict:
    """Summarize the file's analyzed scene-peak luminance.

    This reports the highest scene peak and the arithmetic mean of the
    per-frame scene peaks. It does NOT calculate mpv's `tone-mapping-param`
    and it does NOT choose a value for mpv `target-peak`: that mpv option is
    the measured peak brightness of the output display, not the source file.
    """
    peaks = []
    for item in series_data or []:
        try:
            p = float(item.get("p", item.get("scene_peak", item.get("nits"))))
        except (TypeError, ValueError):
            continue
        if math.isfinite(p) and p >= 0.0:
            peaks.append(p)

    if not peaks:
        return {
            "max_peak_nits": None,
            "mean_peak_nits": None,
            "p95_peak_nits": None,
            "frames": 0,
        }

    return {
        "max_peak_nits": round(max(peaks), 1),
        "mean_peak_nits": round(sum(peaks) / len(peaks), 1),
        "p95_peak_nits": round(_percentile(peaks, 95.0), 1),
        "frames": len(peaks),
    }


def file_md5(path: str) -> str:
    """MD5 of the absolute resolved path string (fast identifier matching mpv Lua)."""
    return hashlib.md5(str(Path(path).resolve()).encode()).hexdigest()


def cache_path_jsonl(video_path: str) -> Path:
    return CACHE_DIR / f"{file_md5(video_path)}.jsonl"


def cache_path_curve(video_path: str) -> Path:
    return CACHE_DIR / f"{file_md5(video_path)}.curve.json"


def cache_path_failed(video_path: str) -> Path:
    return CACHE_DIR / f"{file_md5(video_path)}.failed"


def atomic_write_curve(out_curve: Path, curve_data: dict, video_path: str,
                       info: dict = None):
    """Atomically writes curve JSON.

    Structure, in order:
      1. Source file identity  (file, path, src_mtime, src_size)
      2. Probe metadata        (codec, fps, duration, bit_depth, color_range,
                                dolby_vision, dv_profile, max_cll, max_fall)
      3. Analysis summary      (source, total_points, initial_nits,
                                max_peak_nits, mean_peak_nits, p95_peak_nits)
      4. Per-frame series      (required by cabc.lua's try_load_curve -- do
                                not remove)

    Field-name notes:
      src_mtime / src_size are LOAD-BEARING. Both the Python cache-validity
      check in main() below and cabc.lua's try_load_curve() read these exact
      keys. Renaming them silently breaks both cache-invalidation paths.

    max_peak_nits / mean_peak_nits / p95_peak_nits are informational;
    they exist so a human can inspect the video's HDR headroom at a glance.
    `peak_avg_nits` remains the maximum per-frame average luminance for
    compatibility and clarity. cabc.lua's build_curve_from_raw_series ignores
    them entirely.
    """
    series = curve_data.get("series") or []
    peak_summary = summarize_content_peak(series)

    out = {}

    # --- 1. Source file identity ---
    try:
        p = Path(video_path).resolve()
        st = p.stat()
        out["file"] = p.name
        out["path"] = str(p)
        out["src_mtime"] = round(st.st_mtime, 3)
        out["src_size"] = st.st_size
    except Exception as e:
        print(f"[!] Warning: could not stat source video: {e}")
        out["file"] = Path(video_path).name
        out["path"] = str(Path(video_path).resolve())

    # --- 2. Probe metadata ---
    if info:
        if info.get("codec"):
            out["codec"] = info["codec"]
        if info.get("fps"):
            out["fps"] = round(info["fps"], 3)
        if info.get("duration") is not None:
            out["duration"] = round(info["duration"], 3)
        if info.get("bit_depth") is not None:
            out["bit_depth"] = info["bit_depth"]
        if info.get("color_range"):
            out["color_range"] = info["color_range"]
        out["dolby_vision"] = bool(info.get("is_dovi", False))
        if info.get("dovi_profile") is not None:
            out["dv_profile"] = info["dovi_profile"]
        if info.get("max_cll") is not None:
            out["max_cll"] = info["max_cll"]
        if info.get("max_fall") is not None:
            out["max_fall"] = info["max_fall"]

    # --- 3. Analysis summary ---
    out["source"] = curve_data.get("source", "")
    out["total_points"] = curve_data.get("total_points", len(series))
    out["initial_nits"] = curve_data.get("initial_nits")

    peak_summary = summarize_content_peak(series)
    out["max_peak_nits"] = peak_summary["max_peak_nits"]
    out["mean_peak_nits"] = peak_summary["mean_peak_nits"]
    out["p95_peak_nits"] = peak_summary["p95_peak_nits"]
    # Keep this legacy informational field explicit: it is the maximum
    # per-frame average luminance, not the arithmetic mean of scene peaks.
    if series:
        try:
            out["peak_avg_nits"] = round(max(float(s.get("a", 0.0)) for s in series), 1)
        except (TypeError, ValueError):
            out["peak_avg_nits"] = None
    else:
        out["peak_avg_nits"] = None

    # --- 4. Per-frame series (required by cabc.lua try_load_curve) ---
    if series:
        out["series"] = series

    tmp_curve = out_curve.with_suffix(".curve.json.tmp")
    try:
        with open(tmp_curve, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=2)
        tmp_curve.replace(out_curve)
    except Exception:
        if tmp_curve.exists():
            try: tmp_curve.unlink()
            except Exception: pass
        raise


def count_lines(path: Path) -> int:
    try:
        with open(path, "rb") as f:
            return sum(1 for _ in f)
    except Exception:
        return 0


def probe_video(video_path: str) -> dict:
    """Probes video properties via ffprobe."""
    try:
        res = subprocess.run(
            [
                FFPROBE, "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-select_streams", "v:0",
                video_path
            ],
            capture_output=True, text=True, timeout=15
        )
        data = json.loads(res.stdout)
        stream = data.get("streams", [{}])[0]
        fmt = data.get("format", {})

        # Parse FPS
        fps = 24.0
        r_fps = stream.get("r_frame_rate", "24/1")
        if "/" in r_fps:
            num, den = r_fps.split("/")
            if float(den) > 0:
                fps = float(num) / float(den)
        elif r_fps:
            fps = float(r_fps)

        # Parse Duration
        duration = None
        if "duration" in stream and stream["duration"]:
            duration = float(stream["duration"])
        elif "duration" in fmt and fmt["duration"]:
            duration = float(fmt["duration"])
        elif "tags" in stream and "DURATION" in stream["tags"]:
            dur_str = stream["tags"]["DURATION"]
            parts = dur_str.split(":")
            if len(parts) == 3:
                duration = float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])

        # Bit depth and color range -- informational right now. The signalstats
        # normalization below assumes 10-bit limited range, which is correct
        # for all real HDR sources (PQ/HLG are always 10-bit at minimum).
        pix_fmt = stream.get("pix_fmt", "") or ""
        bit_depth = 8
        if "10" in pix_fmt or "p010" in pix_fmt:
            bit_depth = 10
        elif "12" in pix_fmt:
            bit_depth = 12
        color_range = stream.get("color_range", "tv") or "tv"

        # Dolby Vision and light-level metadata
        is_dovi = False
        dovi_profile = None
        max_cll = None
        max_fall = None

        for side_data in stream.get("side_data_list", []):
            sd_type = side_data.get("side_data_type")
            if sd_type == "DOVI configuration record":
                is_dovi = True
                dovi_profile = side_data.get("dv_profile")
            elif sd_type == "Content light level metadata":
                max_cll = side_data.get("max_content")
                max_fall = side_data.get("max_average")
            elif sd_type == "Mastering display metadata" and not max_cll:
                max_lum = side_data.get("max_luminance")
                if max_lum and "/" in max_lum:
                    num, den = max_lum.split("/")
                    if float(den) > 0:
                        max_cll = float(num) / float(den)

        tags = {**fmt.get("tags", {}), **stream.get("tags", {})}
        for k, v in tags.items():
            k_up = k.upper()
            if not max_cll and ("MAX_CLL" in k_up or "MAXCLL" in k_up):
                try: max_cll = float(v)
                except ValueError: pass
            elif not max_fall and ("MAX_FALL" in k_up or "MAXFALL" in k_up):
                try: max_fall = float(v)
                except ValueError: pass

        initial_seed = 203.0
        if max_fall and float(max_fall) > 10.0:
            initial_seed = float(max_fall)
        elif max_cll and float(max_cll) > 10.0:
            initial_seed = min(350.0, max(80.0, float(max_cll) * 0.35))

        return {
            "fps": fps,
            "duration": duration,
            "is_dovi": is_dovi,
            "dovi_profile": dovi_profile,
            "codec": stream.get("codec_name", ""),
            "pix_fmt": pix_fmt,
            "bit_depth": bit_depth,
            "color_range": color_range,
            "max_cll": max_cll,
            "max_fall": max_fall,
            "initial_seed": initial_seed
        }
    except Exception:
        return {
            "fps": 24.0, "duration": None, "is_dovi": False, "dovi_profile": None,
            "codec": "", "pix_fmt": "", "bit_depth": 10, "color_range": "tv",
            "initial_seed": 203.0
        }


# ── Scene Cut Derivation (post-hoc) ───────────────────────────────────────────

def _derive_scene_cuts(series_data: list, avg_thresh: float = 0.20,
                       peak_thresh: float = 0.50, min_gap_sec: float = 0.4):
    """Marks cut=True on frames whose avg or peak luminance jumps significantly
    from the previous sampled frame.

    This replaces the old ffmpeg `select=gt(scene,...)` pre-pass, which required
    a second full decode of the file. Because every backend in this script
    already produces per-frame avg/peak luminance, and a scene cut is
    *characterised* by exactly such a discontinuity, we look for the jumps
    directly.

    Trade-offs vs the ffmpeg scene filter:
      - Slightly higher false-positive rate on fast-motion or flash transitions.
      - Can miss a cut between two scenes with near-identical average
        brightness (rare).
    Both failure modes are benign for the CABC smoothing that consumes these
    flags: a false cut just resets smoothing a frame early, and a missed cut
    costs at most one frame of cross-scene smoothing.

    Thresholds are relative (fractional change vs previous frame), floored at
    2 nits to avoid dividing by noise in near-black frames.
    """
    if not series_data:
        return
    series_data[0]["cut"] = True
    last_cut_t = series_data[0]["t"]

    for i in range(1, len(series_data)):
        prev, cur = series_data[i - 1], series_data[i]
        cur["cut"] = False
        if cur["t"] - last_cut_t < min_gap_sec:
            continue
        a_prev = max(prev["a"], 2.0)
        p_prev = max(prev["p"], 2.0)
        a_jump = abs(cur["a"] - prev["a"]) / a_prev
        p_jump = abs(cur["p"] - prev["p"]) / p_prev
        if a_jump > avg_thresh or p_jump > peak_thresh:
            cur["cut"] = True
            last_cut_t = cur["t"]


# ── Fast Dolby Vision Metadata Pipeline ───────────────────────────────────────

def run_fast_dovi(video: str, out_jsonl: Path, out_curve: Path, fps: float,
                  initial_seed: float = 203.0, info: dict = None) -> bool:
    """Extracts native Dolby Vision RPU metadata via dovi_tool in ~3s."""
    if not os.path.exists(DOVI_TOOL):
        return False

    print(f"[*] Dolby Vision detected! Running ultra-fast bitstream extraction via dovi_tool...")
    t_start = time.time()

    with tempfile.TemporaryDirectory(prefix="dovi_cabc_") as tmpdir:
        tmp_rpu = os.path.join(tmpdir, "rpu.bin")
        tmp_l1 = os.path.join(tmpdir, "l1.json")
        tmp_scenes = os.path.join(tmpdir, "scenes.json")

        try:
            ret = subprocess.run([DOVI_TOOL, "extract-rpu", "-i", video, "-o", tmp_rpu],
                                 capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            print(f"[!] dovi_tool extract-rpu timed out after 180s on {video}")
            return False
        if ret.returncode != 0 or not os.path.exists(tmp_rpu) or os.path.getsize(tmp_rpu) == 0:
            print(f"[!] dovi_tool extract-rpu failed: {ret.stderr.strip() or ret.stdout.strip()}")
            return False

        try:
            ret2 = subprocess.run([DOVI_TOOL, "export", "-i", tmp_rpu,
                                   "-l", f"level1={tmp_l1}",
                                   "-d", f"scenes={tmp_scenes}",
                                   "-f", "json"],
                                  capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            print(f"[!] dovi_tool export timed out after 180s on {video}")
            return False
        if ret2.returncode != 0 or not os.path.exists(tmp_l1):
            print(f"[!] dovi_tool export failed: {ret2.stderr.strip()}")
            return False

        with open(tmp_l1) as f:
            l1_data = json.load(f)

        scene_cuts = set()
        if os.path.exists(tmp_scenes):
            with open(tmp_scenes) as f:
                for line in f:
                    line = line.strip()
                    if line.isdigit():
                        scene_cuts.add(int(line))

        if not l1_data:
            return False

        series_data = []
        with open(out_jsonl, "w") as jf:
            for item in l1_data:
                f_idx = item["frame"]
                t = f_idx / fps
                max_pq_norm = item["max_pq"] / 4095.0
                # Fall back to max_pq when avg_pq is absent, so a frame with
                # partial RPU data doesn't silently pull the blended target
                # toward black.
                avg_pq_norm = item.get("avg_pq", item["max_pq"]) / 4095.0
                raw_nits = pq_to_nits(max_pq_norm)
                avg_nits = pq_to_nits(avg_pq_norm)
                is_cut = (f_idx in scene_cuts) or (f_idx == 0)

                series_data.append({
                    "t": round(t, 3),
                    "p": round(raw_nits, 1),
                    "a": round(avg_nits, 1),
                    "cut": is_cut
                })

                entry = {
                    "t": round(t, 6),
                    "pq": round(max_pq_norm, 6),
                    "avg": round(avg_pq_norm, 6),
                    "scene_max": round(raw_nits, 2),
                    "scene_avg": round(avg_nits, 2)
                }
                jf.write(json.dumps(entry) + "\n")

        init_nits = series_data[0]["p"] if series_data else initial_seed
        peak_summary = summarize_content_peak(series_data)
        print(f"[Peak] max={peak_summary['max_peak_nits'] or 0.0:.1f}n "
              f"mean={peak_summary['mean_peak_nits'] or 0.0:.1f}n "
              f"p95={peak_summary['p95_peak_nits'] or 0.0:.1f}n")
        atomic_write_curve(out_curve, {
            "total_points": len(series_data),
            "source": "Dolby Vision RPU (dovi_tool)",
            "initial_nits": round(init_nits, 1),
            "series": series_data,
        }, video, info=info)

        elapsed = time.time() - t_start
        print(f"[OK] Dolby Vision extraction complete in {elapsed:.2f}s "
              f"({len(series_data):,} frames, {len(scene_cuts):,} native scene cuts).")
        return True


# ── Fast HDR10+ Metadata Pipeline ─────────────────────────────────────────────

def run_fast_hdr10plus(video: str, out_jsonl: Path, out_curve: Path, fps: float,
                       initial_seed: float = 203.0, info: dict = None) -> bool:
    """Extracts native HDR10+ metadata via hdr10plus_tool in ~3s."""
    if not os.path.exists(HDR10PLUS_TOOL):
        return False

    with tempfile.TemporaryDirectory(prefix="hdr10p_cabc_") as tmpdir:
        tmp_test = os.path.join(tmpdir, "test.json")
        try:
            test_res = subprocess.run([HDR10PLUS_TOOL, "extract", "-i", video, "-l", "50", "-o", tmp_test],
                                      capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            return False
        if test_res.returncode != 0 or not os.path.exists(tmp_test):
            return False

        print(f"[*] HDR10+ dynamic metadata detected! Running bitstream extraction via hdr10plus_tool...")
        t_start = time.time()
        tmp_full = os.path.join(tmpdir, "hdr10plus.json")
        try:
            full_res = subprocess.run([HDR10PLUS_TOOL, "extract", "-i", video, "-o", tmp_full],
                                      capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            print(f"[!] hdr10plus_tool extract timed out after 180s on {video}")
            return False
        if full_res.returncode != 0 or not os.path.exists(tmp_full):
            return False

        with open(tmp_full) as f:
            data = json.load(f)

        frames = data.get("JSON") or data.get("frames") or []
        if not frames:
            return False

        series_data = []
        with open(out_jsonl, "w") as jf:
            for f_idx, frame in enumerate(frames):
                t = f_idx / fps
                lum = frame.get("LuminanceParameters", {})
                max_scl = lum.get("MaxScl", [203.0, 203.0, 203.0])
                avg_rgb = lum.get("AverageRGB", 100.0)
                scene_peak = float(max(max_scl)) if max_scl else 203.0
                is_cut = (frame.get("SceneFrameIndex", 1) == 0) or (f_idx == 0)

                series_data.append({
                    "t": round(t, 3),
                    "p": round(scene_peak, 1),
                    "a": round(float(avg_rgb), 1),
                    "cut": is_cut
                })

                entry = {
                    "t": round(t, 6),
                    "pq": None,
                    "avg": None,
                    "scene_max": round(scene_peak, 2),
                    "scene_avg": round(float(avg_rgb), 2)
                }
                jf.write(json.dumps(entry) + "\n")

        init_nits = series_data[0]["p"] if series_data else initial_seed
        peak_summary = summarize_content_peak(series_data)
        print(f"[Peak] max={peak_summary['max_peak_nits'] or 0.0:.1f}n "
              f"mean={peak_summary['mean_peak_nits'] or 0.0:.1f}n "
              f"p95={peak_summary['p95_peak_nits'] or 0.0:.1f}n")
        atomic_write_curve(out_curve, {
            "total_points": len(series_data),
            "source": "HDR10+ (hdr10plus_tool)",
            "initial_nits": round(init_nits, 1),
            "series": series_data,
        }, video, info=info)

        elapsed = time.time() - t_start
        print(f"[OK] HDR10+ extraction complete in {elapsed:.2f}s ({len(series_data):,} frames).")
        return True


# ── Fast Universal HDR Analysis Pass (FFmpeg Signalstats) ──────────────────────

def _parse_signalstats_meta(path: str):
    """Parses an ffmpeg `metadata=print:file=...` dump produced by the
    signalstats filter. Returns a list of (pts_str, yavg_str, ymax_str)
    tuples. Handles both key orderings ffmpeg may emit."""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    pattern = re.compile(
        r'pts_time:([\d\.]+).*?lavfi\.signalstats\.YAVG=([\d\.]+).*?lavfi\.signalstats\.YMAX=(\d+)',
        re.DOTALL)
    matches = pattern.findall(content)
    if not matches:
        pattern_rev = re.compile(
            r'pts_time:([\d\.]+).*?lavfi\.signalstats\.YMAX=(\d+).*?lavfi\.signalstats\.YAVG=([\d\.]+)',
            re.DOTALL)
        matches = [(t, yavg, ymax) for (t, ymax, yavg) in pattern_rev.findall(content)]
    return matches


def _extract_signalstats_single(video: str, codec: str):
    """Decodes the whole file in a single ffmpeg process. Returns list of
    (t_sec, yavg, ymax) tuples sorted by t, or None on failure.

    stderr is left inherited so ffmpeg's `-stats` progress line is visible."""
    with tempfile.NamedTemporaryFile(prefix="hdrstat_", suffix=".txt", delete=False) as tf:
        meta_path = tf.name
    try:
        cmd = [
            FFMPEG, "-nostdin",
            "-loglevel", "error", "-stats",
            "-hwaccel", "none" if codec_hwdec_disabled(codec) else "videotoolbox",
            *sw_decoder_args(codec),
            "-i", video,
            "-vf", f"scale=640:-1:flags=neighbor,signalstats,metadata=print:file={meta_path}",
            "-f", "null", "-"
        ]
        ret = subprocess.run(cmd, stdin=subprocess.DEVNULL, timeout=1800)
        if ret.returncode != 0 or not os.path.exists(meta_path) or os.path.getsize(meta_path) == 0:
            return None
        raw = _parse_signalstats_meta(meta_path)
        return [(float(t), float(a), int(m)) for (t, a, m) in raw]
    except subprocess.TimeoutExpired:
        print("[!] Single-pass ffmpeg signalstats decode timed out after 1800s.")
        return None
    finally:
        if os.path.exists(meta_path):
            try: os.unlink(meta_path)
            except Exception: pass


def _extract_signalstats_chunked(video: str, codec: str, duration: float, n_chunks: int):
    """Runs N parallel ffmpeg processes, each on a slice of the file, then
    merges their signalstats output.

    Only worth doing for software-decoded long files: a single dav1d process
    on 4K AV1 leaves most M-series cores idle, so N independent decoders
    trade some per-process efficiency for a net wall-clock win.

    Returns list of (t_sec, yavg, ymax) tuples sorted by t, or None on failure.
    """
    chunk_dur = duration / n_chunks
    cores = os.cpu_count() or 4
    # Cap threads per chunk so N chunks * threads_per_chunk doesn't wildly
    # oversubscribe the CPU. dav1d uses frame-level threading, so a low
    # thread count per chunk is fine when we have N chunks running in parallel.
    threads_per_chunk = max(1, cores // n_chunks)

    print(f"[*] Chunked decode: {n_chunks} processes x {threads_per_chunk} threads, "
          f"~{chunk_dur:.1f}s per chunk.")

    with tempfile.TemporaryDirectory(prefix="hdrstat_chunked_") as tmpdir:
        procs = []
        chunk_start_times = []
        for i in range(n_chunks):
            start = i * chunk_dur
            # small overlap for non-last chunks to avoid dropping the
            # boundary frame; deduped after merge.
            span = chunk_dur + 0.5 if i < n_chunks - 1 else chunk_dur
            meta_path = os.path.join(tmpdir, f"meta_{i:03d}.txt")
            cmd = [
                FFMPEG, "-nostdin",
                "-hwaccel", "none",
                *sw_decoder_args(codec),
                "-threads", str(threads_per_chunk),
                # `-ss` before `-i` = fast input seek (drops to nearest
                # keyframe and decodes forward). `-t` before `-i` caps how
                # much input is processed, so a chunk doesn't waste work on
                # the whole rest of the file.
                "-ss", f"{start:.3f}",
                "-t", f"{span:.3f}",
                "-i", video,
                "-vf", f"scale=640:-1:flags=neighbor,signalstats,metadata=print:file={meta_path}",
                "-f", "null", "-"
            ]
            p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            procs.append((p, meta_path, start, i))
            chunk_start_times.append(time.time())
            print(f"[*]   chunk {i+1}/{n_chunks} started (t={start:.1f}s, span={span:.1f}s)")

        failed = False
        for (p, _, _, i) in procs:
            try:
                rc = p.wait(timeout=1800)
            except subprocess.TimeoutExpired:
                try: p.kill()
                except Exception: pass
                print(f"[!]   chunk {i+1}/{n_chunks} timed out after 1800s")
                failed = True
                continue
            if rc != 0:
                print(f"[!]   chunk {i+1}/{n_chunks} exited with code {rc}")
                failed = True
        if failed:
            return None

        merged = []
        for idx, (_, meta_path, start, i) in enumerate(procs):
            if not os.path.exists(meta_path) or os.path.getsize(meta_path) == 0:
                print(f"[!]   chunk {i+1}/{n_chunks} produced no metadata")
                return None
            chunk_frames = _parse_signalstats_meta(meta_path)
            for pts_str, yavg_str, ymax_str in chunk_frames:
                merged.append((float(pts_str) + start, float(yavg_str), int(ymax_str)))
            elapsed = time.time() - chunk_start_times[i]
            print(f"[*]   chunk {i+1}/{n_chunks} done ({len(chunk_frames):,} frames in {elapsed:.1f}s)")

        merged.sort(key=lambda x: x[0])
        deduped = []
        for t, yavg, ymax in merged:
            if deduped and abs(deduped[-1][0] - t) < 0.002:
                continue
            deduped.append((t, yavg, ymax))
        return deduped


def run_fast_hdr_ffmpeg(video: str, out_jsonl: Path, out_curve: Path,
                        codec: str = "", initial_seed: float = 203.0,
                        duration: float = None, n_chunks: int = None,
                        no_scdet: bool = False, info: dict = None) -> bool:
    """Fast per-frame HDR peak extraction using FFmpeg signalstats.

    Measures actual decoded pixel luma (YMAX/YAVG) directly, so it works
    regardless of whether the file's own HDR metadata is present, missing,
    or wrong. Per-frame pixel analysis is the only way to get a genuinely
    time-varying signal.

    For codecs on HWDEC_BLACKLIST on files longer than CHUNK_MIN_DURATION
    seconds, the file is split into N parallel slices -- a single dav1d
    process does not scale well on 4K AV1, but N independent processes do.
    """
    if not Path(FFMPEG).exists():
        return False

    print(f"[*] Running fast FFmpeg HDR analysis pass...")
    t_start = time.time()

    # Decide single vs chunked.
    use_chunked = (
        codec_hwdec_disabled(codec)
        and duration is not None
        and duration > CHUNK_MIN_DURATION
        and (n_chunks is None or n_chunks > 1)
    )

    if codec_hwdec_disabled(codec):
        print(f"[*] Codec '{codec}' is on the HWDEC_BLACKLIST -> software decode.")

    raw = None
    if use_chunked:
        if n_chunks is None:
            cores = os.cpu_count() or 4
            n_chunks = min(6, max(2, cores // 2))
        raw = _extract_signalstats_chunked(video, codec, duration, n_chunks)
        if raw is None:
            print("[!] Chunked decode failed; falling back to single-pass decode.")
    if raw is None:
        raw = _extract_signalstats_single(video, codec)
    if not raw:
        print("[!] FFmpeg signalstats pass produced no data.")
        return False

    # Normalize 10-bit limited-range Y values [64..940] to PQ [0..1].
    series_data = []
    raw_frames = []
    for (t, yavg, ymax) in raw:
        pq_max = max(0.0, (ymax - 64.0) / (940.0 - 64.0))
        pq_avg = max(0.0, (yavg - 64.0) / (940.0 - 64.0))
        peak_n = pq_to_nits(pq_max)
        avg_n = pq_to_nits(pq_avg)
        series_data.append({
            "t": round(t, 3),
            "p": round(peak_n, 1),
            "a": round(avg_n, 1),
            "cut": False
        })
        raw_frames.append({
            "t": round(t, 6),
            "pq": round(pq_max, 6),
            "avg": round(pq_avg, 6),
            "scene_max": round(peak_n, 2),
            "scene_avg": round(avg_n, 2)
        })

    if no_scdet:
        for s in series_data:
            s["cut"] = False
    else:
        _derive_scene_cuts(series_data)
        n_cuts = sum(1 for s in series_data if s["cut"])
        print(f"[*] Derived {n_cuts:,} scene cuts post-hoc from signalstats series.")

    with open(out_jsonl, "w") as f:
        for rf in raw_frames:
            f.write(json.dumps(rf) + "\n")

    init_nits = series_data[0]["p"] if series_data else initial_seed
    peak_summary = summarize_content_peak(series_data)
    print(f"[Peak] max={peak_summary['max_peak_nits'] or 0.0:.1f}n "
          f"mean={peak_summary['mean_peak_nits'] or 0.0:.1f}n "
          f"p95={peak_summary['p95_peak_nits'] or 0.0:.1f}n")
    atomic_write_curve(out_curve, {
        "total_points": len(series_data),
        "source": "ffmpeg signalstats pass",
        "initial_nits": round(init_nits, 1),
        "series": series_data,
    }, video, info=info)

    elapsed = time.time() - t_start
    print(f"[OK] FFmpeg HDR analysis complete in {elapsed:.1f}s ({len(series_data):,} frames).")
    return True


# ── Main Entrypoint ───────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="HDR peak analyser & raw series metadata exporter for mpv")
    parser.add_argument("video", help="Path to HDR video file")
    parser.add_argument("--force", action="store_true",
                        help="Re-analyse even if cache exists")
    parser.add_argument("--no-scdet", action="store_true",
                        help="Disable scene cut derivation entirely (all frames marked cut=False)")
    parser.add_argument("--chunks", type=int, default=None,
                        help="Number of parallel ffmpeg processes for the software-decode "
                             "signalstats pass. Default: auto (based on CPU count). "
                             "Pass 1 to force single-pass decoding.")
    parser.add_argument("--method", choices=["auto", "dovi", "hdr10plus", "ffmpeg"],
                        default="auto",
                        help="Force a specific extraction backend instead of the automatic "
                             "priority chain (dovi -> hdr10plus -> ffmpeg).")
    args = parser.parse_args()

    video = str(Path(args.video).resolve())
    if not Path(video).exists():
        print(f"[!] File not found: {video}")
        sys.exit(1)

    out_jsonl = cache_path_jsonl(video)
    out_curve = cache_path_curve(video)
    failed_marker = cache_path_failed(video)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    if args.force and failed_marker.exists():
        try: failed_marker.unlink()
        except Exception: pass

    # Cache validity check. Reads the SAME keys cabc.lua's try_load_curve
    # reads (src_mtime / src_size) so both sides agree on validity. Do not
    # rename these fields without updating cabc.lua in lockstep.
    if out_jsonl.exists() and out_curve.exists() and not args.force:
        is_valid = False
        try:
            with open(out_curve, "r", encoding="utf-8") as f:
                cdata = json.load(f)
            st = Path(video).stat()
            if "src_mtime" in cdata and "src_size" in cdata:
                if abs(cdata["src_mtime"] - st.st_mtime) <= 1.0 and cdata["src_size"] == st.st_size:
                    is_valid = True
                else:
                    print(f"[*] Source file modified since curve creation. Re-analysing...")
            else:
                is_valid = True
        except Exception:
            is_valid = False

        if is_valid:
            lines = count_lines(out_jsonl)
            print(f"[OK] Already analysed:")
            print(f"    Raw:   {out_jsonl} ({lines:,} frames)")
            print(f"    Curve: {out_curve}")
            if cdata.get("series"):
                peak_summary = summarize_content_peak(cdata["series"])
                print(f"[Peak] max={peak_summary['max_peak_nits'] or 0.0:.1f}n "
                      f"mean={peak_summary['mean_peak_nits'] or 0.0:.1f}n "
                      f"p95={peak_summary['p95_peak_nits'] or 0.0:.1f}n")
            print(f"    Use --force to re-analyse.")
            if failed_marker.exists():
                try: failed_marker.unlink()
                except Exception: pass
            sys.exit(0)

    info = probe_video(video)
    fps = info["fps"]
    codec = info["codec"]
    duration = info.get("duration")
    init_seed = info.get("initial_seed", 203.0)
    print(f"[*] Video info: FPS={fps:.3f}, Duration={duration}, Codec={codec}, "
          f"DOVI={info['is_dovi']}, InitialSeed={init_seed:.1f}n")

    def on_success():
        if failed_marker.exists():
            try: failed_marker.unlink()
            except Exception: pass
        sys.exit(0)

    method = args.method

    # 1. Fast Dolby Vision Pipeline
    if method in ("auto", "dovi"):
        if info["is_dovi"]:
            if run_fast_dovi(video, out_jsonl, out_curve, fps,
                             initial_seed=init_seed, info=info):
                on_success()
        elif method == "dovi":
            print(f"[!] --method dovi requested but this file has no Dolby Vision RPU.")
            sys.exit(1)

    # 2. Fast HDR10+ Pipeline
    if method in ("auto", "hdr10plus"):
        if run_fast_hdr10plus(video, out_jsonl, out_curve, fps,
                              initial_seed=init_seed, info=info):
            on_success()
        elif method == "hdr10plus":
            print(f"[!] --method hdr10plus requested but no HDR10+ dynamic metadata was found.")
            sys.exit(1)

    # 3. Fast FFmpeg Signalstats Pass
    if method in ("auto", "ffmpeg"):
        if run_fast_hdr_ffmpeg(video, out_jsonl, out_curve,
                               codec=codec,
                               initial_seed=init_seed,
                               duration=duration,
                               n_chunks=args.chunks,
                               no_scdet=args.no_scdet,
                               info=info):
            on_success()
        elif method == "ffmpeg":
            print(f"[!] --method ffmpeg requested but the pass failed.")
            sys.exit(1)

    print(f"[!] All extraction and fallback pipelines failed for {video}")
    try:
        with open(failed_marker, "w", encoding="utf-8") as f:
            json.dump({
                "time": time.time(),
                "path": video,
                "error": "All extraction and fallback pipelines failed"
            }, f)
    except Exception:
        pass
    sys.exit(1)


if __name__ == "__main__":
    main()