#!/usr/bin/env python3
"""
spo2_calibrator.py — Calibrate PPG-derived SpO2 against ring's own reading.

Uses the stored spo2_pct values in ppg_frames (already computed by SpO2Estimator
at capture time, with all gates applied) rather than recomputing from raw DC/AC.

The stored values satisfy: spo2_stored = CURRENT_A - CURRENT_B * R_mean
So: R_mean = (CURRENT_A - spo2_stored) / CURRENT_B

With a reference SpO2 from the ring's own reading (0x15 live frame or 0x4C history):
  • Single-session: report error and suggest additive offset correction
  • Multi-session (≥2 different SpO2 levels): fit updated A, B via least squares

Usage:
  # Show all sessions with their derived SpO2 (no calibration)
  .venv/bin/python spo2_calibrator.py --summary

  # Single session — ring live SpO2 from iOS "live measurement" (byte[14] of 0x15 frame)
  .venv/bin/python spo2_calibrator.py --latest --ref 97
  .venv/bin/python spo2_calibrator.py <session_id_prefix> --ref 96

  # Multi-session interactive: enter ring SpO2 for each session, fit new A, B
  .venv/bin/python spo2_calibrator.py --all-sessions

  # Use health_records (0x4C SpO2 via HealthKit export) as automatic reference
  .venv/bin/python spo2_calibrator.py --latest --use-db-ref
"""

import argparse
import statistics
import sys

import duckdb

DB = "/Users/pravinsail/HealthLocal/db/healthlocal.duckdb"

# Current formula in ppg_pipeline.py (lines ~58-59)
CURRENT_A = 110.0
CURRENT_B = 19.05

ANCHOR_R = 1.0          # R=1.0 is the physiological anchor point
ANCHOR_SPO2 = 85.0      # R=1.0 → SpO2≈85% in all calibrated oximeters


def load_session_spo2(conn: duckdb.DuckDBPyConnection, session_id: str) -> list[float]:
    """Return per-frame SpO2 estimates (stored at capture time, one unique value per seq)."""
    rows = conn.execute("""
        SELECT DISTINCT seq, AVG(spo2_pct) AS spo2
        FROM ppg_frames
        WHERE session_id = ? AND spo2_pct IS NOT NULL
        GROUP BY seq
        ORDER BY seq
    """, [session_id]).fetchall()
    return [float(r[1]) for r in rows if r[1] is not None and 70.0 < r[1] < 102.0]


def load_session_dc_stats(conn: duckdb.DuckDBPyConnection, session_id: str) -> dict:
    """Per-frame DC level stats for AGC context."""
    rows = conn.execute("""
        SELECT AVG(ABS(chB_raw)) dc_B, AVG(ABS(chC_raw)) dc_C,
               MIN(ABS(chB_raw)) min_dc_B, MAX(ABS(chB_raw)) max_dc_B,
               COUNT(DISTINCT seq) n_frames, COUNT(*) n_samples
        FROM ppg_frames
        WHERE session_id = ? AND spo2_pct IS NOT NULL
    """, [session_id]).fetchone()
    if not rows or rows[0] is None:
        return {}
    return {
        "dc_B": rows[0], "dc_C": rows[1],
        "min_dc_B": rows[2], "max_dc_B": rows[3],
        "n_frames": rows[4], "n_samples": rows[5],
    }


def resolve_session_id(conn: duckdb.DuckDBPyConnection, prefix: str) -> str | None:
    row = conn.execute(
        "SELECT session_id FROM ppg_sessions WHERE session_id LIKE ? ORDER BY captured_at DESC LIMIT 1",
        [prefix + "%"]
    ).fetchone()
    return row[0] if row else None


def get_session_info(conn: duckdb.DuckDBPyConnection, session_id: str) -> dict:
    row = conn.execute(
        "SELECT captured_at, duration_s, mean_spo2_pct, mean_hr_bpm, total_frames "
        "FROM ppg_sessions WHERE session_id = ?", [session_id]
    ).fetchone()
    if not row:
        return {}
    return {"captured_at": row[0], "duration_s": row[1], "mean_spo2_pct": row[2],
            "mean_hr_bpm": row[3], "total_frames": row[4]}


