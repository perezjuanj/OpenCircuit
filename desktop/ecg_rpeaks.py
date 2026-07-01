"""ecg_rpeaks.py — Stage 3: Pan-Tompkins R-peak detection on Apple Watch ECG.

Loads 512 Hz ECG voltage samples from DuckDB (imported from Apple Health export),
applies a Pan-Tompkins QRS detector, and returns R-peak timestamps in Unix wall
clock seconds — aligned with the PPG feature extractor's foot_time_s column.

Output:
  CSV: ecg_rpeaks_<ecg_session_id_short>.csv
  Columns: peak_num, sample_index, wall_clock_s, rr_ms

Usage:
    .venv/bin/python ecg_rpeaks.py --list
    .venv/bin/python ecg_rpeaks.py <ecg_session_id>
    .venv/bin/python ecg_rpeaks.py --date 2026-06-27          # all ECGs from a date
    .venv/bin/python ecg_rpeaks.py <ecg_session_id> --plot
"""
from __future__ import annotations

import argparse
import csv
import sys
from datetime import timezone
from pathlib import Path
from typing import Optional

import duckdb
import numpy as np
from scipy.signal import butter, filtfilt, find_peaks

DEFAULT_DB = Path("/Users/pravinsail/HealthLocal/db/healthlocal.duckdb")
FS = 512.0  # Apple Watch ECG sample rate (Hz)

# ── Pan-Tompkins bandpass: 5–15 Hz isolates QRS complex ─────────────────────
BP_LOW  = 5.0
BP_HIGH = 15.0

# Minimum R-R interval: 0.25s (240 bpm max)
MIN_RR_S = 0.25
MIN_RR_SAMPLES = int(MIN_RR_S * FS)


# ── DuckDB helpers ────────────────────────────────────────────────────────────

def list_sessions(db_path: Path) -> None:
    conn = duckdb.connect(str(db_path), read_only=True)
    rows = conn.execute("""
        SELECT ecg_session_id, file_name, recorded_at, classification, sample_rate_hz, sample_count
        FROM ecg_sessions
        ORDER BY recorded_at DESC
        LIMIT 30
    """).fetchall()
    conn.close()
    if not rows:
        print("No ECG sessions in database.")
        return
    print(f"\n{'ecg_session_id (first 12)':<14}  {'file_name':<30}  {'recorded_at':<20}  {'classification':<18}  Hz  samples")
    print("-" * 110)
    for r in rows:
        print(f"  {str(r[0])[:12]:<14}  {r[1]:<30}  {str(r[2])[:19]:<20}  {(r[3] or ''):<18}  {(r[4] or 0):.0f}  {r[5]}")
    print()


def load_ecg(db_path: Path, session_id: str) -> tuple[np.ndarray, np.ndarray, float]:
    """Returns (times_unix_s, voltage_uv, recorded_at_unix_s).

    times_unix_s: per-sample Unix timestamps derived from recorded_at + sample_index/FS.
    voltage_uv:   raw signal in µV.
    recorded_at_unix_s: start time of recording as Unix timestamp.
    """
    conn = duckdb.connect(str(db_path), read_only=True)

    meta = conn.execute("""
        SELECT recorded_at, sample_rate_hz, sample_count
        FROM ecg_sessions WHERE ecg_session_id = ?
    """, [session_id]).fetchone()

    if not meta:
        print(f"ECG session '{session_id}' not found.")
        sys.exit(1)

    recorded_at, sample_rate, sample_count = meta
    if recorded_at is None:
        print(f"ECG session '{session_id}' has no recorded_at timestamp.")
        sys.exit(1)

    # Convert recorded_at (timezone-aware datetime from DuckDB) to Unix seconds
    if hasattr(recorded_at, "timestamp"):
        rec_unix = recorded_at.timestamp()
    else:
        # Fallback: assume UTC
        from datetime import datetime
        rec_unix = recorded_at.replace(tzinfo=timezone.utc).timestamp()

    rows = conn.execute("""
        SELECT sample_index, value
        FROM ecg_voltage_samples
        WHERE ecg_session_id = ?
        ORDER BY sample_index
    """, [session_id]).fetchall()
    conn.close()

    if not rows:
        print(f"No voltage samples for session '{session_id}'.")
        sys.exit(1)

    indices = np.array([r[0] for r in rows], dtype=float)
    voltage = np.array([r[1] for r in rows], dtype=float)

    # sample_index starts at 1 in the DB (imported with enumerate(samples, start=1))
    times = rec_unix + (indices - 1.0) / FS

    fs_actual = float(sample_rate) if sample_rate else FS
    print(f"  Loaded {len(voltage)} samples  ({len(voltage)/fs_actual:.1f}s at {fs_actual:.0f}Hz)")
    print(f"  recorded_at (UTC): {recorded_at}  →  Unix {rec_unix:.3f}")
    return times, voltage, rec_unix


