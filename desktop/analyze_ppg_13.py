"""Analyze a ppg_*.csv file from stream_ppg_13.py or capture_ppg.py.

Accepts both old format (chA/chB/chC) and new format (chA_raw/chB_raw/chC_raw + chA_filt/...).
For old-format files, applies zero-phase bandpass filter (0.5-8 Hz) offline.

Produces:
  1. Raw vs. filtered waveform comparison (chA green LED)
  2. Red + IR channels (chB, chC)
  3. FFT of filtered chA → HR estimate (with cubic detrend)
  4. Per-frame AC/DC quality metrics and SpO2

Usage:
    .venv/bin/python analyze_ppg_13.py <ppg_*.csv>
    .venv/bin/python analyze_ppg_13.py <ppg_*.csv> --no-plot   (stats only)
"""
from __future__ import annotations
import sys, argparse
import pandas as pd
import numpy as np

from ppg_pipeline import BandpassFilter, SAT_THRESHOLD

FS = 25.0
SATURATION_THRESH = SAT_THRESHOLD


def load(path: str, seq_start: int | None = None, seq_end: int | None = None) -> pd.DataFrame:
    df = pd.read_csv(path)
    df["time_s"] = df["sample_idx"] / FS
    # Normalise column names: old format (chA/chB/chC) → new format (chA_raw/...)
    if "chA" in df.columns and "chA_raw" not in df.columns:
        df = df.rename(columns={"chA": "chA_raw", "chB": "chB_raw", "chC": "chC_raw"})

    # Seq range filter — applied BEFORE zero-phase filter so the filter sees a
    # continuous segment (avoids ringing from DC discontinuities between segments).
    filtering = seq_start is not None or seq_end is not None
    if seq_start is not None:
        df = df[df["seq"] >= seq_start].copy()
    if seq_end is not None:
        df = df[df["seq"] <= seq_end].copy()

    # (Re-)compute zero-phase filter when seq range is active, or when not in CSV.
    # Recomputing on the filtered subset removes ringing from cross-segment DC steps.
    if filtering or "chA_filt" not in df.columns:
        sat = df["chA_raw"] > SATURATION_THRESH
        chA_clean = df["chA_raw"].copy()
        chA_clean[sat] = np.nan
        chA_clean = chA_clean.interpolate()   # linear interp over saturation gaps
        df["chA_filt"] = BandpassFilter.zero_phase(chA_clean.values.tolist())
        df["chB_filt"] = BandpassFilter.zero_phase(df["chB_raw"].values.tolist())
        df["chC_filt"] = BandpassFilter.zero_phase(df["chC_raw"].values.tolist())
    # Ensure saturated column
    if "saturated" not in df.columns:
        df["saturated"] = (df["chA_raw"] > SATURATION_THRESH).astype(int)
    return df


def mark_sat_frames(df: pd.DataFrame) -> tuple[pd.DataFrame, set]:
    """Mark frames that contain saturation events (chA_raw near uint16 max)."""
    frame_max = df.groupby("seq")["chA_raw"].max()
    sat_seqs = set(frame_max[frame_max > SATURATION_THRESH].index)
    if "saturated" not in df.columns:
        df["saturated"] = df["seq"].isin(sat_seqs).astype(int)
    return df, sat_seqs


def fft_hr(arr: np.ndarray, fs: float = FS) -> tuple[float, np.ndarray, np.ndarray]:
    """FFT HR from numpy array. Returns (hr_bpm, freqs_hz, magnitudes).
    Applies cubic detrend before FFT to remove slow DC drift from AGC events."""
    n = len(arr)
    t = np.arange(n, dtype=float)
    arr = arr - np.polyval(np.polyfit(t, arr, 3), t)   # remove slow drift
    arr *= np.hanning(n)
    mags = np.abs(np.fft.rfft(arr))
    freqs = np.fft.rfftfreq(n, d=1.0 / fs)
    mask = (freqs >= 0.5) & (freqs <= 3.5)
    peak_hz = freqs[mask][np.argmax(mags[mask])]
    return float(peak_hz * 60), freqs, mags


