"""bp_calibration.py — Stage 3 Step 4: SBP/DBP regression from PTT + morphology features.

Loads one or more ptt_calibration_*.csv files (output of ptt_calculator.py),
filters to reliable readings (n_ptt ≥ MIN_PTT), and fits Ridge linear regression
models for SBP and DBP.

Features used:
  PTT (ms)        — inversely proportional to BP (shorter PTT = stiffer arteries = higher BP)
  AI% (%)         — Augmentation Index, correlates with arterial stiffness → SBP
  RI              — Reflection Index
  rise_time (ms)  — foot → systolic peak
  pw50 (ms)       — pulse width at 50% amplitude

Outputs:
  Console         — coefficients, R², LOO-CV MAE per feature set
  bp_model_<ts>.json  — model coefficients for bp_estimator.py
  bp_predictions_<ts>.csv  — actual vs predicted (for plotting/auditing)

Usage:
    .venv/bin/python bp_calibration.py ptt_calibration_20260627_221304.csv ptt_calibration_20260627_214451.csv
    .venv/bin/python bp_calibration.py --all           # uses all ptt_calibration_*.csv in cwd
    .venv/bin/python bp_calibration.py --all --plot    # also shows scatter plot
"""
from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime
from pathlib import Path

import numpy as np
from sklearn.linear_model import Ridge
from sklearn.model_selection import LeaveOneOut
from sklearn.preprocessing import StandardScaler

MIN_PTT = 5          # minimum R-peak→foot pairs for a reading to be trusted
MIN_NOTCH = 5        # minimum notch pulses for AI% / RI to be trustworthy


# ── Data loading ──────────────────────────────────────────────────────────────

def load_reading(row: dict, source_file: str) -> dict | None:
    """Return a clean feature dict or None if the reading is too noisy."""
    try:
        n_ptt = int(row.get("n_ptt") or 0)
        n_notch = int(row.get("n_notch_pulses") or 0)
        sbp = row.get("sbp_mmhg"); dbp = row.get("dbp_mmhg")
        ptt = row.get("mean_ptt_ms")
        ai = row.get("mean_ai_pct"); ri = row.get("mean_ri")
        rise = row.get("mean_rise_ms"); pw50 = row.get("mean_pw50_ms")

        if not sbp or not dbp or not ptt or sbp in ("", "None") or ptt in ("", "None"):
            return None
        if n_ptt < MIN_PTT:
            return None

        d = {
            "source": source_file,
            "reading_num": int(row.get("reading_num") or 0),
            "sbp": float(sbp),
            "dbp": float(dbp),
            "ptt_ms": float(ptt),
            "n_ptt": n_ptt,
        }
        # Morphology features: only if enough notch pulses
        d["ai_pct"] = float(ai) if ai and ai not in ("", "None") and n_notch >= MIN_NOTCH else None
        d["ri"] = float(ri) if ri and ri not in ("", "None") and n_notch >= MIN_NOTCH else None
        d["rise_ms"] = float(rise) if rise and rise not in ("", "None") else None
        d["pw50_ms"] = float(pw50) if pw50 and pw50 not in ("", "None") else None
        return d
    except (ValueError, TypeError):
        return None


def load_all(csv_paths: list[Path]) -> list[dict]:
    readings = []
    for p in csv_paths:
        with open(p) as f:
            for row in csv.DictReader(f):
                r = load_reading(row, p.name)
                if r:
                    readings.append(r)
    return readings


# ── Model fitting ─────────────────────────────────────────────────────────────

FEATURE_SETS = {
    "PTT only": ["ptt_ms"],
    "PTT + AI%": ["ptt_ms", "ai_pct"],
    "PTT + AI% + rise": ["ptt_ms", "ai_pct", "rise_ms"],
    "PTT + AI% + RI + rise": ["ptt_ms", "ai_pct", "ri", "rise_ms"],
}

# Morphology-only feature sets — used when no ECG/PTT is available (continuous mode)
MORPH_FEATURE_SETS = {
    "AI% only": ["ai_pct"],
    "AI% + RI": ["ai_pct", "ri"],
    "AI% + rise": ["ai_pct", "rise_ms"],
    "AI% + RI + rise + pw50": ["ai_pct", "ri", "rise_ms", "pw50_ms"],
}


