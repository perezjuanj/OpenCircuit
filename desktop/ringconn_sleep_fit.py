#!/usr/bin/env python3
"""Supervised fit of OpenCircuit's sleep staging to RingConn's own hypnogram.

RingConn computes its hypnogram ON-DEVICE and syncs it to its cloud as `sleepPhases`
(a JSON array of {start, end, sleepType} with sleepType ∈ SLEEP_AWAKE /
SLEEP_AWAKE_IN_BED / SLEEP_LIGHT / SLEEP_DEEP / SLEEP_REM). The thresholds it uses are
unreadable from its stripped binary, so the only path to matching it is SUPERVISED
FITTING: capture a night's `sleepPhases` (see docs/RUNBOOK_SLEEP_GROUNDTRUTH.md) AND
our decoded per-epoch signals for the same night, then search our staging parameters to
reproduce its per-epoch labels.

This harness:
  1. Loads our per-epoch features from a CSV (the extract_last_night.py format:
     utc_iso,local,counter,layout,hr_bpm,hrv_ms,spo2_pct,rr_brpm,motion).
  2. Loads RingConn ground truth: parses `sleepPhases`, expands the segments to
     PER-EPOCH labels on our 150 s epoch grid.
  3. Re-implements our staging as a PARAMETERIZED function whose parameters mirror the
     Swift `SleepStaging.Tuning` EXACTLY (and the motion-based in-bed detection it
     depends on, ported from SleepDetection.swift / BulkSleep.swift). This is a faithful
     port — it is the thing we fit.
  4. FITS the Tuning by coordinate descent to MAXIMIZE per-epoch agreement (overall
     accuracy + macro-F1) vs RingConn. It also reports whether enabling an rrVarWeight
     cue, a SpO2-dip cue, or a multi-night BASELINE-RELATIVE normalization helps.
  5. OUTPUTS a per-stage confusion matrix + F1, night-total minute agreement, the best
     params, and a ready-to-paste Swift `Tuning(...)` initializer.

Stdlib only (numpy used opportunistically if present, but never required; scipy too).

Usage:
  # Prove it works NOW, no real data needed (generates a synthetic night + labels):
  python3 ringconn_sleep_fit.py --synthetic

  # Real night (one or more, comma-separated and positionally paired):
  python3 ringconn_sleep_fit.py \
      --features captures/last_night_extracted.csv \
      --groundtruth captures/groundtruth_sleep_20260621.json

Faithful to: ios/OpenCircuitKit/Sources/OpenCircuitKit/Analytics/SleepStaging.swift,
             .../Analytics/SleepDetection.swift, .../BulkSleep.swift (read 2026-06-21).
"""
from __future__ import annotations

import argparse
import ast
import csv
import json
import math
import os
import random
import sys
import tempfile
from dataclasses import dataclass, replace

from datetime import datetime, timezone

# --- Constants mirrored from the Swift side -----------------------------------------
SYNC_EPOCH = 1_577_793_600          # Command.syncEpoch (Opcodes.swift)
EPOCH_SECONDS = 150                 # BulkRecord.epochSeconds (0x96)
MOTION_STILL_THRESHOLD = 2.0        # ActivityPeriod.motionStillThreshold
GRAVITY_WINDOW_MINUTES = 15         # ActivityPeriod.gravityWindowMinutes
GRAVITY_STILL_FRACTION = 0.70       # ActivityPeriod.gravityStillFraction
GRAVITY_MAX_GAP = 20 * 60           # ActivityPeriod.gravityMaxGap
ACTIVITY_CHANGE_THRESHOLD = 15 * 60  # ActivityPeriod.activityChangeThreshold
MIN_SLEEP_DURATION = 60 * 60        # ActivityPeriod.minSleepDuration
VALID_BPM = range(30, 221)          # LiveHR.validBPM (30...220)

# Our 4 evaluation classes (the RingConn label space collapsed to ours).
CLASSES = ["deep", "light", "rem", "awake"]

# RingConn sleepType -> our class (the mapping the task specifies).
SLEEPTYPE_MAP = {
    "SLEEP_DEEP": "deep",
    "SLEEP_LIGHT": "light",
    "SLEEP_REM": "rem",
    "SLEEP_AWAKE": "awake",
    "SLEEP_AWAKE_IN_BED": "awake",
}

# Our SleepStage enum -> evaluation class.
STAGE_TO_CLASS = {
    "asleepDeep": "deep",
    "asleepCore": "light",
    "asleepREM": "rem",
    "awake": "awake",
}


# --- Tuning: mirrors Swift SleepStaging.Tuning EXACTLY, plus experimental extensions --
@dataclass
class Tuning:
    # --- These 17 fields mirror Swift SleepStaging.Tuning one-for-one (same defaults) --
    awakeMotion: int = 15
    deepHRPercentile: float = 0.42
    remHRPercentile: float = 0.86
    deepVarPercentile: float = 0.50
    remVarPercentile: float = 0.84
    variabilityHalfWindow: int = 2
    deepVarFloor: float = 2.5
    remVarFloor: float = 3.0
    minDeepRunEpochs: int = 3
    minREMRunEpochs: int = 2
    minAwakeRunEpochs: int = 1
    hrvVarWeight: float = 0.5
    sleepFloorPercentile: float = 0.12
    wakeHRMarginBPM: float = 18.0
    hrWakeHalfWindow: int = 2
    onsetSustainEpochs: int = 6
    minHRWakeRunEpochs: int = 5

    # --- Experimental extensions (NOT in Swift Tuning yet; off by default). The fit
    #     reports whether turning these on helps; if so, add them to the Swift struct. --
    rrVarWeight: float = 0.0        # fuse respiratory-rate short-term variability into the var score
    spo2DipEnabled: bool = False    # treat an SpO2 dip vs the night median as a REM cue
    spo2DipDelta: float = 3.0       # %SpO2 below the night median to count as a dip

    # Names of the 17 fields that map to the real Swift initializer.
    SWIFT_FIELDS = (
        "awakeMotion", "deepHRPercentile", "remHRPercentile", "deepVarPercentile",
        "remVarPercentile", "variabilityHalfWindow", "deepVarFloor", "remVarFloor",
        "minDeepRunEpochs", "minREMRunEpochs", "minAwakeRunEpochs", "hrvVarWeight",
        "sleepFloorPercentile", "wakeHRMarginBPM", "hrWakeHalfWindow",
        "onsetSustainEpochs", "minHRWakeRunEpochs",
    )


