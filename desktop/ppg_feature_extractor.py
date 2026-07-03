"""ppg_feature_extractor.py — Stage 3 Step 1: Per-pulse morphology feature extraction.

Loads bandpass-filtered chA (GREEN) PPG frames from DuckDB for a given session,
segments them into individual pulses (foot-to-foot), upsamples to 100 Hz via cubic
spline for better dicrotic-notch resolution, and extracts per-pulse features:

  rise_time_ms  — foot → systolic peak (ms)
  pw50_ms       — pulse width at 50% amplitude (FWHM proxy)
  ai_pct        — Augmentation Index = (D - N) / (S - foot) × 100
                  correlates with arterial stiffness → SBP
  ri            — Reflection Index = (D - foot) / (S - foot)
  si_raw_s      — time between systolic and diastolic peaks (s); multiply by 1/height
                  for Stiffness Index = height_m / si_raw_s
  has_notch     — whether a dicrotic notch was reliably detected

Output:
  CSV: ppg_features_<session_id>.csv  (always)
  Prints per-pulse summary + per-session stats

Usage:
    .venv/bin/python ppg_feature_extractor.py --list
    .venv/bin/python ppg_feature_extractor.py <session_id>
    .venv/bin/python ppg_feature_extractor.py <session_id> --height-cm 170 --plot
    .venv/bin/python ppg_feature_extractor.py <session_id> --db /path/to/healthlocal.duckdb
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from pathlib import Path
from typing import Optional

import duckdb
import numpy as np
from scipy.interpolate import CubicSpline
from scipy.signal import find_peaks

# ── Constants ─────────────────────────────────────────────────────────────────
FS_RAW = 25.0          # ring PPG sample rate (Hz)
FS_UP = 100.0          # upsample target (Hz)  — 10ms resolution for notch detection
UP_FACTOR = int(FS_UP / FS_RAW)   # = 4

MIN_PULSE_S = 0.40     # shortest plausible pulse (150 bpm)
MAX_PULSE_S = 1.80     # longest plausible pulse (33 bpm)
MIN_PULSE_SAMPLES_UP = int(MIN_PULSE_S * FS_UP)   # at 100 Hz
MAX_PULSE_SAMPLES_UP = int(MAX_PULSE_S * FS_UP)

NOTCH_SEARCH_START = 0.10   # fraction of pulse to start looking for notch after peak
NOTCH_SEARCH_END = 0.75     # fraction of pulse where diastolic peak must end by

DEFAULT_DB = Path.home() / "HealthLocal" / "db" / "healthlocal.duckdb"


# ── DuckDB helpers ────────────────────────────────────────────────────────────

def list_sessions(db_path: Path) -> None:
    conn = duckdb.connect(str(db_path), read_only=True)
    rows = conn.execute("""
        SELECT session_id, captured_at, duration_s, total_frames, mean_hr_bpm,
               mean_spo2_pct, contact_ratio, csv_filename
        FROM ppg_sessions
        ORDER BY captured_at DESC
        LIMIT 30
    """).fetchall()
    conn.close()

    if not rows:
        print("No PPG sessions in database.")
        return

    print(f"\n{'session_id':<20}  {'captured_at':<20}  {'dur_s':>6}  {'frames':>6}  "
          f"{'hr_bpm':>6}  {'spo2':>5}  {'contact':>7}  csv_filename")
    print("-" * 110)
    for r in rows:
        sid, cap, dur, frames, hr, spo2, contact, fname = r
        print(f"{(sid or ''):<20}  {str(cap)[:19]:<20}  {(dur or 0):>6.0f}  "
              f"{(frames or 0):>6}  {(hr or 0):>6.1f}  {(spo2 or 0):>5.1f}  "
              f"{(contact or 0):>7.2f}  {fname or ''}")
    print()


def load_frames(db_path: Path, session_id: str) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Returns (times_s, chA_filt, contact) arrays, contact-filtered.

    wall_clock_s is identical for all 25 samples within one 25-Hz frame — we
    reconstruct a strictly-increasing per-sample timestamp using sample_idx so
    the cubic-spline upsampler gets a monotonic x axis.
    """
    conn = duckdb.connect(str(db_path), read_only=True)
    rows = conn.execute("""
        SELECT wall_clock_s, sample_idx, chA_filt, contact
        FROM ppg_frames
        WHERE session_id = ?
        ORDER BY sample_idx
    """, [session_id]).fetchall()
    conn.close()

    if not rows:
        print(f"No frames found for session '{session_id}'.")
        sys.exit(1)

    wall_s = np.array([r[0] for r in rows], dtype=float)
    sidx   = np.array([r[1] for r in rows], dtype=int)
    sig    = np.array([r[2] for r in rows], dtype=float)
    con    = np.array([r[3] for r in rows], dtype=int)

    # Reconstruct per-sample times anchored to the session wall clock.
    # wall_clock_s is the same for all 25 samples in one BLE frame, so we use
    # sample_idx (global monotonic counter) to build a strictly-increasing axis.
    t = wall_s[0] + (sidx - sidx[0]) / FS_RAW

    print(f"  Loaded {len(t)} samples  ({len(t)/FS_RAW:.1f}s at 25 Hz)")
    print(f"  Contact coverage: {100*con.mean():.1f}%")
    return t, sig, con


