#!/usr/bin/env python3
import sys
import ctypes
import time
import argparse

DISPLAY_ID = 1

def get_ds():
    try:
        ds = ctypes.CDLL("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
    except Exception as e:
        print(f"[!] Failed to load DisplayServices framework: {e}")
        sys.exit(1)

    b_type = ctypes.c_float
    ds.DisplayServicesGetLinearBrightness.argtypes = [ctypes.c_uint32, ctypes.POINTER(b_type)]
    ds.DisplayServicesGetLinearBrightness.restype = ctypes.c_int
    ds.DisplayServicesSetBrightness.argtypes = [ctypes.c_uint32, b_type]
    ds.DisplayServicesSetBrightness.restype = ctypes.c_int
    ds.DisplayServicesGetBrightness.argtypes = [ctypes.c_uint32, ctypes.POINTER(b_type)]
    ds.DisplayServicesGetBrightness.restype = ctypes.c_int
    ds.DisplayServicesSetLinearBrightness.argtypes = [ctypes.c_uint32, b_type]
    ds.DisplayServicesSetLinearBrightness.restype = ctypes.c_int
    return ds, b_type


# Every DisplayServices call returns an int status code (0 = success). None of
# these were being checked previously -- a transient failure would silently
# leave whatever stale value was already in the ctypes buffer, and the script
# would carry on as if the read/write had actually happened. This is exactly
# the class of bug that caused a real, confirmed issue elsewhere in this
# project (a silently-stale desktop-brightness value from an unchecked read).
# Lower stakes here since this is a manual, one-shot diagnostic tool you watch
# run rather than something unattended in the background -- but a calibration
# tool specifically should not silently fold a failed read into its own output
# table, so failures are surfaced, not swallowed.
def set_brightness(ds, val):
    ret = ds.DisplayServicesSetBrightness(DISPLAY_ID, val)
    if ret != 0:
        print(f"[!] Warning: DisplayServicesSetBrightness({val:.6f}) returned {ret} (expected 0)")
    return ret == 0

def get_brightness(ds, buf):
    ret = ds.DisplayServicesGetBrightness(DISPLAY_ID, ctypes.byref(buf))
    if ret != 0:
        print(f"[!] Warning: DisplayServicesGetBrightness returned {ret} (expected 0)")
    return ret == 0

def set_linear_brightness(ds, val):
    ret = ds.DisplayServicesSetLinearBrightness(DISPLAY_ID, val)
    if ret != 0:
        print(f"[!] Warning: DisplayServicesSetLinearBrightness({val:.6f}) returned {ret} (expected 0)")
    return ret == 0

def get_linear_brightness(ds, buf):
    ret = ds.DisplayServicesGetLinearBrightness(DISPLAY_ID, ctypes.byref(buf))
    if ret != 0:
        print(f"[!] Warning: DisplayServicesGetLinearBrightness returned {ret} (expected 0)")
    return ret == 0


def main():
    print("\n--- macOS Hardware Brightness Calibrator ---")
    parser = argparse.ArgumentParser(description="Find exact macOS slider float for a target nit value.")
    parser.add_argument("nits", type=float, nargs="?", default=None, help="Target brightness in nits (e.g., 280, 404)")
    parser.add_argument("--max-nits", type=float, default=500.0, help="Maximum nits of your display (default: 500.0)")
    parser.add_argument("--dump-table", action="store_true", help="Dump all 501 points (0 to max-nits) as a formatted table")
    parser.add_argument("--binary-search", action="store_true", help="Force slow hardware sensor binary search with flicker")
    args = parser.parse_args()

    ds, b_type = get_ds()

    # Read original brightness to restore it later
    orig = b_type()
    if not get_brightness(ds, orig):
        print("[!] Could not read current brightness -- restoring on exit may not return to the true original value.")

    if args.dump_table:
        print(f"[*] Sweeping 0 to {args.max_nits:.0f} nits via DisplayServices...")
        try:
            points = []
            failed_points = 0
            for n in range(int(args.max_nits) + 1):
                if n == 0:
                    points.append((0, 0.0))
                    continue
                lin = n / args.max_nits
                ok_set = set_linear_brightness(ds, lin)
                s = b_type()
                ok_get = get_brightness(ds, s)
                if not (ok_set and ok_get):
                    failed_points += 1
                points.append((n, round(s.value, 6)))
        finally:
            set_brightness(ds, orig.value)

        print("\n================ 501-POINT CALIBRATION TABLE ================")
        for i in range(0, len(points), 10):
            chunk = points[i:i+10]
            values_str = ", ".join(f"{v[1]:.6f}" for v in chunk) + ","
            print(f"    {values_str:<78} # {chunk[0][0]:3d}-{chunk[-1][0]:3d} nits")
        print("=============================================================")
        if failed_points > 0:
            print(f"[!] {failed_points} point(s) above had a failed read or write -- treat this table with caution.")
        return

    if args.nits is None:
        parser.print_help()
        sys.exit(1)

    target_nits = args.nits
    max_nits = args.max_nits
    target_linear = target_nits / max_nits

    if target_linear < 0.0 or target_linear > 1.0:
        print(f"\n[!] Error: Target {target_nits} nits is outside the display limits (0 - {max_nits}).")
        sys.exit(1)

    print(f"[*] Target Nits: {target_nits}")
    print(f"[*] Target Linear Light: {target_linear:.6f}")

    ok = True
    if args.binary_search:
        print("[*] Running live hardware binary search...")
        print("[!] Please wait (your screen will rapidly flicker for ~1 second)...\n")
        low = 0.0
        high = 1.0
        best_val = orig.value
        try:
            for i in range(17):
                mid = (low + high) / 2.0
                ok = set_brightness(ds, mid) and ok
                time.sleep(0.04)
                lin = b_type()
                ok = get_linear_brightness(ds, lin) and ok
                if lin.value < target_linear:
                    low = mid
                else:
                    high = mid
                best_val = mid

            ok = set_brightness(ds, best_val) and ok
            time.sleep(0.05)
            final_lin = b_type()
            ok = get_linear_brightness(ds, final_lin) and ok
            final_nits = final_lin.value * max_nits
        finally:
            set_brightness(ds, orig.value)
    else:
        print("[*] Instant hardware calibration query (<1ms, no flicker)...")
        try:
            if target_nits <= 0:
                best_val = 0.0
                final_nits = 0.0
            else:
                ok = set_linear_brightness(ds, target_linear) and ok
                s = b_type()
                ok = get_brightness(ds, s) and ok
                best_val = s.value
                final_lin = b_type()
                ok = get_linear_brightness(ds, final_lin) and ok
                final_nits = final_lin.value * max_nits
        finally:
            set_brightness(ds, orig.value)

    if not ok:
        print("\n[!] One or more hardware calls failed above -- the result below may not be reliable.")

    print("\n================ SUCCESS ================")
    print(f"Copy/Paste this Float: {best_val:.6f}")
    print(f"Actual Hardware Output: {final_nits:.2f} nits")
    print("=========================================\n")

if __name__ == "__main__":
    main()
