"""bp_estimator.py — Stage 4: Continuous BP estimation from any PPG session.

Loads ppg_features_<session_id>.csv (runs ppg_feature_extractor.py if missing),
divides the session into sliding 60-second windows, applies the morphology-only
Ridge model from bp_model_*.json, and POSTs the windowed estimates to the
health-local-core API (which stores them in the bp_estimates table).

No ECG required — uses AI%, RI, rise_time, pw50 from the ring PPG waveform.

Usage:
    .venv/bin/python bp_estimator.py <session_id>
    .venv/bin/python bp_estimator.py <session_id> --model bp_model_20260628.json
    .venv/bin/python bp_estimator.py <session_id> --window-s 60 --step-s 30
    .venv/bin/python bp_estimator.py --latest          # most recent PPG session
    .venv/bin/python bp_estimator.py --list            # show recent sessions
"""
from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
from pathlib import Path
from typing import Optional

import duckdb
import numpy as np
import requests

DEFAULT_DB   = Path.home() / "HealthLocal" / "db" / "healthlocal.duckdb"
DEFAULT_API  = "http://localhost:8765"
DESKTOP_DIR  = Path(__file__).parent
MIN_NOTCH    = 3   # minimum notch pulses in a window to trust AI%/RI
MIN_PULSES   = 4   # minimum total pulses to emit a window estimate


# ── Model ─────────────────────────────────────────────────────────────────────

def load_model(model_path: Optional[Path] = None) -> dict:
    """Load latest bp_model_*.json if path not provided."""
    if model_path is None:
        candidates = sorted(DESKTOP_DIR.glob("bp_model_*.json"),
                            key=lambda p: p.stat().st_mtime, reverse=True)
        if not candidates:
            print("No bp_model_*.json found. Run bp_calibration.py first.")
            sys.exit(1)
        model_path = candidates[0]
    data = json.loads(model_path.read_text())
    print(f"  Model        : {model_path.name}  (trained on {data.get('n_readings')} readings)")
    morph = data.get("morphology_models", {})
    if not morph.get("sbp") or not morph.get("dbp"):
        print("  Warning: no morphology_models in this JSON. Re-run bp_calibration.py --all.")
        sys.exit(1)
    return data


def apply_model(model_dict: dict, features: dict) -> Optional[float]:
    """Apply a Ridge model dict to a feature dict. Returns None if any feature is missing."""
    try:
        vals = [features[fn] for fn in model_dict["feature_names"]]
    except KeyError:
        return None
    if any(v is None for v in vals):
        return None
    scaled = [(v - m) / s for v, m, s in zip(
        vals, model_dict["scaler_mean"], model_dict["scaler_std"])]
    return model_dict["intercept"] + sum(c * x for c, x in zip(
        model_dict["coefficients"], scaled))


# ── Feature loading ───────────────────────────────────────────────────────────

def ensure_features(session_id: str) -> Path:
    """Return path to ppg_features CSV, running extractor if needed."""
    feat_path = DESKTOP_DIR / f"ppg_features_{session_id}.csv"
    if feat_path.exists():
        return feat_path
    print(f"  Running ppg_feature_extractor for {session_id[:12]}...")
    result = subprocess.run(
        [sys.executable, str(DESKTOP_DIR / "ppg_feature_extractor.py"), session_id],
        capture_output=True, text=True, cwd=str(DESKTOP_DIR)
    )
    if result.returncode != 0:
        print(result.stderr[-500:] if result.stderr else "(no stderr)")
        sys.exit(1)
    if not feat_path.exists():
        print(f"  Extractor ran but {feat_path.name} not found.")
        sys.exit(1)
    return feat_path


def load_pulse_features(feat_path: Path) -> list[dict]:
    """Load ppg_features CSV as list of dicts with float fields."""
    pulses = []
    with open(feat_path) as f:
        for row in csv.DictReader(f):
            try:
                p = {
                    "foot_time_s": float(row["foot_time_s"]),
                    "ai_pct":      float(row["ai_pct"]) if row.get("ai_pct") else None,
                    "ri":          float(row["ri"])      if row.get("ri")     else None,
                    "rise_ms":     float(row["rise_time_ms"]) if row.get("rise_time_ms") else None,
                    "pw50_ms":     float(row["pw50_ms"]) if row.get("pw50_ms") else None,
                    "has_notch":   row.get("has_notch", "").strip() == "True",
                }
                pulses.append(p)
            except (ValueError, KeyError):
                pass
    return pulses