# --- Per-epoch feature row ----------------------------------------------------------
@dataclass
class Epoch:
    counter: int
    time: float           # unix seconds (counter + SYNC_EPOCH)
    layout: str
    hr: "float | None"
    hrv: "float | None"
    spo2: "float | None"
    rr: "float | None"
    motion: list          # the 5 [10:15] per-30 s counts; idle -> [1,1,1,1,1]


# ====================================================================================
# Loaders
# ====================================================================================
def _as_float(s):
    s = (s or "").strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def _parse_motion(s):
    s = (s or "").strip()
    if not s:
        return [1, 1, 1, 1, 1]      # idle template: motion 01×5 (BulkRecord.layout == .idle)
    try:
        v = ast.literal_eval(s)
        if isinstance(v, (list, tuple)) and len(v) == 5:
            return [int(x) for x in v]
    except (ValueError, SyntaxError):
        pass
    return [1, 1, 1, 1, 1]


def load_features(csv_path, start=None, end=None):
    """Load extract_last_night.py-format CSV into [Epoch], optionally time-filtered.

    Columns: utc_iso,local,counter,layout,hr_bpm,hrv_ms,spo2_pct,rr_brpm,motion.
    `hr` is gated to the same valid band the Swift decoder uses (30…220, idle dropped),
    so the forward-fill behaves exactly like BulkRecord.heartRate.
    """
    epochs = []
    with open(csv_path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                counter = int(row["counter"])
            except (KeyError, ValueError, TypeError):
                continue
            t = counter + SYNC_EPOCH
            if start is not None and t < start:
                continue
            if end is not None and t > end:
                continue
            layout = (row.get("layout") or "").strip()
            hr = _as_float(row.get("hr_bpm"))
            if hr is not None and (layout == "idle" or int(hr) not in VALID_BPM):
                hr = None
            epochs.append(Epoch(
                counter=counter, time=float(t), layout=layout,
                hr=hr,
                hrv=_as_float(row.get("hrv_ms")),
                spo2=_as_float(row.get("spo2_pct")),
                rr=_as_float(row.get("rr_brpm")),
                motion=_parse_motion(row.get("motion")),
            ))
    epochs.sort(key=lambda e: e.counter)
    return epochs


def _find_sleep_phases(obj):
    """Recursively locate a `sleepPhases`-like list anywhere in the parsed JSON."""
    if isinstance(obj, list):
        # The file itself may be the array of phase dicts.
        if obj and isinstance(obj[0], dict) and any(
            k in obj[0] for k in ("sleepType", "sleep_type", "type", "stage")
        ):
            return obj
        for item in obj:
            found = _find_sleep_phases(item)
            if found is not None:
                return found
        return None
    if isinstance(obj, dict):
        for key in ("sleepPhases", "sleep_phases", "phases", "sleepStages", "stages"):
            v = obj.get(key)
            if isinstance(v, list) and v and isinstance(v[0], dict):
                return v
        for v in obj.values():
            found = _find_sleep_phases(v)
            if found is not None:
                return found
    return None


def _to_unix_seconds(v):
    """Coerce a unix timestamp that may be in seconds or milliseconds to seconds."""
    f = float(v)
    return f / 1000.0 if f > 1e11 else f


def _norm_sleeptype(s):
    s = str(s).strip().upper()
    if s in SLEEPTYPE_MAP:
        return SLEEPTYPE_MAP[s]
    # tolerate values without the SLEEP_ prefix or with extra qualifiers
    for key, cls in SLEEPTYPE_MAP.items():
        if key in s or key.replace("SLEEP_", "") in s:
            return cls
    if "AWAKE" in s or "WAKE" in s:
        return "awake"
    return None


def load_groundtruth(json_path):
    """Parse a captured RingConn /sleep response body into [(start_unix, end_unix, class)].

    Robust to the body being the raw `sleepPhases` array OR a full response envelope that
    nests it (api.ringconn.com wraps payloads under data/result keys). Timestamps are
    accepted in unix seconds or milliseconds.
    """
    with open(json_path) as f:
        obj = json.load(f)
    phases = _find_sleep_phases(obj)
    if not phases:
        raise ValueError(f"no sleepPhases array found in {json_path}")
    out = []
    for p in phases:
        st = p.get("start", p.get("startTime", p.get("begin", p.get("beginTime"))))
        en = p.get("end", p.get("endTime", p.get("finish", p.get("finishTime"))))
        typ = p.get("sleepType", p.get("sleep_type", p.get("type", p.get("stage"))))
        if st is None or en is None or typ is None:
            continue
        cls = _norm_sleeptype(typ)
        if cls is None:
            continue
        out.append((_to_unix_seconds(st), _to_unix_seconds(en), cls))
    out.sort(key=lambda x: x[0])
    return out


def expand_groundtruth(epochs, gt_segments):
    """Map RingConn segments onto our epoch grid: counter -> class for covered epochs."""
    labels = {}
    for e in epochs:
        for (st, en, cls) in gt_segments:
            if st <= e.time < en:
                labels[e.counter] = cls
                break
    return labels


# ====================================================================================
# Motion-based in-bed detection (port of SleepDetection.swift + BulkSleep.mainSleep)
# ====================================================================================
def _motion_timeline(epochs):
    """Expand epochs to the per-30 s (time, movement) motion timeline (5 per epoch)."""
    times, deltas = [], []
    for e in epochs:
        base = e.time
        for k in range(5):
            times.append(base + 30.0 * k)
            deltas.append(float(e.motion[k]))
    return times, deltas


def _filter_merge(temps):
    """Port of ActivityPeriod.filterMerge — temps: list of [activity, start, end]."""
    if not temps:
        return []
    acts = [list(t) for t in temps]
    merged = []
    i = 0
    while i < len(acts):
        cur = acts[i]
        if (cur[2] - cur[1]) < ACTIVITY_CHANGE_THRESHOLD:
            if i > 0 and i + 1 < len(acts) and acts[i - 1][0] == acts[i + 1][0] and merged:
                prev = merged.pop()
                merged.append([prev[0], prev[1], acts[i + 1][2]])
                i += 1
            elif i + 1 < len(acts):
                acts[i + 1] = [acts[i + 1][0], cur[1], acts[i + 1][2]]
            elif merged:
                prev = merged.pop()
                merged.append([prev[0], prev[1], cur[2]])
        else:
            merged.append(cur)
        i += 1
    return merged


def _detect_periods(times, deltas):
    """Port of ActivityPeriod.detect (motion front-end). Returns [(activity, start, end)]."""
    n = len(deltas)
    if len(times) != n or n < 2:
        return []
    diffs = []
    for i in range(1, n):
        d = int(times[i] - times[i - 1])
        if 0 < d < 300:
            diffs.append(d)
    diffs.sort()
    avg = max(1, (diffs[len(diffs) // 2] if diffs else 60))
    window = max((GRAVITY_WINDOW_MINUTES * 60) // avg, 3)
    half = window // 2
    is_sleep = [False] * n
    for i in range(n):
        s = i - half if i >= half else 0
        e = min(i + half + 1, n)
        win = deltas[s:e]
        still = sum(1 for x in win if x < MOTION_STILL_THRESHOLD)
        is_sleep[i] = (still / len(win)) >= GRAVITY_STILL_FRACTION
    temps = []
    run_start = 0
    for i in range(1, n + 1):
        end_of_data = (i == n)
        class_change = (not end_of_data) and is_sleep[i] != is_sleep[run_start]
        gap_break = (not end_of_data) and (times[i] - times[i - 1] > GRAVITY_MAX_GAP)
        if end_of_data or class_change or gap_break:
            temps.append(["sleep" if is_sleep[run_start] else "active",
                          times[run_start], times[i - 1]])
            if not end_of_data:
                run_start = i
    return _filter_merge(temps)


def _main_sleep(epochs):
    """Port of BulkSleep.mainSleep: first .sleep period > 1 h. Returns (start, end) or None."""
    times, deltas = _motion_timeline(epochs)
    for (act, st, en) in _detect_periods(times, deltas):
        if act == "sleep" and (en - st) > MIN_SLEEP_DURATION:
            return (st, en)
    return None


def _contiguous_fragments(epochs, max_gap=GRAVITY_MAX_GAP):
    """Port of BulkSleep.contiguousFragments: split on counter gaps > maxGap."""
    s = sorted(epochs, key=lambda e: e.counter)
    if not s:
        return []
    frags, cur = [], [s[0]]
    for i in range(1, len(s)):
        if (s[i].counter - s[i - 1].counter) > max_gap:
            frags.append(cur)
            cur = [s[i]]
        else:
            cur.append(s[i])
    frags.append(cur)
    return frags


# ====================================================================================
# Numeric helpers (ported to match the Swift semantics exactly)
# ====================================================================================
def percentile(sorted_xs, q):
    """Value at quantile q (nearest-rank, round-half-away-from-zero) — matches Swift."""
    if not sorted_xs:
        return 0.0
    idx = int(math.floor(q * (len(sorted_xs) - 1) + 0.5))   # Swift .rounded() for q,n>=0
    return sorted_xs[min(max(idx, 0), len(sorted_xs) - 1)]


def rolling_sd(xs, half):
    """Centered rolling population SD over ±half (matches SleepStaging.rollingSD)."""
    n = len(xs)
    out = [0.0] * n
    for i in range(n):
        s = max(0, i - half)
        e = min(n - 1, i + half)
        w = xs[s:e + 1]
        mean = sum(w) / len(w)
        var = sum((x - mean) ** 2 for x in w) / len(w)
        out[i] = math.sqrt(var)
    return out


def rolling_median(xs, half):
    """Centered rolling median over ±half (matches SleepStaging.rollingMedian)."""
    n = len(xs)
    out = [0.0] * n
    for i in range(n):
        s = max(0, i - half)
        e = min(n - 1, i + half)
        w = sorted(xs[s:e + 1])
        out[i] = w[len(w) // 2]
    return out


def filled_forward(xs):
    """Forward-then-backward fill of None gaps (matches SleepStaging.filledForward)."""
    out = list(xs)
    last = None
    for i in range(len(out)):
        if out[i] is not None:
            last = out[i]
        else:
            out[i] = last
    nxt = None
    for i in range(len(out) - 1, -1, -1):
        if out[i] is not None:
            nxt = out[i]
        else:
            out[i] = nxt
    return out


def _erode_short_hr_wake(awake, motion_awake, min_run):
    """Port of SleepStaging.erodeShortHRWake (mutates `awake`)."""
    n = len(awake)
    i = 0
    while i < n:
        if not awake[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and awake[j + 1]:
            j += 1
        run = j - i + 1
        has_motion = any(motion_awake[k] for k in range(i, j + 1))
        if run < min_run and not has_motion:
            for k in range(i, j + 1):
                awake[k] = False
        i = j + 1


def _sleep_span(awake, sustain):
    """Port of SleepStaging.sleepSpan: (first, last) of sustained asleep runs, or None."""
    n = len(awake)
    first = last = None
    i = 0
    while i < n:
        if awake[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and not awake[j + 1]:
            j += 1
        if j - i + 1 >= sustain:
            if first is None:
                first = i
            last = j
        i = j + 1
    if first is not None and last is not None:
        return (first, last)
    return None


def _smooth(stages, t):
    """Port of SleepStaging.smooth: short deep/rem/awake runs -> light ('asleepCore')."""
    n = len(stages)
    i = 0
    while i < n:
        j = i
        while j + 1 < n and stages[j + 1] == stages[i]:
            j += 1
        run = j - i + 1
        min_run = None
        if stages[i] == "deep":
            min_run = t.minDeepRunEpochs
        elif stages[i] == "rem":
            min_run = t.minREMRunEpochs
        elif stages[i] == "awake":
            min_run = t.minAwakeRunEpochs
        if min_run is not None and run < min_run:
            for k in range(i, j + 1):
                stages[k] = "light"
        i = j + 1


# ====================================================================================
# Staging (port of SleepStaging.classifyContiguous), split into Tuning-independent
# preparation (cached across fit iterations) and the Tuning-dependent decision.
# ====================================================================================
@dataclass
class PreparedFragment:
    """Per-fragment rows after motion-block detection + forward-fill (Tuning-free)."""
    counters: list
    hr: list
    hrv: list   # float | None
    rr: list    # float | None
    spo2: list  # float | None
    motion_sum: list


def prepare_night(epochs):
    """Split into contiguous fragments, detect each in-bed block, forward-fill vitals.

    Mirrors the Tuning-INDEPENDENT head of SleepStaging.classifyContiguous (mainSleep +
    the inBlock forward-fill). Returns a list of PreparedFragment, one per fragment that
    contains a detectable >1 h sleep block with ≥2 usable rows.
    """
    out = []
    for frag in _contiguous_fragments(epochs):
        block = _main_sleep(frag)
        if block is None:
            continue
        bstart, bend = block
        in_block = sorted([e for e in frag if bstart <= e.time <= bend],
                          key=lambda e: e.counter)
        last_hr = last_hrv = last_rr = None
        pf = PreparedFragment([], [], [], [], [], [])
        for e in in_block:
            if e.hr is not None:
                last_hr = e.hr
            if e.hrv is not None and e.hrv > 0:
                last_hrv = e.hrv
            if e.rr is not None and e.rr > 0:
                last_rr = e.rr
            if last_hr is None:
                continue
            m = sum(0 if c == 1 else c for c in e.motion)
            pf.counters.append(e.counter)
            pf.hr.append(float(last_hr))
            pf.hrv.append(last_hrv)
            pf.rr.append(last_rr)
            pf.spo2.append(e.spo2)
            pf.motion_sum.append(m)
        if len(pf.counters) >= 2:
            out.append(pf)
    return out


def _variability(pf, t):
    """Blended rolling variability: HR SD (+ hrvVarWeight·HRV SD, + rrVarWeight·RR SD)."""
    var = rolling_sd(pf.hr, t.variabilityHalfWindow)
    if t.hrvVarWeight > 0 and any(v is not None for v in pf.hrv):
        hrv = [float(v) if v is not None else 0.0 for v in filled_forward(pf.hrv)]
        hv = rolling_sd(hrv, t.variabilityHalfWindow)
        for i in range(len(var)):
            var[i] += t.hrvVarWeight * hv[i]
    if t.rrVarWeight > 0 and any(v is not None for v in pf.rr):
        rr = [float(v) if v is not None else 0.0 for v in filled_forward(pf.rr)]
        rv = rolling_sd(rr, t.variabilityHalfWindow)
        for i in range(len(var)):
            var[i] += t.rrVarWeight * rv[i]
    return var


def classify_prepared(pf, t, band_pool=None):
    """Tuning-dependent decision over one PreparedFragment. Returns {counter -> class}.

    Faithful port of the body of SleepStaging.classifyContiguous, returning per-epoch
    labels keyed by epoch counter rather than emitting time segments. `band_pool`, when
    given, supplies (sorted_hr, sorted_var) for the Deep/REM HR/var bands from an external
    (e.g. multi-night) distribution — the BASELINE-RELATIVE variant; None uses this
    fragment's own in-window asleep distribution (the single-night Swift behaviour).
    """
    hr = pf.hr
    n = len(hr)
    var = _variability(pf, t)

    sleep_floor = percentile(sorted(hr), t.sleepFloorPercentile)
    wake_threshold = sleep_floor + t.wakeHRMarginBPM
    sm_hr = rolling_median(hr, t.hrWakeHalfWindow)
    motion_awake = [pf.motion_sum[i] > t.awakeMotion for i in range(n)]
    awake = [sm_hr[i] >= wake_threshold or motion_awake[i] for i in range(n)]
    _erode_short_hr_wake(awake, motion_awake, t.minHRWakeRunEpochs)

    span = _sleep_span(awake, t.onsetSustainEpochs)
    if span is None:
        return {}
    lo, hi = span
    window_idx = list(range(lo, hi + 1))
    asleep_idx = [i for i in window_idx if not awake[i]]
    pool = asleep_idx if len(asleep_idx) >= 4 else window_idx

    if band_pool is not None:
        hr_pool, var_pool = band_pool
    else:
        hr_pool = sorted(hr[i] for i in pool)
        var_pool = sorted(var[i] for i in pool)

    deep_hr = percentile(hr_pool, t.deepHRPercentile)
    rem_hr = percentile(hr_pool, t.remHRPercentile)
    deep_var = max(percentile(var_pool, t.deepVarPercentile), t.deepVarFloor)
    rem_var = max(percentile(var_pool, t.remVarPercentile), t.remVarFloor)

    # Optional SpO2-dip cue: an asleep epoch dipping below the night median by spo2DipDelta.
    spo2_dip = [False] * n
    if t.spo2DipEnabled:
        present = sorted(v for v in pf.spo2 if v is not None)
        if present:
            med = present[len(present) // 2]
            for i in range(n):
                spo2_dip[i] = pf.spo2[i] is not None and pf.spo2[i] <= med - t.spo2DipDelta

    stages = []
    for i in window_idx:
        if awake[i]:
            stages.append("awake")
        elif hr[i] <= deep_hr and var[i] <= deep_var:
            stages.append("deep")
        elif hr[i] >= rem_hr or var[i] > rem_var or spo2_dip[i]:
            stages.append("rem")
        else:
            stages.append("light")
    _smooth(stages, t)

    out = {}
    for i in range(n):
        if i < lo:
            out[pf.counters[i]] = "awake"
        elif i <= hi:
            out[pf.counters[i]] = stages[i - lo]
        else:
            out[pf.counters[i]] = "awake"
    return out


def stage_night(prepared, t, band_pool=None):
    """Stage all prepared fragments of one night. Returns {counter -> class}."""
    out = {}
    for pf in prepared:
        out.update(classify_prepared(pf, t, band_pool=band_pool))
    return out


def baseline_band_pool(nights_prepared, t):
    """Pool every night's in-window asleep HR/var into one distribution (rolling baseline).

    The BASELINE-RELATIVE variant draws Deep/REM bands from a multi-night pool instead of
    each night's own percentiles. Uses the Tuning's awake detection to pick asleep epochs
    so the pool is "asleep HR across nights"; falls back to all in-window epochs if a
    night has < 4 asleep epochs (matching the single-night pool fallback).
    """
    hr_all, var_all = [], []
    for prepared in nights_prepared:
        for pf in prepared:
            n = len(pf.hr)
            var = _variability(pf, t)
            sleep_floor = percentile(sorted(pf.hr), t.sleepFloorPercentile)
            wake_threshold = sleep_floor + t.wakeHRMarginBPM
            sm_hr = rolling_median(pf.hr, t.hrWakeHalfWindow)
            motion_awake = [pf.motion_sum[i] > t.awakeMotion for i in range(n)]
            awake = [sm_hr[i] >= wake_threshold or motion_awake[i] for i in range(n)]
            _erode_short_hr_wake(awake, motion_awake, t.minHRWakeRunEpochs)
            span = _sleep_span(awake, t.onsetSustainEpochs)
            if span is None:
                continue
            lo, hi = span
            window_idx = list(range(lo, hi + 1))
            asleep_idx = [i for i in window_idx if not awake[i]]
            pool = asleep_idx if len(asleep_idx) >= 4 else window_idx
            hr_all.extend(pf.hr[i] for i in pool)
            var_all.extend(var[i] for i in pool)
    if not hr_all:
        return None
    return (sorted(hr_all), sorted(var_all))


# ====================================================================================
# Evaluation
# ====================================================================================
def evaluate(nights_pred, nights_truth):
    """Aggregate per-epoch agreement across nights.

    Evaluation set per night = union of (epochs RingConn labels) and (epochs we stage).
    Missing on either side defaults to 'awake' (an epoch outside our in-bed window, or
    outside RingConn's session, is not-asleep). Returns a metrics dict.
    """
    cm = {a: {b: 0 for b in CLASSES} for a in CLASSES}   # cm[truth][pred]
    total = correct = 0
    for pred, truth in zip(nights_pred, nights_truth):
        counters = set(pred) | set(truth)
        for c in counters:
            tlab = truth.get(c, "awake")
            plab = pred.get(c, "awake")
            cm[tlab][plab] += 1
            total += 1
            if tlab == plab:
                correct += 1
    accuracy = correct / total if total else 0.0

    per_class = {}
    f1s = []
    for c in CLASSES:
        tp = cm[c][c]
        fp = sum(cm[o][c] for o in CLASSES if o != c)
        fn = sum(cm[c][o] for o in CLASSES if o != c)
        support = tp + fn
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rec = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
        per_class[c] = {"precision": prec, "recall": rec, "f1": f1, "support": support}
        if support > 0:
            f1s.append(f1)
    macro_f1 = sum(f1s) / len(f1s) if f1s else 0.0

    # Minute totals (each epoch = EPOCH_SECONDS) for night-level agreement.
    pred_min = {c: 0.0 for c in CLASSES}
    truth_min = {c: 0.0 for c in CLASSES}
    for pred, truth in zip(nights_pred, nights_truth):
        counters = set(pred) | set(truth)
        for c in counters:
            pred_min[pred.get(c, "awake")] += EPOCH_SECONDS / 60.0
            truth_min[truth.get(c, "awake")] += EPOCH_SECONDS / 60.0

    return {
        "accuracy": accuracy, "macro_f1": macro_f1, "confusion": cm,
        "per_class": per_class, "total": total,
        "pred_minutes": pred_min, "truth_minutes": truth_min,
    }


def objective(metrics, mode="blend"):
    if mode == "acc":
        return metrics["accuracy"]
    if mode == "f1":
        return metrics["macro_f1"]
    return metrics["accuracy"] + metrics["macro_f1"]   # blend


def score_tuning(nights_prepared, nights_truth, t, mode="blend", band_pool_per_night=None):
    preds = []
    for i, prepared in enumerate(nights_prepared):
        bp = band_pool_per_night[i] if band_pool_per_night else None
        preds.append(stage_night(prepared, t, band_pool=bp))
    m = evaluate(preds, nights_truth)
    return objective(m, mode), m


# ====================================================================================
# Fit — coordinate descent over candidate grids (scipy used if available, else this)
# ====================================================================================
SEARCH_GRID = {
    "awakeMotion": [5, 10, 15, 20, 30, 45],
    "deepHRPercentile": [0.20, 0.30, 0.42, 0.50, 0.60],
    "remHRPercentile": [0.70, 0.78, 0.86, 0.92],
    "deepVarPercentile": [0.30, 0.40, 0.50, 0.60],
    "remVarPercentile": [0.70, 0.78, 0.84, 0.90],
    "variabilityHalfWindow": [1, 2, 3],
    "deepVarFloor": [1.5, 2.5, 3.5],
    "remVarFloor": [2.0, 3.0, 4.0],
    "minDeepRunEpochs": [2, 3, 4],
    "minREMRunEpochs": [1, 2, 3],
    "minAwakeRunEpochs": [1, 2],
    "hrvVarWeight": [0.0, 0.5, 1.0],
    "sleepFloorPercentile": [0.06, 0.12, 0.20],
    "wakeHRMarginBPM": [10, 14, 18, 22, 26],
    "hrWakeHalfWindow": [1, 2, 3],
    "onsetSustainEpochs": [4, 6, 8],
    "minHRWakeRunEpochs": [3, 5, 7],
}


def coordinate_descent(nights_prepared, nights_truth, start, mode="blend",
                       max_passes=3, grid=None, verbose=False):
    """Greedy coordinate descent. Never worsens the objective (starts from `start`)."""
    grid = grid or SEARCH_GRID
    best = start
    best_score, _ = score_tuning(nights_prepared, nights_truth, best, mode)
    for p in range(max_passes):
        improved = False
        for param, candidates in grid.items():
            cur_val = getattr(best, param)
            local_best_val, local_best_score = cur_val, best_score
            for v in candidates:
                if v == cur_val:
                    continue
                cand = replace(best, **{param: v})
                sc, _ = score_tuning(nights_prepared, nights_truth, cand, mode)
                if sc > local_best_score + 1e-12:
                    local_best_score, local_best_val = sc, v
            if local_best_val != cur_val:
                best = replace(best, **{param: local_best_val})
                best_score = local_best_score
                improved = True
                if verbose:
                    print(f"  pass {p+1}: {param} -> {local_best_val} "
                          f"(score {best_score:.4f})")
        if not improved:
            break
    return best, best_score


# ====================================================================================
# Reporting
# ====================================================================================
def print_confusion(metrics):
    cm = metrics["confusion"]
    w = 8
    print("  confusion matrix (rows = RingConn truth, cols = our prediction):")
    header = " " * 10 + "".join(f"{c:>{w}}" for c in CLASSES) + f"{'recall':>9}"
    print(header)
    for tr in CLASSES:
        row = sum(cm[tr].values())
        rec = cm[tr][tr] / row if row else 0.0
        cells = "".join(f"{cm[tr][pc]:>{w}}" for pc in CLASSES)
        print(f"  {tr:>8}{cells}{rec:>9.2f}")
    prec_cells = "".join(
        f"{(cm[pc][pc] / sum(cm[tr][pc] for tr in CLASSES) if sum(cm[tr][pc] for tr in CLASSES) else 0.0):>{w}.2f}"
        for pc in CLASSES)
    print(f"  {'precis.':>8}{prec_cells}")


def print_metrics(title, metrics):
    print(f"\n=== {title} ===")
    print(f"  epochs scored: {metrics['total']}   "
          f"accuracy: {metrics['accuracy']:.3f}   macro-F1: {metrics['macro_f1']:.3f}")
    print_confusion(metrics)
    print("  per-class:")
    for c in CLASSES:
        pc = metrics["per_class"][c]
        print(f"    {c:>6}  P={pc['precision']:.2f} R={pc['recall']:.2f} "
              f"F1={pc['f1']:.2f}  support={pc['support']}")
    print("  night-total minutes (ours vs RingConn):")
    for c in CLASSES:
        o = metrics["pred_minutes"][c]
        g = metrics["truth_minutes"][c]
        print(f"    {c:>6}  ours={o:6.0f}m  ringconn={g:6.0f}m  diff={o-g:+6.0f}m")


def swift_initializer(t):
    """Emit a paste-ready Swift SleepStaging.Tuning(...) for the 17 mirrored fields."""
    def fmt(v):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, float):
            return f"{v:g}"
        return str(v)
    lines = ["SleepStaging.Tuning("]
    for i, name in enumerate(Tuning.SWIFT_FIELDS):
        comma = "," if i < len(Tuning.SWIFT_FIELDS) - 1 else ""
        lines.append(f"    {name}: {fmt(getattr(t, name))}{comma}")
    lines.append(")")
    return "\n".join(lines)


# ====================================================================================
# Synthetic night generator (proves the harness end-to-end with no real data)
# ====================================================================================
def synth_night(seed, hr_offset=0.0, base_dt=None):
    """Generate one plausible night: [Epoch] features + RingConn-style sleepPhases JSON.

    The hidden architecture (light/deep/rem cycles + leading/trailing awake-in-bed) drives
    physiologically shaped HR/HRV/SpO2/motion, and the SAME hidden stages become the
    RingConn ground truth — so a faithful staging model should largely recover them.
    """
    rng = random.Random(seed)
    if base_dt is None:
        base_dt = datetime(2026, 6, 21, 23, 0, 0, tzinfo=timezone.utc)
    t0 = int(base_dt.timestamp())
    base_counter = t0 - SYNC_EPOCH

    # Build a hidden per-epoch stage sequence.
    stages = []
    stages += ["awake_bed"] * 8                      # ~20 min lying awake before onset
    for _ in range(5):                               # ~5 sleep cycles
        stages += ["light"] * rng.randint(6, 9)
        stages += ["deep"] * rng.randint(5, 9)
        stages += ["light"] * rng.randint(4, 7)
        stages += ["rem"] * rng.randint(5, 9)
        if rng.random() < 0.5:
            stages += ["awake"] * rng.randint(1, 2)  # brief interior awakening
    stages += ["awake_bed"] * 6                      # lingering in bed after final wake

    base_hr = 54.0 + hr_offset
    epochs, true_labels = [], []
    for i, s in enumerate(stages):
        counter = base_counter + i * EPOCH_SECONDS
        t = counter + SYNC_EPOCH
        if s == "deep":
            hr = base_hr - 4 + rng.gauss(0, 0.6)
            hrv = 70 + rng.gauss(0, 4)
            motion = [1, 1, 1, 1, 1]
            spo2 = 97 + rng.randint(-1, 1)
            cls = "deep"
        elif s == "rem":
            hr = base_hr + 7 + rng.gauss(0, 2.5)
            hrv = 45 + rng.gauss(0, 8)
            motion = [1, 1, 1, 1, 1]
            spo2 = 96 + rng.randint(-4, 1)            # occasional REM desat
            cls = "rem"
        elif s == "light":
            hr = base_hr + 1 + rng.gauss(0, 1.6)
            hrv = 55 + rng.gauss(0, 5)
            motion = [1, 1, 1, 1, 1] if rng.random() < 0.8 else [1, 2, 1, 1, 1]
            spo2 = 97 + rng.randint(-1, 1)
            cls = "light"
        else:  # awake / awake_bed
            hr = base_hr + 16 + rng.gauss(0, 3)
            hrv = None
            burst = rng.randint(4, 30)
            motion = [1, burst, rng.randint(1, 8), 1, rng.randint(1, 5)]
            spo2 = 98
            cls = "awake"
        rr = 15 + rng.gauss(0, 0.8)
        epochs.append(Epoch(
            counter=counter, time=float(t), layout="sleepVitals",
            hr=round(max(35, min(120, hr))),
            hrv=None if hrv is None else round(max(10, hrv)),
            spo2=max(85, min(100, spo2)),
            rr=round(rr, 1),
            motion=motion,
        ))
        true_labels.append((counter, cls, s))

    # Coalesce hidden stages into RingConn sleepPhases segments (unix seconds).
    phases = []
    i = 0
    while i < len(true_labels):
        j = i
        while j + 1 < len(true_labels) and true_labels[j + 1][2] == true_labels[i][2]:
            j += 1
        st = true_labels[i][0] + SYNC_EPOCH
        en = true_labels[j][0] + SYNC_EPOCH + EPOCH_SECONDS
        s = true_labels[i][2]
        sleeptype = {
            "deep": "SLEEP_DEEP", "rem": "SLEEP_REM", "light": "SLEEP_LIGHT",
            "awake": "SLEEP_AWAKE", "awake_bed": "SLEEP_AWAKE_IN_BED",
        }[s]
        phases.append({"start": st, "end": en, "sleepType": sleeptype})
        i = j + 1
    gt_json = {"data": {"sleepPhases": phases}}
    return epochs, gt_json


def write_features_csv(path, epochs):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["utc_iso", "local", "counter", "layout",
                    "hr_bpm", "hrv_ms", "spo2_pct", "rr_brpm", "motion"])
        for e in epochs:
            iso = datetime.fromtimestamp(e.time, timezone.utc).isoformat()
            w.writerow([
                iso, iso, e.counter, e.layout,
                "" if e.hr is None else int(e.hr),
                "" if e.hrv is None else int(e.hrv),
                "" if e.spo2 is None else int(e.spo2),
                "" if e.rr is None else e.rr,
                str(e.motion),
            ])


# ====================================================================================
# Pipeline
# ====================================================================================
def run_pipeline(nights_epochs, nights_gt_segments, mode="blend", verbose=False,
                 do_variants=True):
    """load->align->fit->report over a list of nights. Returns the report dict."""
    nights_prepared = [prepare_night(eps) for eps in nights_epochs]
    nights_truth = [expand_groundtruth(eps, gt)
                    for eps, gt in zip(nights_epochs, nights_gt_segments)]

    n_prep = sum(len(p) for p in nights_prepared)
    n_truth = sum(len(t) for t in nights_truth)
    print(f"nights: {len(nights_epochs)}   prepared fragments: {n_prep}   "
          f"RingConn-labelled epochs: {n_truth}")
    if n_prep == 0:
        print("ERROR: no detectable >1 h sleep block in any night — cannot stage/fit.")
        return None
    if n_truth == 0:
        print("ERROR: RingConn ground truth covers none of our epochs — check alignment "
              "(timestamps, date range, units).")
        return None

    default = Tuning()
    base_score, base_metrics = score_tuning(nights_prepared, nights_truth, default, mode)
    print_metrics("BASELINE (Swift default Tuning)", base_metrics)

    print("\nfitting (coordinate descent over Tuning)…")
    best, best_score = coordinate_descent(nights_prepared, nights_truth, default,
                                          mode=mode, verbose=verbose)
    _, best_metrics = score_tuning(nights_prepared, nights_truth, best, mode)
    print_metrics("FITTED (single-night percentile bands)", best_metrics)

    variants = {}
    if do_variants:
        print("\n--- experiments (do the extra cues / normalizations help?) ---")
        # rrVarWeight
        rr_best, rr_score = coordinate_descent(
            nights_prepared, nights_truth, replace(best, rrVarWeight=0.5),
            mode=mode, grid={"rrVarWeight": [0.0, 0.25, 0.5, 1.0]})
        variants["rrVarWeight"] = (rr_score, rr_best.rrVarWeight)
        print(f"  rrVarWeight: best weight {rr_best.rrVarWeight} -> score {rr_score:.4f} "
              f"(vs {best_score:.4f}; {'HELPS' if rr_score > best_score + 1e-9 else 'no gain'})")

        # SpO2-dip cue
        sp_on = replace(best, spo2DipEnabled=True)
        sp_score, _ = score_tuning(nights_prepared, nights_truth, sp_on, mode)
        variants["spo2Dip"] = (sp_score, True)
        print(f"  SpO2-dip cue: score {sp_score:.4f} "
              f"(vs {best_score:.4f}; {'HELPS' if sp_score > best_score + 1e-9 else 'no gain'})")

        # Baseline-relative (multi-night pooled) bands
        bp = baseline_band_pool(nights_prepared, best)
        if bp is not None and len(nights_epochs) > 1:
            bl_score, bl_metrics = score_tuning(
                nights_prepared, nights_truth, best, mode,
                band_pool_per_night=[bp] * len(nights_prepared))
            variants["baseline"] = (bl_score, None)
            verdict = ("HELPS — worth building the Swift rolling baseline"
                       if bl_score > best_score + 1e-9
                       else "no gain — single-night percentiles suffice")
            print(f"  baseline-relative bands (pooled {len(nights_epochs)} nights): "
                  f"score {bl_score:.4f} (vs single-night {best_score:.4f}; {verdict})")
        else:
            print("  baseline-relative bands: need >1 night of captures to evaluate "
                  "(single night => baseline == that night). Capture multiple nights to test.")

    print("\n=== BEST FITTED Tuning (paste into SleepStaging.Tuning.default) ===")
    print(swift_initializer(best))
    if variants.get("rrVarWeight", (0,))[0] > best_score + 1e-9:
        print(f"\n  NOTE: rrVarWeight={variants['rrVarWeight'][1]} helped — "
              "add it to the Swift Tuning struct + _variability blend.")
    if variants.get("spo2Dip", (0,))[0] > best_score + 1e-9:
        print("  NOTE: the SpO2-dip cue helped — port it into the REM branch of SleepStaging.")

    return {
        "default": default, "default_score": base_score, "default_metrics": base_metrics,
        "best": best, "best_score": best_score, "best_metrics": best_metrics,
        "variants": variants,
    }


# ====================================================================================
# CLI
# ====================================================================================
def _parse_time(s):
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    raise argparse.ArgumentTypeError(f"bad time {s!r}; use YYYY-MM-DD or YYYY-MM-DDTHH:MM")


def run_synthetic(seed=7, nights=3, mode="blend", verbose=False):
    """Generate synthetic nights, write them to disk, reload via the real loaders, fit."""
    print("SYNTHETIC MODE — generating a plausible night + RingConn-style labels.\n")
    tmp = tempfile.mkdtemp(prefix="ringconn_synth_")
    nights_epochs, nights_gt = [], []
    for k in range(nights):
        epochs, gt_json = synth_night(seed + k, hr_offset=2.0 * k,
                                      base_dt=datetime(2026, 6, 18 + k, 23, 0, 0,
                                                       tzinfo=timezone.utc))
        csv_path = os.path.join(tmp, f"synthetic_features_{k}.csv")
        json_path = os.path.join(tmp, f"synthetic_groundtruth_{k}.json")
        write_features_csv(csv_path, epochs)
        with open(json_path, "w") as f:
            json.dump(gt_json, f)
        # Reload through the REAL load path to exercise file IO + parsing end-to-end.
        nights_epochs.append(load_features(csv_path))
        nights_gt.append(load_groundtruth(json_path))
    print(f"wrote + reloaded {nights} synthetic night(s) under {tmp}\n")

    report = run_pipeline(nights_epochs, nights_gt, mode=mode, verbose=verbose)

    # --- self-check ----------------------------------------------------------------
    print("\n--- self-check ---")
    ok = report is not None
    if ok:
        ok = report["best_metrics"]["total"] > 0
        ok = ok and report["best_score"] >= report["default_score"] - 1e-9
        ok = ok and any(sum(row.values()) for row in report["best_metrics"]["confusion"].values())
    print("SELF-CHECK PASSED" if ok else "SELF-CHECK FAILED")
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--features", help="our per-epoch CSV(s), comma-separated for multi-night")
    ap.add_argument("--groundtruth", help="RingConn /sleep JSON(s), comma-separated, paired")
    ap.add_argument("--start", type=_parse_time, help="filter epochs from this UTC time")
    ap.add_argument("--end", type=_parse_time, help="filter epochs to this UTC time")
    ap.add_argument("--objective", choices=["blend", "acc", "f1"], default="blend",
                    help="fit target: accuracy+macroF1 (blend), accuracy, or macro-F1")
    ap.add_argument("--synthetic", action="store_true",
                    help="generate synthetic data and run the full path (no real data needed)")
    ap.add_argument("--nights", type=int, default=3, help="synthetic night count")
    ap.add_argument("--seed", type=int, default=7, help="synthetic RNG seed")
    ap.add_argument("--verbose", action="store_true", help="trace coordinate-descent moves")
    args = ap.parse_args(argv)

    if args.synthetic:
        return run_synthetic(seed=args.seed, nights=args.nights,
                             mode=args.objective, verbose=args.verbose)

    if not args.features or not args.groundtruth:
        ap.error("provide --features and --groundtruth (or use --synthetic)")
    feats = args.features.split(",")
    gts = args.groundtruth.split(",")
    if len(feats) != len(gts):
        ap.error("--features and --groundtruth must list the same number of nights")
    nights_epochs = [load_features(p.strip(), start=args.start, end=args.end) for p in feats]
    nights_gt = [load_groundtruth(p.strip()) for p in gts]
    report = run_pipeline(nights_epochs, nights_gt, mode=args.objective, verbose=args.verbose)
    return 0 if report is not None else 1


if __name__ == "__main__":
    sys.exit(main())