def build_Xy(readings: list[dict], feature_names: list[str], target: str
             ) -> tuple[np.ndarray, np.ndarray, list[int]]:
    """Return X, y, and the row indices that were included (all features present)."""
    X_rows, y_rows, idx_rows = [], [], []
    for i, r in enumerate(readings):
        if r.get(target) is None:
            continue
        row_feats = [r.get(fn) for fn in feature_names]
        if any(v is None for v in row_feats):
            continue
        X_rows.append(row_feats)
        y_rows.append(r[target])
        idx_rows.append(i)
    return np.array(X_rows, dtype=float), np.array(y_rows, dtype=float), idx_rows


def loo_cv(X: np.ndarray, y: np.ndarray, alpha: float = 1.0
           ) -> tuple[float, float, np.ndarray]:
    """Leave-one-out CV. Returns (mean_abs_err, std_abs_err, pred_array)."""
    loo = LeaveOneOut()
    preds = np.zeros_like(y)
    for train_idx, test_idx in loo.split(X):
        scaler = StandardScaler()
        Xtr = scaler.fit_transform(X[train_idx])
        Xte = scaler.transform(X[test_idx])
        mdl = Ridge(alpha=alpha).fit(Xtr, y[train_idx])
        preds[test_idx] = mdl.predict(Xte)
    errs = np.abs(preds - y)
    return float(np.mean(errs)), float(np.std(errs)), preds


def fit_model(X: np.ndarray, y: np.ndarray, alpha: float = 1.0
              ) -> tuple[Ridge, StandardScaler]:
    scaler = StandardScaler()
    Xs = scaler.fit_transform(X)
    model = Ridge(alpha=alpha).fit(Xs, y)
    return model, scaler


# ── Output helpers ────────────────────────────────────────────────────────────

def model_to_dict(model: Ridge, scaler: StandardScaler,
                  feature_names: list[str], target: str) -> dict:
    return {
        "target": target,
        "feature_names": feature_names,
        "intercept": float(model.intercept_),
        "coefficients": [float(c) for c in model.coef_],
        "scaler_mean": [float(m) for m in scaler.mean_],
        "scaler_std": [float(s) for s in scaler.scale_],
    }


def predict(model_dict: dict, features: dict) -> float:
    """Apply a saved model_dict to a feature dict. Returns predicted value."""
    vals = [features[fn] for fn in model_dict["feature_names"]]
    scaled = [(v - m) / s for v, m, s in zip(
        vals, model_dict["scaler_mean"], model_dict["scaler_std"])]
    return model_dict["intercept"] + sum(c * x for c, x in zip(
        model_dict["coefficients"], scaled))


# ── Main ──────────────────────────────────────────────────────────────────────