def get_db_ref_spo2(conn: duckdb.DuckDBPyConnection, session_id: str) -> float | None:
    """Nearest health_records SpO2 (from HealthKit / Apple Health export) within ±30 min."""
    info = get_session_info(conn, session_id)
    if not info:
        return None
    ts = str(info["captured_at"])
    match = conn.execute("""
        SELECT value, source_name, start_time,
               ABS(EPOCH(start_time) - EPOCH(TIMESTAMPTZ ?)) AS secs_diff
        FROM health_records
        WHERE (metric_type LIKE '%Oxygen%' OR metric_type LIKE '%oxygen%')
          AND ABS(EPOCH(start_time) - EPOCH(TIMESTAMPTZ ?)) < 1800
        ORDER BY secs_diff ASC
        LIMIT 1
    """, [ts, ts]).fetchone()
    if not match:
        return None
    val, src, ref_ts, diff = match
    # HealthKit stores as fraction 0-1; convert to %
    ref_pct = val * 100.0 if val is not None and val <= 1.5 else val
    print(f"  DB ref: {ref_pct:.1f}% from {src} at {ref_ts} ({diff:.0f}s from session start)")
    return ref_pct


def fit_from_anchor(mean_R: float, ref_spo2: float) -> tuple[float, float]:
    """Fit SpO2 = A - B*R from one data point + physiological anchor (R=1.0 → 85%).
    Returns (A, B)."""
    # Two equations:  A - B * mean_R = ref_spo2
    #                 A - B * 1.0   = 85.0
    # Subtracting:    B * (1.0 - mean_R) = ref_spo2 - 85.0
    denom = 1.0 - mean_R
    if abs(denom) < 1e-6:
        raise ValueError(f"mean_R ≈ 1.0 — formula is degenerate at this operating point.")
    B = (ref_spo2 - ANCHOR_SPO2) / denom
    A = ANCHOR_SPO2 + B * ANCHOR_R
    return A, B


def fit_multipoint(calib_points: list[tuple[float, float]]) -> tuple[float, float]:
    """Least-squares fit of SpO2 = A - B*R from multiple (R, SpO2_ref) pairs."""
    n = len(calib_points)
    sum_R = sum(r for r, _ in calib_points)
    sum_S = sum(s for _, s in calib_points)
    sum_R2 = sum(r**2 for r, _ in calib_points)
    sum_RS = sum(r * s for r, s in calib_points)
    det = n * sum_R2 - sum_R**2
    if abs(det) < 1e-9:
        raise ValueError("Degenerate: R values too similar across sessions.")
    A = (sum_S * sum_R2 - sum_RS * sum_R) / det
    neg_B = (n * sum_RS - sum_R * sum_S) / det
    return A, -neg_B


def show_session_summary(conn: duckdb.DuckDBPyConnection) -> None:
    rows = conn.execute("""
        SELECT s.session_id, s.captured_at, s.duration_s,
               s.mean_spo2_pct,
               COUNT(DISTINCT f.seq) AS spo2_frames,
               AVG(ABS(f.chB_raw)) AS dc_B
        FROM ppg_sessions s
        LEFT JOIN ppg_frames f ON s.session_id = f.session_id AND f.spo2_pct IS NOT NULL
        GROUP BY s.session_id, s.captured_at, s.duration_s, s.mean_spo2_pct
        ORDER BY s.captured_at
    """).fetchall()

    print(f"\n{'ID':8}  {'Captured':19}  {'Dur':>5}  {'Derived SpO2':>12}  {'SpO2 frames':>11}  {'dc_B':>6}")
    print("-" * 78)
    for r in rows:
        sid, ts, dur, spo2, n_frames, dc_B = r
        spo2_str = f"{spo2:.1f}%" if spo2 else "  —  "
        dc_str = f"{dc_B:.0f}" if dc_B else "—"
        print(f"{sid[:8]}  {str(ts)[:19]}  {dur:>5.0f}  {spo2_str:>12}  {n_frames:>11}  {dc_str:>6}")

    print(f"\n  Current formula: SpO2 = {CURRENT_A} - {CURRENT_B} × R")
    print(f"  Ring's live SpO2 shown in iOS log (0x15 frames), e.g. 'live SpO2: 97%'")
    print(f"\nTo calibrate a session:")
    print(f"  .venv/bin/python spo2_calibrator.py <session_id> --ref <ring_spo2>")