# ── Signal processing ─────────────────────────────────────────────────────────

MIN_SEGMENT_SAMPLES = 50   # 2s at 25 Hz — minimum contact run worth processing


def contact_runs(con: np.ndarray, min_len: int = MIN_SEGMENT_SAMPLES) -> list[tuple[int, int]]:
    """Return (start, end) index pairs for runs of contact==1 with len >= min_len."""
    runs: list[tuple[int, int]] = []
    in_run = False
    start = 0
    for i, c in enumerate(con):
        if c == 1 and not in_run:
            in_run = True
            start = i
        elif c != 1 and in_run:
            in_run = False
            if i - start >= min_len:
                runs.append((start, i))
    if in_run and len(con) - start >= min_len:
        runs.append((start, len(con)))
    return runs


def upsample_segment(t: np.ndarray, sig: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Cubic spline upsample one continuous contact segment from 25 Hz → 100 Hz.

    Clips AGC spike outliers to [p2, p98] before splining so that transients from
    IIR filter re-initialization don't distort the upsampled waveform.
    """
    lo, hi = np.percentile(sig, 2), np.percentile(sig, 98)
    sig_clipped = np.clip(sig, lo, hi)
    cs = CubicSpline(t, sig_clipped)
    t_up = np.linspace(t[0], t[-1], num=len(t) * UP_FACTOR)
    return t_up, cs(t_up)


def find_feet(sig_up: np.ndarray) -> np.ndarray:
    """Find pulse foot indices in the 100-Hz upsampled signal.

    Uses the 5th–95th percentile range (robust to AGC spikes) for prominence.
    30% of that robust range suppresses dicrotic-notch false-positives while
    passing true pulse feet (which form the deepest valleys in the clean signal).
    """
    min_dist = int(MIN_PULSE_S * FS_UP)
    robust_range = float(np.percentile(sig_up, 95) - np.percentile(sig_up, 5))
    valleys, _ = find_peaks(
        -sig_up,
        distance=min_dist,
        prominence=max(0.30 * robust_range, 1e-6),
    )
    return valleys


# ── Per-pulse feature extraction ──────────────────────────────────────────────

def extract_pulse_features(
    t_up: np.ndarray,
    seg: np.ndarray,
    height_m: Optional[float],
) -> Optional[dict]:
    """
    Given one pulse segment (foot-to-foot, 100 Hz), extract morphology features.
    Returns None if the segment is invalid or too noisy.
    """
    n = len(seg)
    if n < MIN_PULSE_SAMPLES_UP or n > MAX_PULSE_SAMPLES_UP:
        return None

    foot_val = seg[0]
    amplitude = seg.max() - foot_val
    if amplitude < 1e-6:
        return None  # flat segment

    # Systolic peak
    peak_idx = int(np.argmax(seg))
    peak_val = seg[peak_idx]
    peak_time = t_up[peak_idx]
    foot_time = t_up[0]

    rise_time_ms = (peak_time - foot_time) * 1000.0

    # Pulse width at 50% amplitude (FWHM proxy)
    half_amp = foot_val + 0.5 * amplitude
    above = np.where(seg >= half_amp)[0]
    pw50_ms = ((t_up[above[-1]] - t_up[above[0]]) * 1000.0) if len(above) >= 2 else None

    # Dicrotic notch + diastolic peak search
    # Search only in the post-systolic window (after peak, before 75% of segment end)
    search_start = peak_idx + max(1, int(NOTCH_SEARCH_START * n))
    search_end = int(NOTCH_SEARCH_END * n)
    has_notch = False
    ai_pct: Optional[float] = None
    ri: Optional[float] = None
    si_raw_s: Optional[float] = None
    diastolic_val: Optional[float] = None

    if search_end > search_start + 4:
        post_peak = seg[search_start:search_end]
        # Find notch: deepest valley after systolic peak
        notch_local, notch_props = find_peaks(
            -post_peak,
            distance=3,
            prominence=0.02 * amplitude,  # > 2% of amplitude
        )
        if len(notch_local) > 0:
            notch_idx_local = notch_local[np.argmin(post_peak[notch_local])]
            notch_idx = search_start + notch_idx_local
            notch_val = seg[notch_idx]

            # Diastolic peak: max after notch
            if notch_idx + 2 < search_end:
                dias_local = int(np.argmax(seg[notch_idx + 1:search_end])) + notch_idx + 1
                dias_val = seg[dias_local]
                dias_time = t_up[dias_local]

                if dias_val > notch_val:
                    has_notch = True
                    diastolic_val = dias_val
                    ai_pct = 100.0 * (dias_val - notch_val) / amplitude
                    ri = (dias_val - foot_val) / amplitude
                    si_raw_s = dias_time - peak_time

    feat: dict = {
        "foot_time_s": float(foot_time),
        "peak_time_s": float(peak_time),
        "duration_ms": float((t_up[-1] - t_up[0]) * 1000.0),
        "amplitude": float(amplitude),
        "rise_time_ms": float(rise_time_ms),
        "pw50_ms": float(pw50_ms) if pw50_ms is not None else None,
        "has_notch": has_notch,
        "ai_pct": round(ai_pct, 2) if ai_pct is not None else None,
        "ri": round(ri, 4) if ri is not None else None,
        "si_raw_s": round(si_raw_s, 4) if si_raw_s is not None else None,
    }

    if height_m and si_raw_s and si_raw_s > 0:
        feat["si_m_per_s"] = round(height_m / si_raw_s, 2)

    return feat


# ── Optional plot ─────────────────────────────────────────────────────────────

def plot_session(
    t_up: np.ndarray,
    sig_up: np.ndarray,
    feet: np.ndarray,
    pulses: list[dict],
) -> None:
    try:
        import matplotlib.pyplot as plt
        import matplotlib.patches as mpatches
    except ImportError:
        print("  matplotlib not installed — skipping plot")
        return

    fig, axes = plt.subplots(2, 1, figsize=(14, 8), sharex=True)

    # Top: waveform with detected feet
    ax = axes[0]
    ax.plot(t_up, sig_up, lw=0.6, color="#2563eb", label="chA filtered (100 Hz)")
    foot_times = [t_up[f] for f in feet]
    foot_vals  = [sig_up[f] for f in feet]
    ax.scatter(foot_times, foot_vals, s=30, color="red", zorder=5, label="pulse feet")
    ax.set_ylabel("Amplitude (filtered)")
    ax.set_title("PPG Waveform — pulse segmentation")
    ax.legend(fontsize=8)

    # Bottom: per-pulse features over time
    ax2 = axes[1]
    valid = [p for p in pulses if p and p.get("has_notch") and p.get("ai_pct") is not None]
    if valid:
        ptimes = [p["foot_time_s"] for p in valid]
        ai_vals = [p["ai_pct"] for p in valid]
        ax2.plot(ptimes, ai_vals, "o-", ms=4, color="#16a34a", label="AI%")
        ax2.set_ylabel("Augmentation Index (%)")
        ax2.set_title("Per-pulse Augmentation Index (AI) — correlates with SBP")
        ax2.legend(fontsize=8)
    else:
        ax2.text(0.5, 0.5, "No dicrotic notch detected — signal quality too low",
                 ha="center", va="center", transform=ax2.transAxes, color="red")

    ax2.set_xlabel("Wall clock (s)")
    plt.tight_layout()
    plt.show()


# ── Main ──────────────────────────────────────────────────────────────────────

def run(session_id: str, db_path: Path, height_cm: Optional[float], do_plot: bool) -> None:
    height_m = height_cm / 100.0 if height_cm else None

    print(f"\n=== PPG Feature Extractor — session: {session_id} ===")
    print(f"  DB : {db_path}")

    t_raw, sig_raw, contact = load_frames(db_path, session_id)

    # Split into continuous contact runs and process each independently.
    # Upsampling the whole session over non-contact gaps produces cubic-spline
    # artefacts that defeat the valley detector — segment processing avoids this.
    runs = contact_runs(contact, min_len=MIN_SEGMENT_SAMPLES)
    total_contact = sum(e - s for s, e in runs)
    print(f"  Contact runs: {len(runs)} (≥{MIN_SEGMENT_SAMPLES} samples each, "
          f"{total_contact} total = {total_contact/FS_RAW:.1f}s)")

    if not runs:
        print("  No usable contact segments — check ring fit.")
        sys.exit(1)

    all_pulses: list[dict] = []
    seg_t_up_list: list[np.ndarray] = []
    seg_s_up_list: list[np.ndarray] = []
    seg_feet_list: list[np.ndarray] = []
    pulse_num = 0

    for seg_start, seg_end in runs:
        t_seg = t_raw[seg_start:seg_end]
        s_seg = sig_raw[seg_start:seg_end]

        # Upsample this segment
        t_up, sig_up = upsample_segment(t_seg, s_seg)
        seg_t_up_list.append(t_up)
        seg_s_up_list.append(sig_up)

        # Find feet within this upsampled segment
        feet = find_feet(sig_up)
        seg_feet_list.append(feet)

        if len(feet) < 2:
            continue

        # Extract features per pulse
        for i in range(len(feet) - 1):
            f0, f1 = feet[i], feet[i + 1]
            seg_pt = t_up[f0:f1]
            seg_ps = sig_up[f0:f1]
            feat = extract_pulse_features(seg_pt, seg_ps, height_m)
            if feat is None:
                continue
            pulse_num += 1
            feat["pulse_num"] = pulse_num
            feat["session_id"] = session_id
            if "si_m_per_s" not in feat:
                feat["si_m_per_s"] = None
            all_pulses.append(feat)

    # Consistency filters — remove physiologically implausible pulses.
    # 1. Duration: outside [0.5×, 1.5×] median catches dicrotic-notch false feet.
    # 2. Amplitude: outside [0.1×, 3.0×] median catches IIR-transient spike pulses.
    if all_pulses:
        durations = np.array([p["duration_ms"] for p in all_pulses])
        amplitudes = np.array([p["amplitude"] for p in all_pulses])
        median_dur = float(np.median(durations))
        median_amp = float(np.median(amplitudes))
        valid_pulses = [
            p for p in all_pulses
            if (0.5 * median_dur <= p["duration_ms"] <= 1.5 * median_dur
                and 0.1 * median_amp <= p["amplitude"] <= 3.0 * median_amp)
        ]
        n_filtered = len(all_pulses) - len(valid_pulses)
        if n_filtered:
            print(f"  Consistency filter: removed {n_filtered} outlier pulses "
                  f"(dur median={median_dur:.0f}ms, amp median={median_amp:.1f}, "
                  f"kept {len(valid_pulses)})")
    else:
        valid_pulses = all_pulses

    notch_pulses = [p for p in valid_pulses if p["has_notch"]]

    print(f"\n  Valid pulses : {len(valid_pulses)}")
    print(f"  With notch  : {len(notch_pulses)} ({100*len(notch_pulses)/max(1,len(valid_pulses)):.0f}%)")

    if valid_pulses:
        rise_vals = [p["rise_time_ms"] for p in valid_pulses if p["rise_time_ms"]]
        dur_vals  = [p["duration_ms"]   for p in valid_pulses]
        amp_vals  = [p["amplitude"]     for p in valid_pulses]

        implied_hr = [60000 / d for d in dur_vals if d > 0]

        print(f"\n  --- Pulse stats ---")
        print(f"  Pulse duration: {np.mean(dur_vals):.0f} ± {np.std(dur_vals):.0f} ms")
        print(f"  Implied HR    : {np.mean(implied_hr):.1f} ± {np.std(implied_hr):.1f} bpm")
        print(f"  Rise time     : {np.mean(rise_vals):.0f} ± {np.std(rise_vals):.0f} ms")
        print(f"  Amplitude     : {np.mean(amp_vals):.3f} ± {np.std(amp_vals):.3f}")

    if notch_pulses:
        ai_vals  = [p["ai_pct"] for p in notch_pulses if p["ai_pct"] is not None]
        ri_vals  = [p["ri"]     for p in notch_pulses if p["ri"]     is not None]
        si_vals  = [p["si_raw_s"] for p in notch_pulses if p["si_raw_s"] is not None]

        print(f"\n  --- Morphology features (notch-detected pulses only) ---")
        print(f"  AI% (Augmentation Index) : {np.mean(ai_vals):.1f} ± {np.std(ai_vals):.1f}%")
        print(f"  RI  (Reflection Index)   : {np.mean(ri_vals):.3f} ± {np.std(ri_vals):.3f}")
        print(f"  SI raw (S→D time)        : {np.mean(si_vals)*1000:.0f} ± {np.std(si_vals)*1000:.0f} ms")
        if height_m:
            si_ms_vals = [p.get("si_m_per_s") for p in notch_pulses if p.get("si_m_per_s")]
            if si_ms_vals:
                print(f"  SI (m/s, h={height_cm}cm)    : {np.mean(si_ms_vals):.2f} ± {np.std(si_ms_vals):.2f} m/s")

    # ── Write CSV ─────────────────────────────────────────────────────────────
    out_csv = f"ppg_features_{session_id}.csv"
    fieldnames = [
        "session_id", "pulse_num", "foot_time_s", "peak_time_s",
        "duration_ms", "amplitude", "rise_time_ms", "pw50_ms",
        "has_notch", "ai_pct", "ri", "si_raw_s", "si_m_per_s",
    ]

    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for p in valid_pulses:
            if "si_m_per_s" not in p:
                p["si_m_per_s"] = None
            w.writerow(p)

    print(f"\n  Features CSV: {out_csv}  ({len(valid_pulses)} pulses)")
    print(f"\n  Next steps:")
    print(f"    1. Run calibration_session.py to capture ring PPG + AW ECG + cuff BP")
    print(f"    2. Export AW ECG from iPhone Health app (zip → electrocardiograms/*.csv)")
    print(f"    3. Run ecg_rpeaks.py to detect R-peaks from AW ECG")
    print(f"    4. Run ptt_calculator.py to compute PTT (ECG R-peak → PPG foot)")
    print(f"    5. Run bp_calibration.py with features + PTT + cuff readings")
    print()

    if do_plot and seg_t_up_list:
        # Concatenate all segments for plotting (gaps visible as jumps)
        t_cat = np.concatenate(seg_t_up_list)
        s_cat = np.concatenate(seg_s_up_list)
        # Feet as absolute indices into the concatenated arrays
        offset = 0
        feet_abs = []
        for seg_t_up, seg_feet in zip(seg_t_up_list, seg_feet_list):
            feet_abs.extend([offset + f for f in seg_feet])
            offset += len(seg_t_up)
        plot_session(t_cat, s_cat, np.array(feet_abs), valid_pulses)


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("session_id", nargs="?",
                   help="session_id from ppg_sessions (use --list to see all)")
    p.add_argument("--list", action="store_true",
                   help="List available PPG sessions and exit")
    p.add_argument("--db", default=str(DEFAULT_DB),
                   help=f"Path to DuckDB file (default: {DEFAULT_DB})")
    p.add_argument("--height-cm", type=float, default=None,
                   help="Your height in cm — enables SI (Stiffness Index) in m/s")
    p.add_argument("--plot", action="store_true",
                   help="Show waveform + AI% plot after extraction")
    args = p.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        print(f"DuckDB not found at {db_path}\nRun Docker: colima start && docker compose up -d")
        sys.exit(1)

    if args.list:
        list_sessions(db_path)
        return

    if not args.session_id:
        p.print_help()
        sys.exit(1)

    run(args.session_id, db_path, args.height_cm, args.plot)


if __name__ == "__main__":
    main()
