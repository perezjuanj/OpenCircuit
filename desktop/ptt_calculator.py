"""ptt_calculator.py — Stage 3: Pulse Transit Time from ECG R-peaks + PPG feet.

For each calibration reading window:
  - Loads ECG R-peak timestamps (from ecg_rpeaks_*.csv)
  - Loads PPG pulse feet timestamps (from ppg_features_*.csv)
  - Computes PTT = time from each R-peak to the NEXT PPG foot
  - Filters to physiologically valid PTT: 100–500ms (finger from wrist)
  - Averages per reading window and links to cuff BP from calibration JSON

Output:
  ptt_calibration_<timestamp>.csv — one row per reading:
    reading_num, sbp_mmhg, dbp_mmhg, mean_ptt_ms, n_ptt,
    mean_ai_pct, mean_ri, mean_rise_ms, mean_pw50_ms

This is the combined feature table for bp_calibration.py.

Usage:
    .venv/bin/python ptt_calculator.py calibration_rest_20260627_205748.json
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Optional

import numpy as np

# Physiologically valid PTT range for wrist ECG → finger PPG
PTT_MIN_MS = 100.0
PTT_MAX_MS = 500.0


# ── Loaders ───────────────────────────────────────────────────────────────────

def load_rpeaks(csv_path: Path) -> np.ndarray:
    """Returns sorted array of R-peak wall_clock_s values."""
    times = []
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            if row.get("wall_clock_s"):
                times.append(float(row["wall_clock_s"]))
    return np.array(sorted(times))


def load_ppg_feet(csv_path: Path) -> np.ndarray:
    """Returns sorted array of pulse foot_time_s values."""
    times = []
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            if row.get("foot_time_s"):
                times.append(float(row["foot_time_s"]))
    return np.array(sorted(times))


def load_ppg_features_window(csv_path: Path, t0: float, t1: float) -> list[dict]:
    """Returns feature rows whose foot_time_s falls in [t0, t1]."""
    rows = []
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            ft = row.get("foot_time_s")
            if ft and t0 <= float(ft) <= t1:
                rows.append(row)
    return rows


# ── PTT computation ───────────────────────────────────────────────────────────

def compute_ptt(r_times: np.ndarray, foot_times: np.ndarray,
                t0: float, t1: float) -> list[float]:
    """For each R-peak within [t0, t1], find the next PPG foot and return PTT in ms."""
    ptts: list[float] = []
    # Only consider R-peaks in the window
    mask = (r_times >= t0) & (r_times <= t1)
    window_peaks = r_times[mask]

    for rt in window_peaks:
        # Find feet that come after this R-peak
        candidates = foot_times[foot_times > rt]
        if len(candidates) == 0:
            continue
        nearest_foot = candidates[0]
        ptt_ms = (nearest_foot - rt) * 1000.0
        if PTT_MIN_MS <= ptt_ms <= PTT_MAX_MS:
            ptts.append(ptt_ms)

    return ptts


def avg(vals: list, key: Optional[str] = None) -> Optional[float]:
    if key:
        nums = [float(r[key]) for r in vals if r.get(key) and r[key] != ""]
    else:
        nums = [v for v in vals if v is not None]
    return float(np.mean(nums)) if nums else None


# ── Main ──────────────────────────────────────────────────────────────────────

def run(cal_json_path: Path) -> None:
    cal = json.loads(cal_json_path.read_text())
    desktop = cal_json_path.parent

    ppg_features_path = desktop / f"ppg_features_{cal.get('ppg_session_id', '')}.csv"
    # Try to find it by glob if session_id not in JSON
    if not ppg_features_path.exists():
        candidates = sorted(desktop.glob("ppg_features_*.csv"),
                            key=lambda p: p.stat().st_mtime, reverse=True)
        if not candidates:
            print("No ppg_features_*.csv found. Run ppg_feature_extractor.py first.")
            sys.exit(1)
        # Pick the most recently modified one — probably the calibration session
        ppg_features_path = candidates[0]
        print(f"  Using PPG features: {ppg_features_path.name}")

    # Find ECG R-peak CSVs in desktop (all from today)
    rpeak_files = sorted(desktop.glob("ecg_rpeaks_*.csv"))
    if not rpeak_files:
        print("No ecg_rpeaks_*.csv found. Run ecg_rpeaks.py --date <date> first.")
        sys.exit(1)

    # Load all R-peaks from all ECG files (pool them — each file covers 30s)
    all_rpeaks = np.array([], dtype=float)
    for f in rpeak_files:
        rp = load_rpeaks(f)
        print(f"  {f.name}: {len(rp)} R-peaks")
        all_rpeaks = np.concatenate([all_rpeaks, rp])
    all_rpeaks = np.sort(all_rpeaks)
    print(f"  Total R-peaks pooled: {len(all_rpeaks)}")

    # Load PPG foot times
    all_feet = load_ppg_feet(ppg_features_path)
    print(f"  PPG feet loaded: {len(all_feet)}")

    print(f"\n{'='*70}")
    print(f"  State: {cal['state']}   PPG: {cal['ppg_csv']}")
    print(f"{'='*70}")

    out_rows: list[dict] = []

    for rd in cal["readings"]:
        t0 = rd["start_wall_s"]
        t1 = rd["end_wall_s"]
        sbp = rd["sbp_mmhg"]
        dbp = rd["dbp_mmhg"]

        # PTT for this window
        ptts = compute_ptt(all_rpeaks, all_feet, t0, t1)

        # PPG morphology features for this window
        feat_rows = load_ppg_features_window(ppg_features_path, t0, t1)
        notch_rows = [r for r in feat_rows if r.get("has_notch") == "True"]

        mean_ptt = avg(ptts) if ptts else None
        mean_ai  = avg(notch_rows, "ai_pct")
        mean_ri  = avg(notch_rows, "ri")
        mean_si  = avg(notch_rows, "si_raw_s")
        mean_rise = avg(feat_rows, "rise_time_ms")
        mean_pw50 = avg(feat_rows, "pw50_ms")

        row = {
            "reading_num": rd["reading_num"],
            "sbp_mmhg": sbp,
            "dbp_mmhg": dbp,
            "mean_ptt_ms": f"{mean_ptt:.1f}" if mean_ptt else "",
            "n_ptt": len(ptts),
            "mean_ai_pct": f"{mean_ai:.2f}" if mean_ai else "",
            "mean_ri": f"{mean_ri:.4f}" if mean_ri else "",
            "mean_si_raw_s": f"{mean_si:.4f}" if mean_si else "",
            "mean_rise_ms": f"{mean_rise:.1f}" if mean_rise else "",
            "mean_pw50_ms": f"{mean_pw50:.1f}" if mean_pw50 else "",
            "n_ppg_pulses": len(feat_rows),
            "n_notch_pulses": len(notch_rows),
        }
        out_rows.append(row)

        print(f"\n  Reading {rd['reading_num']}: {sbp}/{dbp} mmHg")
        print(f"    PTT          : {mean_ptt:.1f} ms  (n={len(ptts)})" if mean_ptt else
              f"    PTT          : no valid PTT in window")
        print(f"    AI%          : {mean_ai:.1f}%   (n={len(notch_rows)})" if mean_ai else
              f"    AI%          : n/a (no notch)")
        print(f"    RI           : {mean_ri:.4f}" if mean_ri else "    RI           : n/a")
        print(f"    SI raw (ms)  : {mean_si*1000:.1f}" if mean_si else "    SI raw       : n/a")
        print(f"    Rise time(ms): {mean_rise:.1f}" if mean_rise else "    Rise time     : n/a")
        print(f"    PW50 (ms)    : {mean_pw50:.1f}" if mean_pw50 else "    PW50          : n/a")

    # Write combined feature table
    ts = cal["timestamp"]
    out_csv = f"ptt_calibration_{ts}.csv"
    fieldnames = ["reading_num", "sbp_mmhg", "dbp_mmhg",
                  "mean_ptt_ms", "n_ptt",
                  "mean_ai_pct", "mean_ri", "mean_si_raw_s",
                  "mean_rise_ms", "mean_pw50_ms",
                  "n_ppg_pulses", "n_notch_pulses"]

    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(out_rows)

    print(f"\n  Combined feature table: {out_csv}")
    print(f"  → Feed this into bp_calibration.py once you have all 3 sessions.")


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("cal_json",
                   help="calibration_<state>_<timestamp>.json from calibration_session.py")
    args = p.parse_args()

    cal_path = Path(args.cal_json)
    if not cal_path.exists():
        print(f"File not found: {cal_path}")
        sys.exit(1)

    run(cal_path)


if __name__ == "__main__":
    main()