def calibrate_one(conn: duckdb.DuckDBPyConnection, session_id: str,
                  ref_spo2: float, verbose: bool = True) -> dict | None:
    """Calibrate one session. Returns dict with mean_R, result info, or None on failure."""
    spo2_vals = load_session_spo2(conn, session_id)
    if not spo2_vals:
        if verbose:
            print(f"  Session {session_id[:8]}: no stored SpO2 values "
                  f"(capture may not have had pipeline cols; check CSV format).")
        return None

    dc = load_session_dc_stats(conn, session_id)
    info = get_session_info(conn, session_id)

    mean_spo2 = statistics.mean(spo2_vals)
    std_spo2 = statistics.stdev(spo2_vals) if len(spo2_vals) > 1 else 0.0
    # Reverse-compute mean R: stored_spo2 = CURRENT_A - CURRENT_B * R → R = (A - spo2) / B
    R_vals = [(CURRENT_A - s) / CURRENT_B for s in spo2_vals if CURRENT_B > 0]
    mean_R = statistics.mean(R_vals)
    std_R = statistics.stdev(R_vals) if len(R_vals) > 1 else 0.0
    error = mean_spo2 - ref_spo2

    if verbose:
        captured = str(info.get("captured_at", "unknown"))[:19]
        print(f"\n=== Session {session_id[:8]}  ({captured}) ===")
        print(f"  SpO2 frames     : {len(spo2_vals)} / {info.get('total_frames', '?')} total")
        print(f"  Derived SpO2    : {mean_spo2:.1f}% ± {std_spo2:.1f}%  "
              f"[{min(spo2_vals):.1f}–{max(spo2_vals):.1f}]")
        print(f"  Reference SpO2  : {ref_spo2:.1f}%  (ring 0x15 / 0x4C reading)")
        print(f"  Error           : {error:+.1f}%  ({'over' if error > 0 else 'under'}estimated)")
        if dc:
            print(f"  dc_B (valid)    : {dc['dc_B']:.0f} mean  "
                  f"[{dc['min_dc_B']:.0f}–{dc['max_dc_B']:.0f}]  "
                  f"(calibrated at dc_B≈810)")
        print(f"  Mean R          : {mean_R:.4f} ± {std_R:.4f}")

    try:
        A_new, B_new = fit_from_anchor(mean_R, ref_spo2)
        check = A_new - B_new * mean_R
        if verbose:
            print(f"\n  Suggested constants (anchor: R={ANCHOR_R:.1f} → SpO2={ANCHOR_SPO2:.0f}%):")
            print(f"    A = {A_new:.2f}  (was {CURRENT_A})")
            print(f"    B = {B_new:.2f}  (was {CURRENT_B})")
            print(f"    Check: {A_new:.2f} - {B_new:.2f}×{mean_R:.4f} = {check:.1f}%  "
                  f"(target {ref_spo2:.1f}%)")
            if abs(error) > 2.0:
                print(f"\n  NOTE: error > 2%. A simple additive offset may suffice:")
                print(f"    spo2_corrected = spo2_formula + ({ref_spo2 - mean_spo2:+.1f})")
    except ValueError as e:
        A_new, B_new = CURRENT_A, CURRENT_B
        if verbose:
            print(f"  Fit failed: {e}")

    return {
        "session_id": session_id, "mean_R": mean_R, "ref_spo2": ref_spo2,
        "derived_spo2": mean_spo2, "error": error,
        "dc_B": dc.get("dc_B"), "A_new": A_new, "B_new": B_new,
        "n_frames": len(spo2_vals),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Calibrate PPG SpO2 formula")
    parser.add_argument("session_id", nargs="?", help="Session ID prefix")
    parser.add_argument("--ref", type=float, metavar="SPO2",
                        help="Reference SpO2 %% from ring's live reading (0x15 frame in iOS log)")
    parser.add_argument("--latest", action="store_true", help="Use most recent PPG session")
    parser.add_argument("--use-db-ref", action="store_true",
                        help="Use health_records nearest timestamp (from HealthKit export)")
    parser.add_argument("--summary", action="store_true",
                        help="Show all sessions + derived SpO2 (no calibration)")
    parser.add_argument("--all-sessions", action="store_true",
                        help="Multi-session calibration — prompt for reference SpO2 per session")
    parser.add_argument("--db", default=DB)
    args = parser.parse_args()

    conn = duckdb.connect(args.db, read_only=True)

    if args.summary or (not args.session_id and not args.latest and not args.all_sessions):
        show_session_summary(conn)
        conn.close()
        return

    if args.all_sessions:
        sessions = conn.execute(
            "SELECT session_id, captured_at, mean_spo2_pct "
            "FROM ppg_sessions ORDER BY captured_at"
        ).fetchall()

        calib_points: list[tuple[float, float]] = []
        for sid, ts, derived in sessions:
            d = f"{derived:.1f}%" if derived else "—"
            print(f"\n{sid[:8]}  {str(ts)[:19]}  derived={d}")
            ref_str = input("  Reference SpO2 (ring / AW / pulse-ox), or ENTER to skip: ").strip()
            if not ref_str:
                continue
            try:
                ref = float(ref_str)
            except ValueError:
                print("  Skipped.")
                continue
            result = calibrate_one(conn, sid, ref, verbose=True)
            if result:
                calib_points.append((result["mean_R"], ref))

        if len(calib_points) >= 2:
            print(f"\n=== Multi-session fit ({len(calib_points)} points) ===")
            SpO2_range = max(p[1] for p in calib_points) - min(p[1] for p in calib_points)
            if SpO2_range < 5.0:
                print(f"  WARNING: SpO2 range only {SpO2_range:.1f} mmHg across sessions.")
                print(f"  A narrow range makes A,B poorly constrained. Ideally ≥10% spread.")
            A_fit, B_fit = fit_multipoint(calib_points)
            print(f"\n  Fitted: SpO2 = {A_fit:.2f} - {B_fit:.2f} × R")
            print(f"  Was:    SpO2 = {CURRENT_A} - {CURRENT_B} × R")
            for R, ref in calib_points:
                pred = A_fit - B_fit * R
                print(f"  R={R:.4f}: predicted={pred:.1f}%  ref={ref:.1f}%  err={pred-ref:+.1f}%")
            print(f"\n  To apply, edit ppg_pipeline.py lines ~58-59:")
            print(f"    SPO2_A: float = {A_fit:.2f}")
            print(f"    SPO2_B: float = {B_fit:.2f}")
        else:
            print("\nNeed ≥2 sessions with references for unconstrained 2-param fit.")
        conn.close()
        return

    # Resolve single session
    if args.latest:
        row = conn.execute(
            "SELECT session_id FROM ppg_sessions ORDER BY captured_at DESC LIMIT 1"
        ).fetchone()
        session_id = row[0] if row else None
    else:
        session_id = resolve_session_id(conn, args.session_id)

    if not session_id:
        print("Session not found.")
        conn.close()
        sys.exit(1)

    # Resolve reference SpO2
    if args.use_db_ref:
        ref_spo2 = get_db_ref_spo2(conn, session_id)
        if ref_spo2 is None:
            print("No health_records SpO2 within ±30 min of this session.")
            print("Tip: sync ring → export Apple Health → re-import to get 0x4C SpO2 in health_records.")
            conn.close()
            sys.exit(1)
    elif args.ref is not None:
        ref_spo2 = args.ref
    else:
        # No reference: show derived SpO2 only
        spo2_vals = load_session_spo2(conn, session_id)
        dc = load_session_dc_stats(conn, session_id)
        info = get_session_info(conn, session_id)
        if spo2_vals:
            mean = statistics.mean(spo2_vals)
            std = statistics.stdev(spo2_vals) if len(spo2_vals) > 1 else 0.0
            print(f"\nSession {session_id[:8]}  ({str(info.get('captured_at',''))[:19]})")
            print(f"  Derived SpO2 : {mean:.1f}% ± {std:.1f}%  [{min(spo2_vals):.1f}–{max(spo2_vals):.1f}]")
            print(f"  SpO2 frames  : {len(spo2_vals)}")
            if dc:
                print(f"  dc_B (valid) : {dc['dc_B']:.0f} mean  [{dc['min_dc_B']:.0f}–{dc['max_dc_B']:.0f}]")
        else:
            print(f"No SpO2 data for session {session_id[:8]}.")
        print(f"\nTo calibrate: .venv/bin/python spo2_calibrator.py {session_id[:8]} --ref <ring_reading>")
        conn.close()
        return

    result = calibrate_one(conn, session_id, ref_spo2)

    if result and abs(result.get("error", 0)) < 0.5:
        print(f"\n  Formula is accurate (error < 0.5%). No correction needed.")

    if result:
        print(f"\n  HOW TO CALIBRATE (two paths):")
        print(f"  A) Additive offset (simplest, no model change):")
        print(f"     In ppg_pipeline.py SpO2Estimator.feed() final line:")
        offset = ref_spo2 - result["derived_spo2"]
        print(f"     return max(70.0, SPO2_A - SPO2_B * self.last_r + ({offset:+.1f}))")
        print(f"  B) Update A, B constants (proper 2-point fit, run --all-sessions with")
        print(f"     a session at lower SpO2, e.g. post-exercise or breath-hold).")

    conn.close()


if __name__ == "__main__":
    main()