# ── Windowing ─────────────────────────────────────────────────────────────────

def window_features(pulses: list[dict], t_start: float, t_end: float,
                    window_s: float, step_s: float) -> list[dict]:
    """Divide [t_start, t_end] into sliding windows, compute mean features per window."""
    windows = []
    t = t_start
    while t + window_s <= t_end + step_s:
        w0, w1 = t, t + window_s
        in_window = [p for p in pulses if w0 <= p["foot_time_s"] < w1]
        notch_pulses = [p for p in in_window if p["has_notch"]]

        if len(in_window) < MIN_PULSES:
            t += step_s
            continue

        def mean_of(key: str, pool: list[dict]) -> Optional[float]:
            vals = [p[key] for p in pool if p.get(key) is not None]
            return float(np.mean(vals)) if vals else None

        feats: dict = {
            "ai_pct":  mean_of("ai_pct", notch_pulses) if len(notch_pulses) >= MIN_NOTCH else None,
            "ri":      mean_of("ri",      notch_pulses) if len(notch_pulses) >= MIN_NOTCH else None,
            "rise_ms": mean_of("rise_ms", in_window),
            "pw50_ms": mean_of("pw50_ms", in_window),
        }
        windows.append({
            "window_start_s": w0,
            "window_end_s":   w1,
            "n_pulses":       len(in_window),
            "n_notch":        len(notch_pulses),
            "features":       feats,
        })
        t += step_s

    return windows


# ── DuckDB helpers ────────────────────────────────────────────────────────────

def list_sessions(db_path: Path) -> None:
    conn = duckdb.connect(str(db_path), read_only=True)
    rows = conn.execute("""
        SELECT session_id, captured_at, duration_s, mean_hr_bpm, csv_filename
        FROM ppg_sessions ORDER BY captured_at DESC LIMIT 20
    """).fetchall()
    conn.close()
    print(f"\n{'session_id (first 12)':<14}  {'captured_at':<20}  {'dur_s':>6}  {'HR':>6}  file")
    print("-" * 80)
    for r in rows:
        print(f"  {str(r[0])[:12]:<14}  {str(r[1])[:19]:<20}  {r[2]:>6.0f}  "
              f"{(r[3] or 0):>6.1f}  {r[4] or ''}")
    print()


def get_latest_session_id(db_path: Path) -> str:
    conn = duckdb.connect(str(db_path), read_only=True)
    row = conn.execute(
        "SELECT session_id FROM ppg_sessions ORDER BY captured_at DESC LIMIT 1"
    ).fetchone()
    conn.close()
    if not row:
        print("No PPG sessions in database.")
        sys.exit(1)
    return row[0]


def get_session_meta(db_path: Path, session_id: str) -> dict:
    conn = duckdb.connect(str(db_path), read_only=True)
    row = conn.execute(
        "SELECT session_id, captured_at, duration_s, csv_filename FROM ppg_sessions WHERE session_id = ?",
        [session_id]
    ).fetchone()
    conn.close()
    if not row:
        print(f"Session '{session_id}' not found.")
        sys.exit(1)
    return {"session_id": row[0], "captured_at": str(row[1]),
            "duration_s": row[2], "csv_filename": row[3]}


# ── API interaction ───────────────────────────────────────────────────────────

def post_estimates(api_base: str, session_id: str, windows: list[dict],
                   model_id: str) -> None:
    """POST windowed BP estimates to the health-local-core API."""
    payload = {
        "session_id": session_id,
        "model_id": model_id,
        "windows": [
            {
                "window_start_s": w["window_start_s"],
                "window_end_s":   w["window_end_s"],
                "sbp_mmhg":       w.get("sbp"),
                "dbp_mmhg":       w.get("dbp"),
                "n_pulses":       w["n_pulses"],
            }
            for w in windows
        ],
    }
    try:
        r = requests.post(f"{api_base}/ppg/sessions/{session_id}/bp_estimate",
                          json=payload, timeout=10)
        if r.status_code == 200:
            print(f"  Stored {len(windows)} estimates via API")
        else:
            print(f"  API returned {r.status_code}: {r.text[:200]}")
    except requests.exceptions.ConnectionError:
        print(f"  API not reachable at {api_base} — estimates computed but not stored")


# ── Main ──────────────────────────────────────────────────────────────────────