def per_frame_stats(df: pd.DataFrame, ch_raw: str, ch_filt: str) -> pd.DataFrame:
    """Compute per-frame DC (from raw) and AC (from filtered) statistics."""
    raw_dc = df.groupby("seq")[ch_raw].mean().rename("dc")
    filt_ac = df.groupby("seq")[ch_filt].apply(lambda x: x.max() - x.min()).rename("ac")
    out = pd.concat([raw_dc, filt_ac], axis=1)
    out["ac_dc_pct"] = 100 * out["ac"].abs() / out["dc"].abs().replace(0, np.nan)
    return out


def report(df: pd.DataFrame, sat_seqs: set, no_plot: bool) -> None:
    n_frames = df["seq"].nunique()
    n_sat = len(sat_seqs)
    n_valid = n_frames - n_sat
    total_s = len(df) / FS
    print(f"\n=== Stage 1 PPG Analysis — RingConn RSP 0x13 ===")
    print(f"  Samples : {len(df)}  ({total_s:.1f}s at {FS} Hz)")
    print(f"  Frames  : {n_frames} total, {n_sat} AGC/saturated, {n_valid} valid")

    valid = df[df["saturated"] == 0].copy()
    if valid.empty:
        print("  No valid frames to analyze.")
        return

    # Per-frame AC/DC (filtered AC, raw DC — correct approach)
    print("\n--- Per-frame AC/DC (filtered AC, raw DC baseline) ---")
    for raw_col, filt_col, label in [
        ("chA_raw", "chA_filt", "chA (green LED, uint16)"),
        ("chB_raw", "chB_filt", "chB (red?   int16)"),
        ("chC_raw", "chC_filt", "chC (IR?    int16)"),
    ]:
        stats = per_frame_stats(valid, raw_col, filt_col)
        dc = abs(stats["dc"].mean())
        ac = stats["ac"].mean()
        pct = stats["ac_dc_pct"].mean()
        print(f"  {label}: DC={dc:>7.1f}  per-frame AC={ac:>6.2f}  AC/DC={pct:.2f}%")

    # FFT HR on filtered chA (cubic-detrended)
    chA_filt = valid["chA_filt"].values.astype(np.float64)
    if len(chA_filt) >= 50:
        hr_bpm, freqs, mags = fft_hr(chA_filt)
        mask = (freqs >= 0.5) & (freqs <= 3.5)
        ranked = np.argsort(mags[mask])[::-1][:5]
        print(f"\n--- FFT HR (filtered chA, {len(chA_filt)} samples = {len(chA_filt)/FS:.1f}s) ---")
        print(f"  Top 5 peaks in HR band:")
        for i in ranked:
            print(f"    {freqs[mask][i]*60:>6.1f} bpm  (mag={mags[mask][i]:.0f})")
        print(f"  → Best HR estimate: {hr_bpm:.1f} bpm")
    else:
        print(f"\n  FFT skipped — need ≥50 valid samples")

    # SpO2 from per-frame AC/DC of chB and chC
    st_B = per_frame_stats(valid, "chB_raw", "chB_filt")
    st_C = per_frame_stats(valid, "chC_raw", "chC_filt")
    dc_B = abs(valid.groupby("seq")["chB_raw"].mean().mean())
    dc_C = abs(valid.groupby("seq")["chC_raw"].mean().mean())
    ac_B = st_B["ac"].mean()
    ac_C = st_C["ac"].mean()
    if dc_B > 0 and dc_C > 0 and ac_B > 0 and ac_C > 0:
        R_BC = (ac_B / dc_B) / (ac_C / dc_C)
        R_CB = (ac_C / dc_C) / (ac_B / dc_B)
        print(f"\n--- SpO2 (per-frame ratio-of-ratios, calibration TBD) ---")
        print(f"  AC_B/DC_B = {ac_B/dc_B:.4f}   AC_C/DC_C = {ac_C/dc_C:.4f}")
        print(f"  if chB=red, chC=IR:  R={R_BC:.4f} → SpO2 ≈ {110 - 25*R_BC:.1f}%")
        print(f"  if chC=red, chB=IR:  R={R_CB:.4f} → SpO2 ≈ {110 - 25*R_CB:.1f}%")
        print(f"  → Run identify_channels.py to confirm which is correct")

    if no_plot:
        return

    # ── Plots ─────────────────────────────────────────────────────────────────
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(4, 1, figsize=(14, 13))
    fig.suptitle("Stage 1 PPG Analysis — RingConn Air 2 RSP 0x13", fontsize=13)

    t_valid = valid["time_s"].values
    t_all = df["time_s"].values

    # Panel 1: chA raw (full capture) vs filtered (valid only), both on same axes
    ax = axes[0]
    ax.plot(t_all, df["chA_raw"].values, color="lightgreen", lw=0.5,
            alpha=0.6, label="chA raw")
    ax.plot(t_valid, valid["chA_filt"].values, color="green", lw=0.9,
            label="chA filtered (0.5-8 Hz)")
    for seq in sat_seqs:
        seg = df[df["seq"] == seq]["time_s"]
        if not seg.empty:
            ax.axvspan(seg.min(), seg.max(), alpha=0.25, color="red",
                       label="_AGC event" if seg.min() > 0 else "AGC event")
    ax.set_ylabel("chA (ADC counts)")
    ax.set_title("chA green LED — raw vs. bandpass filtered (red shading = AGC/saturation)")
    ax.legend(loc="upper right", fontsize=8)

    # Panel 2: filtered chA zoomed (removes DC drift — shows heartbeat waveform)
    ax = axes[1]
    ax.plot(t_valid, valid["chA_filt"].values, color="green", lw=0.8)
    ax.axhline(0, color="gray", lw=0.5, linestyle="--")
    ax.set_ylabel("chA filtered (counts)")
    ax.set_title("chA filtered — DC removed, heartbeat waveform visible")

    # Panel 3: chB and chC filtered (red/IR candidates)
    ax = axes[2]
    ax.plot(t_valid, valid["chB_filt"].values, color="red", lw=0.8, label="chB filtered (red?)")
    ax.plot(t_valid, valid["chC_filt"].values, color="darkred", lw=0.8,
            alpha=0.7, label="chC filtered (IR?)")
    ax.axhline(0, color="gray", lw=0.5, linestyle="--")
    ax.set_ylabel("filtered (counts)")
    ax.set_title("chB / chC filtered — red + IR candidates")
    ax.legend(loc="upper right", fontsize=8)

    # Panel 4: FFT of filtered chA → HR
    ax = axes[3]
    chA_filt_arr = valid["chA_filt"].values.astype(np.float64)
    if len(chA_filt_arr) >= 50:
        peak_hr, freqs, mags = fft_hr(chA_filt_arr)
        hr_mask = (freqs >= 0.3) & (freqs <= 4.0)
        ax.plot(freqs[hr_mask] * 60, mags[hr_mask], color="navy", lw=0.9)
        ax.axvline(peak_hr, color="orange", linestyle="--",
                   label=f"Peak: {peak_hr:.1f} bpm")
        ax.set_xlabel("HR (bpm)")
        ax.set_ylabel("FFT magnitude")
        ax.set_title(f"Filtered chA FFT — HR estimate: {peak_hr:.1f} bpm")
        ax.legend()

    for ax in axes:
        ax.set_xlabel("Time (s)")
    fig.tight_layout()
    plt.show()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("csv", help="CSV from capture_ppg.py or stream_ppg_13.py")
    p.add_argument("--no-plot", action="store_true", help="stats only, no matplotlib window")
    p.add_argument("--seq-start", type=int, default=None, metavar="SEQ",
                   help="Analyse only frames from this seq number (inclusive). "
                        "Use to isolate a stable segment when DC changed mid-capture.")
    p.add_argument("--seq-end", type=int, default=None, metavar="SEQ",
                   help="Analyse only frames through this seq number (inclusive).")
    args = p.parse_args()

    df = load(args.csv, seq_start=args.seq_start, seq_end=args.seq_end)
    if args.seq_start is not None or args.seq_end is not None:
        lo = args.seq_start if args.seq_start is not None else "start"
        hi = args.seq_end if args.seq_end is not None else "end"
        print(f"  [Seq range {lo}–{hi}: {df['seq'].nunique()} frames, "
              f"zero-phase filter recomputed on this segment]")
    df, sat_seqs = mark_sat_frames(df)
    report(df, sat_seqs, args.no_plot)


if __name__ == "__main__":
    main()