def run(csv_paths: list[Path], do_plot: bool, alpha: float) -> None:
    readings = load_all(csv_paths)
    n = len(readings)
    print(f"\n{'='*70}")
    print(f"  Loaded {n} valid readings from {len(csv_paths)} calibration file(s)")
    if n < 3:
        print("  Need at least 3 valid readings. Run more calibration sessions first.")
        return

    print(f"\n  {'Source':<40}  {'SBP':>6}  {'DBP':>6}  {'PTT(ms)':>8}  {'AI%':>7}  {'n_ptt':>5}")
    print("  " + "-"*70)
    for r in readings:
        ai = f"{r['ai_pct']:.1f}%" if r.get("ai_pct") is not None else "  n/a"
        print(f"  {r['source']:<40}  {r['sbp']:>6.0f}  {r['dbp']:>6.0f}  "
              f"{r['ptt_ms']:>8.1f}  {ai:>7}  {r['n_ptt']:>5}")

    # Determine best feature set (most complete with all n readings)
    best_fset = "PTT only"
    for fname, feats in FEATURE_SETS.items():
        _, _, idx = build_Xy(readings, feats, "sbp")
        if len(idx) == n:
            best_fset = fname

    print(f"\n  Best feature set with all {n} readings: '{best_fset}'")
    best_feats = FEATURE_SETS[best_fset]

    results: dict[str, dict] = {}

    for target in ("sbp", "dbp"):
        print(f"\n{'─'*70}")
        print(f"  TARGET: {'SBP' if target=='sbp' else 'DBP'} (mmHg)")
        print(f"{'─'*70}")

        best_mae = float("inf")
        best_model_dict = None

        for fname, feats in FEATURE_SETS.items():
            X, y, idx = build_Xy(readings, feats, target)
            if len(idx) < 3:
                continue
            mae, mae_std, _ = loo_cv(X, y, alpha=alpha)
            model, scaler = fit_model(X, y, alpha=alpha)
            y_pred = model.predict(scaler.transform(X))
            ss_res = np.sum((y - y_pred)**2)
            ss_tot = np.sum((y - np.mean(y))**2)
            r2 = 1 - ss_res / ss_tot if ss_tot > 0 else 0.0

            flag = " ← BEST" if mae < best_mae else ""
            print(f"  [{fname:<28}]  n={len(idx)}  R²={r2:+.3f}  "
                  f"LOO-MAE={mae:.1f}±{mae_std:.1f} mmHg{flag}")

            if mae < best_mae:
                best_mae = mae
                best_model_dict = model_to_dict(model, scaler, feats, target)

        results[target] = best_model_dict

    # Morphology-only models (no PTT — for continuous estimation without ECG)
    morph_results: dict[str, dict] = {}
    print(f"\n{'─'*70}")
    print("  MORPHOLOGY-ONLY MODELS (for continuous estimation, no ECG/PTT):")
    for target in ("sbp", "dbp"):
        best_mae, best_mdict = float("inf"), None
        for fname, feats in MORPH_FEATURE_SETS.items():
            X, y, idx = build_Xy(readings, feats, target)
            if len(idx) < 3:
                continue
            mae, mae_std, _ = loo_cv(X, y, alpha=alpha)
            model, scaler = fit_model(X, y, alpha=alpha)
            label = "SBP" if target == "sbp" else "DBP"
            flag = " ← BEST" if mae < best_mae else ""
            print(f"  {label} [{fname:<28}]  n={len(idx)}  LOO-MAE={mae:.1f}±{mae_std:.1f} mmHg{flag}")
            if mae < best_mae:
                best_mae, best_mdict = mae, model_to_dict(model, scaler, feats, target)
        morph_results[target] = best_mdict

    # Show final predictions with best models
    print(f"\n{'='*70}")
    print("  PREDICTIONS (best models):")
    print(f"  {'Source':<40}  {'SBP_act':>7}  {'SBP_pred':>8}  "
          f"{'SBP_err':>7}  {'DBP_act':>7}  {'DBP_pred':>8}  {'DBP_err':>7}")
    print("  " + "-"*70)

    pred_rows = []
    for r in readings:
        sbp_pred = predict(results["sbp"], r) if results["sbp"] else None
        dbp_pred = predict(results["dbp"], r) if results["dbp"] else None
        sbp_err = abs(r["sbp"] - sbp_pred) if sbp_pred is not None else None
        dbp_err = abs(r["dbp"] - dbp_pred) if dbp_pred is not None else None

        def fmt(v): return f"{v:>8.1f}" if v is not None else "     n/a"
        def fmterr(v): return f"{v:>+7.1f}" if v is not None else "     n/a"

        print(f"  {r['source']:<40}  {r['sbp']:>7.0f}  {fmt(sbp_pred)}  "
              f"{fmterr(sbp_pred-r['sbp'] if sbp_pred else None)}  "
              f"{r['dbp']:>7.0f}  {fmt(dbp_pred)}  "
              f"{fmterr(dbp_pred-r['dbp'] if dbp_pred else None)}")

        pred_rows.append({
            "source": r["source"], "reading_num": r["reading_num"],
            "sbp_actual": r["sbp"], "dbp_actual": r["dbp"],
            "sbp_pred": f"{sbp_pred:.1f}" if sbp_pred else "",
            "dbp_pred": f"{dbp_pred:.1f}" if dbp_pred else "",
            "sbp_err": f"{sbp_pred-r['sbp']:.1f}" if sbp_pred else "",
            "dbp_err": f"{dbp_pred-r['dbp']:.1f}" if dbp_pred else "",
            "ptt_ms": r["ptt_ms"], "n_ptt": r["n_ptt"],
        })

    # Save model JSON
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    model_path = Path(f"bp_model_{ts}.json")
    model_out = {
        "created_at": ts,
        "calibration_files": [str(p) for p in csv_paths],
        "n_readings": len(readings),
        "min_ptt_filter": MIN_PTT,
        "ridge_alpha": alpha,
        "models": results,
        "morphology_models": morph_results,
    }
    model_path.write_text(json.dumps(model_out, indent=2))
    print(f"\n  Model saved: {model_path}")

    # Save predictions CSV
    pred_path = Path(f"bp_predictions_{ts}.csv")
    with open(pred_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(pred_rows[0].keys()))
        w.writeheader()
        w.writerows(pred_rows)
    print(f"  Predictions saved: {pred_path}")

    if results.get("sbp"):
        print(f"\n  SBP model: {results['sbp']['feature_names']}")
        for fn, c in zip(results["sbp"]["feature_names"], results["sbp"]["coefficients"]):
            print(f"    {fn}: {c:+.4f} (scaled)")
    if results.get("dbp"):
        print(f"\n  DBP model: {results['dbp']['feature_names']}")
        for fn, c in zip(results["dbp"]["feature_names"], results["dbp"]["coefficients"]):
            print(f"    {fn}: {c:+.4f} (scaled)")

    print(f"\n  NOTE: With only {n} calibration points, add morning session before")
    print(f"  trusting predictions. Target: ≥9 readings across ≥3 BP states.")

    if do_plot:
        _plot(readings, results)