# ── Pan-Tompkins QRS detector ─────────────────────────────────────────────────

def detect_rpeaks(times: np.ndarray, voltage: np.ndarray) -> np.ndarray:
    """Pan-Tompkins R-peak detector. Returns indices into times/voltage arrays.

    Steps:
      1. Bandpass 5–15 Hz (QRS band)
      2. Derivative (emphasises slopes)
      3. Squaring (non-linearity, always positive)
      4. Moving-window integration (30ms window)
      5. find_peaks with adaptive threshold
    """
    # 1. Bandpass
    b, a = butter(4, [BP_LOW / (FS / 2), BP_HIGH / (FS / 2)], btype="band")
    filtered = filtfilt(b, a, voltage)

    # 2. Derivative (5-point)
    diff = np.diff(filtered, prepend=filtered[0], append=filtered[-1])
    # use central difference
    deriv = np.zeros_like(filtered)
    deriv[1:-1] = (filtered[2:] - filtered[:-2]) / (2.0 / FS)
    deriv[0]  = deriv[1]
    deriv[-1] = deriv[-2]

    # 3. Square
    squared = deriv ** 2

    # 4. Moving-window integration (30ms = 15 samples at 512 Hz)
    win = max(1, int(0.030 * FS))
    kernel = np.ones(win) / win
    integrated = np.convolve(squared, kernel, mode="same")

    # 5. Adaptive threshold + find_peaks
    # Threshold = 50% of the 90th-percentile peak level (handles varying amplitudes)
    threshold = 0.50 * float(np.percentile(integrated, 90))
    peaks, props = find_peaks(
        integrated,
        height=threshold,
        distance=MIN_RR_SAMPLES,
        prominence=threshold * 0.3,
    )

    # Refine: for each detected peak location, find the true R-peak in the original
    # bandpass-filtered signal within ±40ms (the integrated signal lags a little)
    refine_window = int(0.040 * FS)
    refined = []
    for p in peaks:
        lo = max(0, p - refine_window)
        hi = min(len(filtered) - 1, p + refine_window)
        local_max = lo + int(np.argmax(np.abs(filtered[lo:hi + 1])))
        refined.append(local_max)

    return np.array(refined, dtype=int)


# ── Plot ──────────────────────────────────────────────────────────────────────

def plot_ecg(times: np.ndarray, voltage: np.ndarray, peak_indices: np.ndarray,
             title: str = "ECG R-peak detection") -> None:
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        print("  matplotlib not installed — skipping plot")
        return

    fig, ax = plt.subplots(figsize=(14, 4))
    ax.plot(times - times[0], voltage, lw=0.6, color="#1d4ed8", label="ECG (µV)")
    ax.scatter(times[peak_indices] - times[0], voltage[peak_indices],
               s=40, color="red", zorder=5, label=f"R-peaks ({len(peak_indices)})")
    ax.set_xlabel("Time (s from start)")
    ax.set_ylabel("Voltage (µV)")
    ax.set_title(title)
    ax.legend(fontsize=9)
    plt.tight_layout()
    plt.show()