def run(session_id: str, model_data: dict, window_s: float, step_s: float,
        db_path: Path, api_base: str) -> None:
    morph_sbp = model_data["morphology_models"]["sbp"]
    morph_dbp = model_data["morphology_models"]["dbp"]
    model_id  = model_data["created_at"]

    meta = get_session_meta(db_path, session_id)
    print(f"\n  Session      : {session_id[:12]}  ({meta['csv_filename'] or 'unknown'})")
    print(f"  Captured at  : {meta['captured_at']}")
    print(f"  Duration     : {meta['duration_s']:.0f}s")
    print(f"  Window       : {window_s:.0f}s step={step_s:.0f}s")

    feat_path = ensure_features(session_id)
    pulses = load_pulse_features(feat_path)
    print(f"  Pulses loaded: {len(pulses)}")

    if not pulses:
        print("  No pulses found — session may have no contact data.")
        return

    t_start = pulses[0]["foot_time_s"]
    t_end   = pulses[-1]["foot_time_s"]
    windows = window_features(pulses, t_start, t_end, window_s, step_s)

    print(f"\n  {'Window':>6}  {'Time (min)':>10}  {'SBP':>6}  {'DBP':>6}  "
          f"{'n_pulses':>8}  {'n_notch':>7}")
    print("  " + "-"*55)

    sbp_vals, dbp_vals = [], []
    for i, w in enumerate(windows):
        sbp = apply_model(morph_sbp, w["features"])
        dbp = apply_model(morph_dbp, w["features"])
        w["sbp"] = sbp
        w["dbp"] = dbp

        t_min = (w["window_start_s"] - t_start) / 60.0
        sbp_s = f"{sbp:>6.1f}" if sbp is not None else "   n/a"
        dbp_s = f"{dbp:>6.1f}" if dbp is not None else "   n/a"
        print(f"  {i+1:>6}  {t_min:>9.1f}m  {sbp_s}  {dbp_s}  "
              f"{w['n_pulses']:>8}  {w['n_notch']:>7}")

        if sbp is not None: sbp_vals.append(sbp)
        if dbp is not None: dbp_vals.append(dbp)

    if sbp_vals:
        print(f"\n  {'─'*55}")
        print(f"  Session mean : SBP {np.mean(sbp_vals):.1f} ± {np.std(sbp_vals):.1f} mmHg  |  "
              f"DBP {np.mean(dbp_vals):.1f} ± {np.std(dbp_vals):.1f} mmHg")
        print(f"  Range        : SBP {min(sbp_vals):.1f}–{max(sbp_vals):.1f}  |  "
              f"DBP {min(dbp_vals):.1f}–{max(dbp_vals):.1f}")
        print(f"  Windows      : {len(sbp_vals)} valid  ({len(windows)-len(sbp_vals)} skipped)")
    else:
        print("  No valid windows — morphology features may be missing.")
        return

    post_estimates(api_base, session_id, windows, model_id)


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("session_id", nargs="?",
                   help="PPG session_id (use --list to find)")
    p.add_argument("--latest", action="store_true",
                   help="Use the most recently captured PPG session")
    p.add_argument("--list", action="store_true",
                   help="List recent PPG sessions and exit")
    p.add_argument("--model", default=None,
                   help="Path to bp_model_*.json (defaults to most recent in desktop dir)")
    p.add_argument("--window-s", type=float, default=60.0,
                   help="Window size in seconds (default 60)")
    p.add_argument("--step-s", type=float, default=60.0,
                   help="Step between windows in seconds (default 60 = non-overlapping)")
    p.add_argument("--db", default=str(DEFAULT_DB),
                   help=f"DuckDB path (default: {DEFAULT_DB})")
    p.add_argument("--api", default=DEFAULT_API,
                   help=f"API base URL (default: {DEFAULT_API})")
    args = p.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        print(f"DuckDB not found at {db_path}")
        sys.exit(1)

    if args.list:
        list_sessions(db_path)
        return

    session_id = args.session_id
    if args.latest:
        session_id = get_latest_session_id(db_path)
        print(f"  Latest session: {session_id[:12]}")
    if not session_id:
        p.print_help()
        sys.exit(1)

    model_data = load_model(Path(args.model) if args.model else None)

    print(f"\n{'='*60}")
    print("  BP Estimator — Stage 4 continuous estimation")
    print(f"{'='*60}")

    run(session_id, model_data, args.window_s, args.step_s, db_path, args.api)


if __name__ == "__main__":
    main()