def _plot(readings: list[dict], results: dict) -> None:
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        print("  matplotlib not installed — skipping plot")
        return

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    for ax, target, label, color in [
        (axes[0], "sbp", "SBP", "#1d4ed8"),
        (axes[1], "dbp", "DBP", "#dc2626"),
    ]:
        actuals, preds = [], []
        for r in readings:
            if results.get(target) is None:
                continue
            try:
                p = predict(results[target], r)
                actuals.append(r[target])
                preds.append(p)
            except (KeyError, TypeError):
                pass
        if not actuals:
            continue
        actuals = np.array(actuals)
        preds = np.array(preds)
        mn, mx = min(actuals.min(), preds.min()) - 5, max(actuals.max(), preds.max()) + 5
        ax.plot([mn, mx], [mn, mx], "k--", lw=1, alpha=0.4, label="ideal")
        ax.scatter(actuals, preds, s=80, color=color, zorder=5)
        for a, p in zip(actuals, preds):
            ax.plot([a, a], [a, p], color=color, lw=0.8, alpha=0.5)
        mae = np.mean(np.abs(preds - actuals))
        ax.set_title(f"{label}  (train MAE={mae:.1f} mmHg)")
        ax.set_xlabel(f"Actual {label} (mmHg)")
        ax.set_ylabel(f"Predicted {label} (mmHg)")
        ax.set_xlim(mn, mx); ax.set_ylim(mn, mx)
        ax.set_aspect("equal")
        ax.grid(alpha=0.3)
        ax.legend(fontsize=9)
    plt.suptitle("BP Calibration — Actual vs Predicted", fontsize=12)
    plt.tight_layout()
    plt.show()


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("csv_files", nargs="*",
                   help="ptt_calibration_*.csv files to use")
    p.add_argument("--all", action="store_true",
                   help="Use all ptt_calibration_*.csv in current directory")
    p.add_argument("--plot", action="store_true",
                   help="Show actual vs predicted scatter plot")
    p.add_argument("--alpha", type=float, default=1.0,
                   help="Ridge regularisation strength (default 1.0)")
    args = p.parse_args()

    paths = []
    if args.all:
        paths = sorted(Path(".").glob("ptt_calibration_*.csv"))
    else:
        paths = [Path(f) for f in args.csv_files]

    missing = [p for p in paths if not p.exists()]
    if missing:
        print(f"File(s) not found: {missing}")
        return
    if not paths:
        p.print_help()
        return

    run(paths, args.plot, args.alpha)


if __name__ == "__main__":
    main()