# ── Main ──────────────────────────────────────────────────────────────────────

def run(session_id: str, db_path: Path, do_plot: bool) -> str:
    """Detect R-peaks for one ECG session. Returns path to output CSV."""
    conn_check = duckdb.connect(str(db_path), read_only=True)
    meta = conn_check.execute(
        "SELECT file_name, recorded_at, classification FROM ecg_sessions WHERE ecg_session_id = ?",
        [session_id]
    ).fetchone()
    conn_check.close()

    short_id = session_id[:12]
    print(f"\n=== ECG R-peak Detector ===")
    if meta:
        print(f"  File          : {meta[0]}")
        print(f"  Recorded at   : {meta[1]}")
        print(f"  Classification: {meta[2]}")

    times, voltage, rec_unix = load_ecg(db_path, session_id)

    print("  Running Pan-Tompkins QRS detector...")
    peak_idx = detect_rpeaks(times, voltage)
    print(f"  Detected {len(peak_idx)} R-peaks")

    if len(peak_idx) < 2:
        print("  Too few R-peaks — signal too noisy or wrong session.")
        sys.exit(1)

    # Compute R-R intervals
    peak_times = times[peak_idx]
    rr_ms = np.diff(peak_times) * 1000.0
    mean_rr = float(np.mean(rr_ms))
    hr_bpm = 60000.0 / mean_rr
    print(f"  Mean R-R      : {mean_rr:.0f} ms  ({hr_bpm:.1f} bpm)")
    print(f"  HRV (RMSSD)   : {float(np.sqrt(np.mean(np.diff(rr_ms)**2))):.1f} ms")

    # Write CSV
    out_csv = f"ecg_rpeaks_{short_id}.csv"
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ecg_session_id", "peak_num", "sample_index",
                    "wall_clock_s", "rr_ms"])
        for i, idx in enumerate(peak_idx):
            rr = float(rr_ms[i - 1]) if i > 0 else None
            w.writerow([session_id, i + 1, int(idx), f"{times[idx]:.6f}",
                        f"{rr:.2f}" if rr else ""])

    print(f"  R-peaks CSV   : {out_csv}")

    if do_plot:
        label = f"{(meta[0] if meta else session_id)} — {hr_bpm:.0f} bpm"
        plot_ecg(times, voltage, peak_idx, title=label)

    return out_csv


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("session_id", nargs="?",
                   help="ecg_session_id from ecg_sessions (use --list to find)")
    p.add_argument("--list", action="store_true",
                   help="List ECG sessions and exit")
    p.add_argument("--date", default=None,
                   help="Run all ECGs from a date, e.g. 2026-06-27")
    p.add_argument("--db", default=str(DEFAULT_DB),
                   help=f"DuckDB path (default: {DEFAULT_DB})")
    p.add_argument("--plot", action="store_true",
                   help="Show ECG + R-peaks plot")
    args = p.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        print(f"DuckDB not found at {db_path}")
        sys.exit(1)

    if args.list:
        list_sessions(db_path)
        return

    if args.date:
        conn = duckdb.connect(str(db_path), read_only=True)
        rows = conn.execute("""
            SELECT ecg_session_id, file_name
            FROM ecg_sessions
            WHERE strftime(recorded_at, '%Y-%m-%d') = ?
            ORDER BY recorded_at
        """, [args.date]).fetchall()
        conn.close()
        if not rows:
            print(f"No ECG sessions found for date {args.date}")
            sys.exit(1)
        print(f"Processing {len(rows)} ECG sessions from {args.date}...")
        for sid, fname in rows:
            print(f"\n--- {fname} ---")
            run(sid, db_path, args.plot)
        return

    if not args.session_id:
        p.print_help()
        sys.exit(1)

    run(args.session_id, db_path, args.plot)


if __name__ == "__main__":
    main()
