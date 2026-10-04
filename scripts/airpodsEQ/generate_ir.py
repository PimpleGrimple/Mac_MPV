#!/usr/bin/env -S pipx run --path
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "numpy",
#     "scipy",
# ]
# ///
"""
Audio Processing Tool: Measurement-Curve FIR Correction Generator

Reads two raw frequency-response measurement files (2-column: freq, dB) --
an ORIGINAL curve and a TARGET curve -- and generates a minimum-phase FIR
filter that reshapes ORIGINAL to sound like TARGET, exported as a stereo
.wav impulse response for mpv's afir convolution filter.

SETUP (once):
    chmod +x generate_ir.py

USAGE EXAMPLES:
    1. Match your AirPods to the Truthear Zero (RED):
        ./generate_ir.py Apple_AirPods_Pro_2__Use_ISO_11904-2__AVG.txt Truthear_Zero__RED_AVG.txt

    2. Match any other pair of measurement curves:
        ./generate_ir.py my_original_raw.txt my_target_raw.txt

No "python3" and no typing "pipx run" needed -- the shebang on line 1 does
that for you. It builds a throwaway numpy/scipy environment from the
dependency list embedded at the top of this file the first time it's run,
then reuses it on later runs.

ARGUMENTS:
    orig    Path to the measured ORIGINAL curve, i.e. the "before" sound.
            Required.
    target  Path to the measured TARGET curve, i.e. the "after" sound you
            want to match. Required.

LEVEL MATCHING (automatic, no flag needed):
    Two measurement files are almost never captured at the same absolute
    output level. Before any correction is computed, this script measures
    the average difference between the two curves over REF_BAND (200 Hz -
    8 kHz, see constant below) and subtracts it from the whole curve, so
    the result reflects only the actual tonal/shape difference -- not
    which file happened to be recorded louder. This always runs; it's
    printed to the console every time so you can see the offset removed.

Output: airpods_ir.wav, always written next to this script -- exactly
where main.lua expects to find it, regardless of what you named your
input files.
"""

import os
import sys
import argparse
import numpy as np
from scipy.io import wavfile
from scipy.signal import minimum_phase

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

SAMPLE_RATE = 48000
FFT_SIZE = 4096

# Frequencies (Hz) used to level-match the two measurement files. Different
# measurement files are rarely captured at the same absolute output level,
# so we remove the average offset over this band before doing anything else
# -- otherwise the "correction" would mostly just be a giant volume boost.
REF_BAND = (200.0, 8000.0)

# Cap how hard any single frequency gets pushed. Without this, the natural
# rolloff at the very top of the AirPods' response (see note below) would
# demand 40-60 dB of boost there, which is neither audible nor safe.
MAX_CORRECTION_DB = 12.0

# Above this frequency the correction is faded out linearly to 0 dB by
# TAPER_END_HZ. This is specifically for the AirPods Pro 2 vs. Truthear Zero
# pairing: the AirPods measurement rolls off hard above ~16.5 kHz (driver +
# ANC feedback mic behavior), which the Truthear doesn't. That gap is a
# structural limit of the driver, not something a linear filter should chase.
TAPER_START_HZ = 15000.0
TAPER_END_HZ = 20000.0


def parse_curve_file(filepath):
    """Parses whitespace-separated 'frequency  dB' lines from a text file."""
    data = {}
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                try:
                    data[float(parts[0])] = float(parts[1])
                except ValueError:
                    continue
    if not data:
        raise ValueError(f"No frequency/dB pairs found in {filepath}")
    return data


def build_correction_curve(orig_path, target_path):
    orig = parse_curve_file(orig_path)
    target = parse_curve_file(target_path)

    freq_grid = np.linspace(0, SAMPLE_RATE // 2, (FFT_SIZE // 2) + 1)

    orig_f = np.array(sorted(orig.keys()))
    orig_g = np.array([orig[f] for f in orig_f])
    target_f = np.array(sorted(target.keys()))
    target_g = np.array([target[f] for f in target_f])

    orig_interp = np.interp(freq_grid, orig_f, orig_g)
    target_interp = np.interp(freq_grid, target_f, target_g)

    delta_db = target_interp - orig_interp

    ref_mask = (freq_grid >= REF_BAND[0]) & (freq_grid <= REF_BAND[1])
    offset = delta_db[ref_mask].mean()
    delta_db = delta_db - offset
    print(f"[generate_ir] Removed {offset:+.1f} dB average level offset between the two measurements.")

    clipped = np.abs(delta_db) > MAX_CORRECTION_DB
    if clipped.any():
        print(f"[generate_ir] Clamping {clipped.sum()} of {len(delta_db)} points to +/-{MAX_CORRECTION_DB} dB.")
    delta_db = np.clip(delta_db, -MAX_CORRECTION_DB, MAX_CORRECTION_DB)

    taper = np.ones_like(freq_grid)
    above = freq_grid > TAPER_START_HZ
    taper[above] = np.clip(
        1.0 - (freq_grid[above] - TAPER_START_HZ) / (TAPER_END_HZ - TAPER_START_HZ),
        0.0, 1.0,
    )
    delta_db = delta_db * taper

    return freq_grid, delta_db


def curve_to_min_phase_ir(delta_db):
    magnitude = 10.0 ** (delta_db / 20.0)
    full_magnitude = np.concatenate([magnitude, magnitude[-2:0:-1]])
    impulse_linear = np.fft.ifft(full_magnitude).real
    impulse_linear = np.fft.fftshift(impulse_linear)
    return minimum_phase(impulse_linear)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "orig",
        help="Path to the measured ORIGINAL curve, the 'before'.",
    )
    parser.add_argument(
        "target",
        help="Path to the measured TARGET curve, the 'after'.",
    )
    args = parser.parse_args()

    for p in (args.orig, args.target):
        if not os.path.exists(p):
            print(f"[generate_ir] ERROR: file not found: {p}", file=sys.stderr)
            sys.exit(1)

    print(f"[generate_ir] Original : {os.path.basename(args.orig)}")
    print(f"[generate_ir] Target   : {os.path.basename(args.target)}")

    _, delta_db = build_correction_curve(args.orig, args.target)
    ir = curve_to_min_phase_ir(delta_db)

    # Both measurement files are single (averaged) curves rather than
    # separate L/R channels, so the same correction is applied to both ears.
    stereo_ir = np.vstack([ir, ir]).T.astype(np.float32)

    output_path = os.path.join(SCRIPT_DIR, "airpods_ir.wav")
    wavfile.write(output_path, SAMPLE_RATE, stereo_ir)
    print(f"[generate_ir] Wrote {len(ir)}-tap correction filter to:\n  {output_path}")


if __name__ == "__main__":
    main()