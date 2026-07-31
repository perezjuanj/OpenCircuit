#!/usr/bin/env python3
"""Offline backtest of OpenCircuit's headache-signals detector (#183).

*** DEV TOOL. NOTHING HERE SHIPS IN THE APP. ***
It reads files a tester chose to send us, on this machine, with no network. The app never
runs this code, never imports it, and never computes any number defined here.

WHAT THIS ANSWERS, AND WHY IT IS NOT THE SAME QUESTION THE APP ASKS
------------------------------------------------------------------
The on-device statistics answer "does this work FOR YOU?" — one person, their own labels,
and they need ~a year of that person's diary before they say anything. This harness answers
the question that decides whether the score stays in the product at all: **does the detector
have skill ACROSS people?** That resolves far sooner, because subjects add in parallel.

It is the question the published literature keeps answering NO to. The only nocturnal-wearable
migraine study (Empatica, N=10, 315 nights) beat chance for 5 of 9 participants and 4 of 5
chronic-migraine patients scored BELOW chance; user-INDEPENDENT models in that line of work
could not detect attacks at all. So the headline number here is deliberately the one that
cannot launder a subject effect:

  * every AUC is computed WITHIN a subject and then pooled over subject strata. Pooling all
    days from all people into one ranking is BANNED (`pooled_auc` never does it) — the index
    is a relative position on one person's own scale and means nothing across people, so a
    naive pool would mostly measure "who has a noisier baseline", and would look like skill.
  * the shipped weights are fitted on NOBODY, so the shipped-weight numbers are already
    leave-one-subject-out safe by construction. The `--loso` arm additionally FITS weights on
    the other subjects and scores the held-out one, which is the only honest way to ask
    "could re-weighting the nine features help, and does the improvement transfer?".

HONESTY RULES BAKED INTO THE OUTPUT
-----------------------------------
1. Every estimate prints its n and its positive count beside it. An AUC without a positive
   count is not a result, it is a decoration.
2. An AUC over fewer than `--min-positives` positives (default 5) is REFUSED, not printed.
   A number computed from 2 headaches is noise wearing a decimal point.
3. A missing input is ABSENT with a reason and is EXCLUDED from that feature's statistics —
   never substituted with 0. In this engine 0 means "measured, and ordinary".
4. Nothing here is a probability of a headache. The calibration table reports the OBSERVED
   rate per index decile in this sample; it is a description of these files, not a forecast.
5. EVERY NUMBER BELOW DEPENDS ON LABEL CAPTURE NOT BEING CONDITIONED ON THE SCORE, and that is
   a property of the APP, not of this file. Logging lives only on paths that ignore the index —
   the Siri intents, the Control Centre control, and the morning-after card prompt, which is
   shown on flagged and unflagged days alike for exactly this reason. The notification carries
   NO "did you get one?" reply button and no logging action, deliberately: such a button appears
   only on flagged days, so it would harvest labels disproportionately from the days we flagged
   and inflate every precision and AUC here BY CONSTRUCTION. The bias would be invisible in this
   output — a corrupted label series looks exactly like a good detector — and it would be
   permanent, because there is no way to un-condition a diary after the fact. If a quick-reply
   ever lands on that notification, the rows collected after it are not evidence and this harness
   cannot tell you so.
6. EVERY ROW A TESTER SENDS IS IN THE SAMPLE unless a shipped §5.1 rule excludes it. Days scored
   after the morning notification went live used to be dropped here as well — that made sense
   when the notification was gated behind proof that the detector beat chance, since those days
   could not then validate the gate that had produced them. The notification now unlocks after
   21 scored nights, so the flag latches on in a tester's third week and everything after it is
   post-unlock: keeping that exclusion would have analysed the first three weeks of each export
   and quietly called it the cross-user result. Rule 5 — not an exclusion — is what makes those
   rows honest evidence. `--exclude-post-unlock` still reproduces the old sample.

INPUTS (real ones — read from the app's own artefacts, not invented for this script)
-----------------------------------------------------------------------------------
  --rollup  rollup-backup.json  (PREFERRED)
        `RollupBackup` from `ios/OpenCircuit/App.swift` — carries `riskDays` (EVERY frozen row,
        with exact doubles and the exact `computedAt` freeze instant) AND `headaches` in one
        file. Written by `exportBeforeWipe` with a plain `JSONEncoder()`, so Dates are seconds
        since the APPLE reference date (2001-01-01), which `_coerce_time` handles.
  --diagnostics report.txt  --log log.{json,csv,txt}
        The `# Headache signals` section of the in-app Diagnostics export
        (`ios/OpenCircuit/Diagnostics/DiagnosticsReport.swift`, read 2026-07-31) plus a
        separately exported headache log. TWO LOSSES vs the rollup, both reported at load:
        the export holds only the last 14 rows, and it prints contributions rounded to 2 dp
        and no `computedAt` — so the outcome window has to be ASSUMED (`--assumed-freeze-hour`).
        Use it when a tester will send a diagnostics bundle but not a full backup.

OUTPUTS
-------
  * per-subject and pooled AUC + CI (Hanley–McNeil, and a cluster bootstrap over SUBJECTS,
    which is the CI that actually reflects "we have three testers"), plus a within-subject
    label-permutation p-value.
  * leave-one-subject-out weight fitting: does re-weighting the nine features transfer?
  * an ASCII ROC and a calibration table over within-subject percentile ranks.
  * per-feature point-biserial correlation with the label — WHICH of the nine features carries
    signal for real people. This is the artefact that retires or re-weights the 🔴 PROVISIONAL
    weights in `HeadacheSignals.Feature.weight`; until it exists those weights are literature
    priors, not measurements. Holm-corrected, because nine features tested at once will hand
    you a "finding" roughly 37 % of the time under the null.
  * alerts-per-week and precision at the SHIPPED operating point, so the copy can be checked
    against reality.

USAGE
  # Prove the harness itself works, no real data needed (plants a KNOWN effect and checks
  # that the estimators recover it, plus a null arm that must NOT show skill):
  python3 headache_backtest.py --synthetic

  # Real data:
  python3 headache_backtest.py --rollup captures/alice.json,captures/bob.json
  python3 headache_backtest.py --diagnostics captures/alice.txt --log captures/alice_log.csv

Stdlib only (this must run on the checked-in 3.9 venv with no wheels).

Mirrors, and cites: ios/OpenCircuitKit/Sources/OpenCircuitKit/Analytics/HeadacheSignals.swift,
ios/OpenCircuit/Headache/HeadacheEngine.swift, ios/OpenCircuit/Store/HeadacheStore.swift,
ios/OpenCircuit/Diagnostics/DiagnosticsReport.swift, docs/HEADACHE_SIGNALS.md §5.1/§5.2/§12
(all read 2026-07-31). Modelled on desktop/ringconn_sleep_fit.py.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import re
import statistics
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

try:                                    # 3.9+, present on the checked-in venv
    from zoneinfo import ZoneInfo
except ImportError:                      # pragma: no cover - ancient interpreter
    ZoneInfo = None


# ====================================================================================
# Constants mirrored from the Swift side. Changing one here does NOT change the app —
# it changes what this harness claims the app does, which is worse. Keep them in sync.
# ====================================================================================

# HeadacheSignals.Feature.allCases, in declaration order (the order the export prints).
FEATURES = [
    "sleepEfficiencyDrop", "arousalLetdown", "hrvDeviation", "restingHRDeviation",
    "sleepFragmentation", "sleepDurationDeviation", "scheduleShift", "skinTempDeviation",
    "perimenstrual",
]

# HeadacheSignals.Feature.weight. The eight ring-derived features sum to 1.00.
FEATURE_WEIGHT = {
    "sleepEfficiencyDrop": 0.18, "arousalLetdown": 0.18, "hrvDeviation": 0.14,
    "restingHRDeviation": 0.14, "sleepFragmentation": 0.10, "sleepDurationDeviation": 0.10,
    "scheduleShift": 0.08, "skinTempDeviation": 0.08, "perimenstrual": 0.20,
}

# HeadacheSignals.Feature.isRingDerived — a calendar lookup is not a measurement.
RING_DERIVED = {f: (f != "perimenstrual") for f in FEATURES}

# HeadacheSignals.Tuning defaults.
ONSET_Z = 1.0
SATURATION_Z = 2.5
TEMP_ONSET_C = 0.5
TEMP_SATURATION_C = 1.0
MIN_RING_FEATURES_FOR_SCORE = 4
MAX_SINGLE_FEATURE_SHARE = 0.35
MAX_CAP_PASSES = 3
ELEVATED_PERCENTILE = 0.75
FLAGGED_PERCENTILE = 0.90
MIN_DAYS_FOR_BANDING = 21
BAND_WINDOW_DAYS = 60
MIN_CONTRIBUTING_FEATURES = 3
CONTRIBUTING_THRESHOLD = 0.5

BAND_NAMES = {0: "typical", 1: "elevated", 2: "flagged"}

# docs/HEADACHE_SIGNALS.md §5.1 / `HeadacheEvaluation.Tuning` — the outcome window, pinned before
# any claim, and the lookback that makes a row UNCLASSIFIABLE because the attack had already begun.
OUTCOME_WINDOW_HOURS = 24.0
IN_PROGRESS_LOOKBACK_HOURS = 24.0

# Monte-Carlo budget + seed for THIS harness's permutation test. Fixed so a run is reproducible.
#
# These are the numbers docs/HEADACHE_SIGNALS.md §5.2 specified, but do NOT read that as "the app
# computes the same p". Two things diverge, both deliberately:
#   1. The shipped `HeadacheEvaluation` (read 2026-07-31) does not shuffle at all. Holding the
#      flagged set fixed makes the true-positive count exactly hypergeometric, so it computes the
#      upper tail in CLOSED FORM — 2000 shuffles would be a Monte-Carlo estimate, with a 1/2001
#      resolution floor, of a number available exactly.
#   2. It is a different STATISTIC. On-device: P(TP ≥ observed) for one user's flagged days.
#      Here: P(pooled within-subject AUC ≥ observed) under labels shuffled within each subject.
#      There is no closed form for the second, which is why this one is sampled.
# Both nulls are base-rate-free — that property comes from shuffling labels within a person, not
# from the sampling — so they answer compatible questions. They are not the same number.
PERMUTATION_COUNT = 2000
PERMUTATION_SEED = 0x9E3779B97F4A7C15

# Foundation's reference date (2001-01-01) → unix. `JSONEncoder()` defaults to
# `.deferredToDate`, so every Date in rollup-backup.json is a Double on this epoch.
APPLE_EPOCH_OFFSET = 978_307_200

# 1.96 — the 95 % two-sided normal quantile, spelled once.
Z95 = 1.959963984540054


# ====================================================================================
# Data model
# ====================================================================================
@dataclass
class Row:
    """One FROZEN daily row. `StoredHeadacheRisk`, as read back from either input format.

    Frozen means written once and never recomputed (`insertRiskDayIfAbsent`). That invariant is
    the only reason any number below is a prediction rather than a retro-fit, so this harness
    never modifies `index` — the re-weighting experiment produces a SEPARATE score and says so.
    """
    day: "datetime"                     # local start-of-day, tz-aware where known
    index: float
    band: int
    ring_feature_count: int
    coverage: float
    contributions: dict                 # feature -> (z|None, c|None, w)  ; c None == ABSENT
    absent: dict                        # feature -> reason string
    restaged: bool = False
    alerted: bool = False
    post_unlock: bool = False
    computed_at: "float | None" = None  # unix seconds; None on the diagnostics path
    computed_at_assumed: bool = False

    def c(self, feature):
        """Ramp contribution, or None when the feature was ABSENT. Never 0-for-missing."""
        rec = self.contributions.get(feature)
        return rec[1] if rec else None

    def present_features(self):
        return [f for f in FEATURES if self.c(f) is not None]


@dataclass
class Headache:
    """One logged label. `StoredHeadacheEntry` — the ONLY source of truth this feature has."""
    onset: float                        # unix seconds
    end: "float | None" = None
    severity: int = 0
    source: str = "user"


@dataclass
class Subject:
    """One person's frozen rows + labels. `name` appears in the output — pick a pseudonym."""
    name: str
    rows: list = field(default_factory=list)
    headaches: list = field(default_factory=list)
    tz_name: "str | None" = None
    source_kind: str = "?"
    notes: list = field(default_factory=list)   # load-time caveats, printed verbatim
    # SYNTHETIC ONLY: the effect shift planted for this person, so the self-check can compute the
    # oracle it must recover CONDITIONED ON the subjects actually drawn. Always None for real data.
    planted_shift: "float | None" = None

    def note(self, text):
        self.notes.append(text)


@dataclass
class Day:
    """One evaluable day: the frozen score and the label §5.1 credits it with."""
    subject: str
    day: "datetime"
    index: float
    band: int
    row: Row
    label: bool
    excluded: "str | None" = None       # exclusion reason, or None when it counts


# ====================================================================================
# Loaders — every one of them reads a REAL emitted format. When something cannot be
# read, the loader records a note and keeps going: one malformed row must not cost the
# whole export, exactly as the exporter itself refuses to fail a bundle over one row.
# ====================================================================================
def _coerce_time(v, subject=None):
    """A Date from either export → unix seconds.

    Numbers: `JSONEncoder()`'s `.deferredToDate` writes seconds since 2001-01-01, so a value
    below 1e9 is an APPLE-epoch date (1e9 on that epoch is 2032; a unix timestamp below 1e9 is
    2001, and no headache log predates the app). Above 1e11 is milliseconds.
    Strings: ISO-8601. A naive string is read as UTC and noted, because guessing this
    machine's timezone for a tester's data would silently move labels across day boundaries.
    """
    if v is None:
        return None
    if isinstance(v, (int, float)):
        f = float(v)
        if abs(f) > 1e11:
            return f / 1000.0
        if f < 1e9:
            return f + APPLE_EPOCH_OFFSET
        return f
    s = str(v).strip()
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    for fmt in (None, "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            dt = datetime.fromisoformat(s) if fmt is None else datetime.strptime(s, fmt)
        except ValueError:
            continue
        if dt.tzinfo is None:
            if subject is not None:
                subject.note(f"timestamp {s!r} has no timezone — read as UTC")
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    if subject is not None:
        subject.note(f"unparseable timestamp {s!r} — dropped")
    return None


def _tzinfo(name):
    if not name or ZoneInfo is None:
        return None
    try:
        return ZoneInfo(name)
    except Exception:
        return None


def _f(x, default=None):
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------- rollup-backup.json
def load_rollup(path, name=None):
    """`RollupBackup` JSON → Subject. The high-fidelity path: exact doubles, every row, and the
    real `computedAt`, so the §5.1 outcome window is the instant the score was actually frozen
    rather than an assumption about when the user woke up."""
    with open(path) as fh:
        obj = json.load(fh)
    subj = Subject(name=name or os.path.splitext(os.path.basename(path))[0],
                   source_kind="rollup-backup.json")

    for r in obj.get("riskDays") or []:
        day_ts = _coerce_time(r.get("day"), subj)
        if day_ts is None:
            continue
        contributions = _decode_contributions(str(r.get("contributionsJSON") or "{}"), subj)
        absent = _decode_absent(str(r.get("absentJSON") or "{}"))
        subj.rows.append(Row(
            day=datetime.fromtimestamp(day_ts, timezone.utc),
            index=_f(r.get("index"), 0.0),
            band=int(r.get("bandRaw") or 0),
            ring_feature_count=int(r.get("ringFeatureCount") or 0),
            coverage=_f(r.get("coverageFraction"), 0.0),
            contributions=contributions,
            absent=absent,
            restaged=bool(r.get("sleepRestaged")),
            alerted=bool(r.get("alerted")),
            post_unlock=bool(r.get("postUnlock")),
            computed_at=_coerce_time(r.get("computedAt"), subj)))

    for h in obj.get("headaches") or []:
        onset = _coerce_time(h.get("onset"), subj)
        if onset is None:
            continue
        subj.headaches.append(Headache(onset=onset,
                                       end=_coerce_time(h.get("end"), subj),
                                       severity=int(h.get("severityRaw") or 0),
                                       source=str(h.get("sourceRaw") or "user")))

    missing_ts = sum(1 for r in subj.rows if r.computed_at is None)
    if missing_ts:
        subj.note(f"{missing_ts} row(s) carry no computedAt — their outcome window is assumed")
    subj.rows.sort(key=lambda r: r.day)
    subj.headaches.sort(key=lambda h: h.onset)
    return subj


def _decode_contributions(raw, subject=None):
    """`contributionsJSON` → {feature: (z, c, w)}.

    Shape is `HeadacheContributionRecord` — `{"z":…,"c":…,"w":…}` per feature raw value, with
    `z`/`c` NULL when the feature was absent. An earlier reader in `DiagnosticsReport` assumed
    `[String: Double]` and therefore reported every feature absent on a healthy install; that is
    the exact drift this decoder exists to not repeat, so an unreadable record is DROPPED and
    noted rather than coerced into a number.
    """
    try:
        obj = json.loads(raw) if raw else {}
    except (ValueError, TypeError):
        if subject is not None:
            subject.note("a contributionsJSON column is not valid JSON — row scored as thin")
        return {}
    out = {}
    if not isinstance(obj, dict):
        return out
    for key, rec in obj.items():
        if key not in FEATURE_WEIGHT:
            continue                    # a feature this build doesn't know: decode away
        if not isinstance(rec, dict):
            continue
        out[key] = (_f(rec.get("z")), _f(rec.get("c")), _f(rec.get("w"), 0.0) or 0.0)
    return out


def _decode_absent(raw):
    try:
        obj = json.loads(raw) if raw else {}
    except (ValueError, TypeError):
        return {}
    if not isinstance(obj, dict):
        return {}
    return {k: str(v) for k, v in obj.items() if k in FEATURE_WEIGHT}


# ------------------------------------------------------------- Diagnostics export text
# The exact lines `DiagnosticsReport.headacheSection` emits (read 2026-07-31):
#   "  2026-07-30  index 42  typical  ring 6/8  coverage 0.75  [restaged alerted]"
#   "      present: restingHRDeviation=0.31 (z +1.20, w 0.14), hrvDeviation=0.10 (z -0.30, w 0.14)"
#   "      absent: skinTempDeviation=noDataThisDay, perimenstrual=notApplicable"
_ROW_RE = re.compile(
    r"^\s{1,4}(\d{4}-\d{2}-\d{2})\s+index\s+(-?[\d.]+(?:e[-+]?\d+)?)\s+(\S+)"
    r"\s+ring\s+(\d+)/(\d+)\s+coverage\s+([\d.]+)\s*(?:\[([^\]]*)\])?\s*$",
    re.IGNORECASE)
_PRESENT_RE = re.compile(
    r"([A-Za-z][A-Za-z0-9]*)=(-?[\d.]+)\s*\(z\s*([^,]+?),\s*w\s*(-?[\d.]+)\)")
_WINDOW_RE = re.compile(r"^\s*Window:.*\((\d+)\s+days,\s*([^)]+)\)")
_FROZEN_HDR_RE = re.compile(r"^Frozen daily rows \(latest (\d+) of (\d+)")
_LOG_COUNT_RE = re.compile(r"^Headache log: (\d+) entries")


def parse_diagnostics(text, name="subject", assumed_freeze_hour=9.0, tz_override=None):
    """The `# Headache signals` section of a Diagnostics bundle → Subject (rows only).

    Deliberately tolerant: the section is human-readable text, its neighbours change, and a
    tester's bundle must not be rejected because an unrelated line moved. Anything it cannot
    read becomes a NOTE, and the notes are printed — a silent parse is how a backtest ends up
    describing 3 of a tester's 14 nights and calling it a result.
    """
    subj = Subject(name=name, source_kind="Diagnostics export (# Headache signals)")
    lines = text.splitlines()

    start = None
    for i, line in enumerate(lines):
        if line.strip().startswith("# Headache signals"):
            start = i
            break
    if start is None:
        subj.note("no '# Headache signals' section found — is this a Diagnostics bundle?")
        return subj
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("# "):
            end = i
            break
    section = lines[start:end]

    tz_name = tz_override
    declared_rows = declared_total = None
    logged_entries = None
    for line in section:
        m = _WINDOW_RE.match(line)
        if m and tz_override is None:
            tz_name = m.group(2).strip()
        m = _FROZEN_HDR_RE.match(line.strip())
        if m:
            declared_rows, declared_total = int(m.group(1)), int(m.group(2))
        m = _LOG_COUNT_RE.match(line.strip())
        if m:
            logged_entries = int(m.group(1))
    subj.tz_name = tz_name
    tz = _tzinfo(tz_name) or timezone.utc
    if tz_name and _tzinfo(tz_name) is None:
        subj.note(f"timezone {tz_name!r} unknown to this machine — days read as UTC")

    i = 0
    while i < len(section):
        m = _ROW_RE.match(section[i])
        if not m:
            i += 1
            continue
        day_s, index_s, band_s, ring_s, _ring_total, cov_s, flags_s = m.groups()
        day = datetime.strptime(day_s, "%Y-%m-%d").replace(tzinfo=tz)
        band = next((k for k, v in BAND_NAMES.items() if v == band_s.lower()), None)
        if band is None:
            mm = re.match(r"band\?\((\d+)\)", band_s)
            band = int(mm.group(1)) if mm else 0
            subj.note(f"{day_s}: unmappable band {band_s!r} kept as raw {band}")
        flags = set((flags_s or "").split())

        contributions, absent = {}, {}
        for j in (i + 1, i + 2):
            if j >= len(section):
                break
            line = section[j].strip()
            if line.startswith("present:"):
                body = line[len("present:"):].strip()
                if body != "(none)":
                    for f, c, z, w in _PRESENT_RE.findall(body):
                        if f not in FEATURE_WEIGHT:
                            continue
                        zv = None if z.strip() in ("—", "-", "") else _f(z.strip())
                        contributions[f] = (zv, _f(c), _f(w, 0.0) or 0.0)
            elif line.startswith("absent:"):
                body = line[len("absent:"):].strip()
                if not body.startswith("(none"):
                    for piece in body.split(", "):
                        if "=" in piece:
                            f, reason = piece.split("=", 1)
                            if f in FEATURE_WEIGHT:
                                absent[f] = reason

        # The freeze instant is NOT exported. §5.1 credits a headache to a row only if the onset
        # falls in (computedAt, computedAt+24h], so the window has to be assumed here — stated
        # loudly rather than hidden, because the assumption moves early-morning onsets between
        # "predicted" and "already in progress".
        freeze = day + timedelta(hours=assumed_freeze_hour)
        subj.rows.append(Row(
            day=day, index=_f(index_s, 0.0), band=band,
            ring_feature_count=int(ring_s), coverage=_f(cov_s, 0.0),
            contributions=contributions, absent=absent,
            restaged=("restaged" in flags), alerted=("alerted" in flags),
            post_unlock=("postUnlock" in flags),
            computed_at=freeze.timestamp(), computed_at_assumed=True))
        i += 1

    subj.rows.sort(key=lambda r: r.day)
    if declared_rows is not None and declared_rows != len(subj.rows):
        subj.note(f"header declares {declared_rows} frozen rows, parsed {len(subj.rows)}")
    if declared_total is not None and declared_total > len(subj.rows):
        subj.note(f"the device holds {declared_total} frozen rows; this export carries only "
                  f"{len(subj.rows)} (the export window). Ask for rollup-backup.json for all of them")
    if logged_entries is not None:
        subj.note(f"the export declares {logged_entries} logged headache(s) — the log file must "
                  "account for them, or the labels are incomplete")
    subj.note("contributions in a Diagnostics export are rounded to 2 dp and the freeze instant "
              f"is assumed at {assumed_freeze_hour:g}:00 local — rollup-backup.json is exact")
    return subj


def load_diagnostics(path, name=None, assumed_freeze_hour=9.0, tz_override=None):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    return parse_diagnostics(text, name=name or os.path.splitext(os.path.basename(path))[0],
                             assumed_freeze_hour=assumed_freeze_hour, tz_override=tz_override)


# ------------------------------------------------------------------- headache log file
def load_log(path, subject=None):
    """An exported headache log → [Headache]. Accepts, in this order:

      * rollup-backup.json (uses its `headaches` array),
      * a bare JSON array of entries ({onset,end,severityRaw,sourceRaw} or {start,…}),
      * CSV with a header naming an onset column,
      * one timestamp per line.

    Four formats because the label series is the scarcest thing this feature has: a tester who
    exports the wrong shape must not be told "no labels found" and quietly dropped from the
    denominator.
    """
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()

    entries = None
    stripped = raw.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            obj = json.loads(raw)
        except ValueError:
            obj = None
        if isinstance(obj, dict):
            entries = obj.get("headaches") or obj.get("entries") or obj.get("log")
        elif isinstance(obj, list):
            entries = obj

    out = []
    if entries is not None:
        for e in entries:
            if isinstance(e, (str, int, float)):
                ts = _coerce_time(e, subject)
                if ts is not None:
                    out.append(Headache(onset=ts))
                continue
            onset = _coerce_time(e.get("onset", e.get("start", e.get("date"))), subject)
            if onset is None:
                continue
            out.append(Headache(onset=onset,
                                end=_coerce_time(e.get("end"), subject),
                                severity=int(e.get("severityRaw", e.get("severity", 0)) or 0),
                                source=str(e.get("sourceRaw", e.get("source", "user")))))
    else:
        rows = [ln for ln in raw.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
        header = rows[0].lower() if rows else ""
        if "," in header and any(k in header for k in ("onset", "start", "date", "time")):
            for rec in csv.DictReader(rows):
                keys = {k.lower().strip(): v for k, v in rec.items() if k}
                onset = None
                for k in ("onset", "start", "date", "datetime", "time"):
                    if keys.get(k):
                        onset = _coerce_time(keys[k], subject)
                        break
                if onset is None:
                    continue
                out.append(Headache(onset=onset,
                                    end=_coerce_time(keys.get("end"), subject),
                                    severity=int(_f(keys.get("severity"), 0) or 0),
                                    source=str(keys.get("source") or "user")))
        else:
            for ln in rows:
                ts = _coerce_time(ln.strip(), subject)
                if ts is not None:
                    out.append(Headache(onset=ts))

    out.sort(key=lambda h: h.onset)
    return out


# ====================================================================================
# Labelling — docs/HEADACHE_SIGNALS.md §5.1, reproduced exactly. Changing this
# definition after seeing data is a change-control event, not a tweak.
# ====================================================================================
def observation_end(subject):
    """The instant after which this export tells us NOTHING.

    A file-based backtest has no `now`, and assuming one is how you get a fake result: every row
    whose 24 h outcome window runs past the end of the file would be labelled negative simply
    because the file stopped, which drags the measured base rate and the AUC down. So the end of
    observation is inferred as the latest instant any artefact in this subject's files proves we
    were still watching.
    """
    stamps = [r.computed_at for r in subject.rows if r.computed_at is not None]
    stamps += [h.onset for h in subject.headaches]
    stamps += [h.end for h in subject.headaches if h.end is not None]
    return max(stamps) if stamps else None


def label_days(subject, horizon_hours=OUTCOME_WINDOW_HOURS,
               lookback_hours=IN_PROGRESS_LOOKBACK_HOURS, obs_end=None,
               exclude_spanning=False, include_restaged=False, exclude_post_unlock=False):
    """Turn frozen rows + logged onsets into labelled days.

    THE DEFINITION OF RECORD IS THE SHIPPED ONE. This mirrors
    `HeadacheEvaluation.metrics` (OpenCircuitKit, read 2026-07-31) rule for rule, so the harness
    and the on-device panel cannot report different precision on the same data — a divergence
    here would be indistinguishable from a real disagreement between testers:

      positive   onset ∈ (computedAt, computedAt + outcomeWindowHours]
      excluded   1. sleepRestaged        — scored on staging the app no longer believes
                 2. inProgress           — onset ∈ [computedAt − lookback, computedAt]
                 3. unresolved           — computedAt + outcome runs past the end of observation

    Order matters because each row is counted at most once; it is the Kit's order.

    POST-UNLOCK ROWS ARE KEPT, and that is a deliberate reversal. An earlier design gated the
    morning notification behind proof that the detector beat chance, so a day the gate had
    already influenced could not be used to validate it and every `postUnlock` row was dropped
    here by default. That gate no longer exists: the notification unlocks after
    `MIN_DAYS_FOR_BANDING` (21) scored nights and the per-user statistics became an auto-retire
    monitor. Since the flag is latched on at row ~22 and never comes back off, dropping those
    rows now discards all but the first three weeks of every export — i.e. almost the entire
    sample, in the one analysis that decides whether the score stays in the product. What kept
    the labels usable was never this exclusion: it is that logging lives only on paths that
    ignore the index and the notification carries no reply button (module docstring, rule 5).

    `exclude_post_unlock` keeps the old behaviour reachable — for data collected under the old
    gated design, or as a sensitivity check that the pre- and post-unlock halves agree. Expect
    it to REFUSE most estimates: 21 rows minus the exclusions above is not an AUC.

    The lookback form of the in-progress rule (rather than "active until its logged end") is the
    Kit's deliberate choice: an attack older than the outcome horizon is a different episode, and
    an unbounded reading would let one mis-entered date delete a month of evidence. The
    alternative reading — a logged headache SPANNING the freeze instant — is available as
    `exclude_spanning` for a sensitivity check, and is OFF by default precisely because it is a
    divergence from what the app computes.
    """
    onsets = subject.headaches
    out = []
    for row in subject.rows:
        if row.computed_at is None:
            out.append(Day(subject.name, row.day, row.index, row.band, row, False,
                           excluded="noFreezeInstant"))
            continue
        t0 = row.computed_at
        t1 = t0 + horizon_hours * 3600.0

        in_progress = any(t0 - lookback_hours * 3600.0 <= h.onset <= t0 for h in onsets)
        if exclude_spanning:
            in_progress = in_progress or any(
                h.onset <= t0 < h.end for h in onsets if h.end is not None)
        label = any(t0 < h.onset <= t1 for h in onsets)

        excluded = None
        if row.restaged and not include_restaged:
            excluded = "restaged"
        elif in_progress:
            excluded = "inProgress"
        elif obs_end is not None and t1 > obs_end:
            excluded = "unresolved"
        elif row.post_unlock and exclude_post_unlock:
            excluded = "postUnlock"
        out.append(Day(subject.name, row.day, row.index, row.band, row, label, excluded))
    return out


def evaluable(days):
    return [d for d in days if d.excluded is None]


# ====================================================================================
# Statistics. Every function returns its n and positive count with the estimate, so a
# caller physically cannot print one without the other.
# ====================================================================================
@dataclass
class AUCResult:
    auc: float
    n_pos: int
    n_neg: int
    ci_low: float
    ci_high: float

    @property
    def pairs(self):
        return self.n_pos * self.n_neg

    @property
    def usable(self):
        return self.n_pos > 0 and self.n_neg > 0


def auc_mann_whitney(scores, labels):
    """AUC = U/(nPos·nNeg) with ties credited 0.5 — the §5.2 definition, via midranks."""
    pos = [s for s, y in zip(scores, labels) if y]
    neg = [s for s, y in zip(scores, labels) if not y]
    n_pos, n_neg = len(pos), len(neg)
    if n_pos == 0 or n_neg == 0:
        return AUCResult(float("nan"), n_pos, n_neg, float("nan"), float("nan"))

    order = sorted(range(len(scores)), key=lambda i: scores[i])
    ranks = [0.0] * len(scores)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and scores[order[j + 1]] == scores[order[i]]:
            j += 1
        midrank = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[order[k]] = midrank
        i = j + 1
    rank_sum_pos = sum(r for r, y in zip(ranks, labels) if y)
    u = rank_sum_pos - n_pos * (n_pos + 1) / 2.0
    a = u / (n_pos * n_neg)
    lo, hi = hanley_mcneil_ci(a, n_pos, n_neg)
    return AUCResult(a, n_pos, n_neg, lo, hi)


def hanley_mcneil_ci(a, n_pos, n_neg):
    """§5.2's CI, formula-for-formula, so this harness and the on-device `Metrics` agree."""
    if n_pos < 1 or n_neg < 1 or math.isnan(a):
        return float("nan"), float("nan")
    q1 = a / (2 - a) if (2 - a) != 0 else 0.0
    q2 = 2 * a * a / (1 + a) if (1 + a) != 0 else 0.0
    var = (a * (1 - a) + (n_pos - 1) * (q1 - a * a) + (n_neg - 1) * (q2 - a * a)) / (n_pos * n_neg)
    se = math.sqrt(max(var, 0.0))
    return max(0.0, a - Z95 * se), min(1.0, a + Z95 * se)


def wilson_ci(k, n):
    """Wilson score interval — the honest one at the small k this feature lives at."""
    if n == 0:
        return float("nan"), float("nan")
    p = k / n
    d = 1 + Z95 ** 2 / n
    centre = (p + Z95 ** 2 / (2 * n)) / d
    half = Z95 * math.sqrt(p * (1 - p) / n + Z95 ** 2 / (4 * n * n)) / d
    return max(0.0, centre - half), min(1.0, centre + half)


def pooled_auc(per_subject):
    """Pair-weighted mean of WITHIN-subject AUCs (subject-stratified Mann-Whitney).

    NEVER a pool of raw scores across people. The index is explicitly "a relative position on
    one person's own scale ... means nothing across people" (HeadacheSignals.swift header), so
    a naive pooled ranking would rank one person's quiet night against another's, and any
    difference in baseline noisiness between subjects would read as skill. Stratifying is not a
    refinement here, it is the difference between a real number and an artefact.
    """
    num = den = 0.0
    n_pos = n_neg = 0
    used = []
    for name, res in per_subject:
        if not res.usable:
            continue
        w = float(res.pairs)
        num += w * res.auc
        den += w
        n_pos += res.n_pos
        n_neg += res.n_neg
        used.append(name)
    if den == 0:
        return AUCResult(float("nan"), n_pos, n_neg, float("nan"), float("nan")), used
    a = num / den
    lo, hi = hanley_mcneil_ci(a, n_pos, n_neg)
    return AUCResult(a, n_pos, n_neg, lo, hi), used


def _subject_score_label(subject_days):
    return ([d.index for d in subject_days], [d.label for d in subject_days])


def permutation_p_pooled(subject_days_map, observed, permutations=PERMUTATION_COUNT,
                         seed=PERMUTATION_SEED):
    """One-sided p for "pooled AUC > 0.5", shuffling labels WITHIN each subject.

    Within-subject shuffling preserves each person's base rate and each person's score
    distribution, so the null is "this person's headaches fall on days unrelated to their own
    index" — which is exactly the claim being tested, and is base-rate-free by construction
    (that is what makes it usable for a chronic sufferer whose base rate is 0.5).
    """
    rng = random.Random(seed)
    prepared = []
    for name, days in subject_days_map:
        scores, labels = _subject_score_label(days)
        if sum(labels) == 0 or sum(labels) == len(labels):
            continue
        prepared.append((name, scores, list(labels)))
    if not prepared or math.isnan(observed):
        return float("nan"), 0
    hits = 0
    for _ in range(permutations):
        per = []
        for name, scores, labels in prepared:
            shuffled = list(labels)
            rng.shuffle(shuffled)
            per.append((name, auc_mann_whitney(scores, shuffled)))
        a, _ = pooled_auc(per)
        if not math.isnan(a.auc) and a.auc >= observed:
            hits += 1
    return (1 + hits) / (1 + permutations), permutations


def cluster_bootstrap_ci(subject_days_map, resamples=2000, seed=PERMUTATION_SEED,
                         resample_days=True):
    """TWO-STAGE percentile CI: resample SUBJECTS with replacement, then resample each drawn
    subject's DAYS with replacement.

    The day-level (Hanley–McNeil) CI answers "how sure are we about these particular people?",
    which is not the question — the claim is about people in general, so between-person variation
    has to be inside the interval.

    The second stage is not a refinement, it is a correctness fix. A ONE-STAGE cluster bootstrap
    (draw subjects, reuse each one's days verbatim) captures ONLY between-subject variance and
    drops every bit of within-subject sampling error. Measured on this harness's own 4-subject
    synthetic set, that produced [0.727, 0.802] — WIDTH 0.075 against Hanley–McNeil's 0.125. An
    interval sold as "the wider, more honest one" that is in fact the NARROWEST number on the page
    is worse than no interval: it hands a reader who is trying to be careful the tightest claim
    available. Resampling days inside each drawn subject restores the missing component.

    `resample_days=False` selects the one-stage form. It exists ONLY so the self-check can show
    the two forms differ and thereby detect a silent revert of stage 2; it is never the reported
    interval. Note the guarantee is that two-stage is wider than ONE-STAGE — not that it is wider
    than Hanley–McNeil, which is a different estimator under different assumptions and can be the
    wider of the two when the AUC is high and the subjects happen to agree closely.

    With very few subjects a percentile CI over clusters still under-covers — the caller prints
    that caveat, because no amount of resampling manufactures people we do not have.
    """
    names = [n for n, _ in subject_days_map]
    if len(names) < 2:
        return float("nan"), float("nan"), 0
    lookup = dict(subject_days_map)
    rng = random.Random(seed)
    draws = []
    for _ in range(resamples):
        picked = [rng.choice(names) for _ in names]
        per = []
        for i, nm in enumerate(picked):
            days = lookup[nm]
            # Stage 2. A resampled day list can land all-positive or all-negative, which is not an
            # AUC; `pooled_auc` already drops those strata, so the draw is simply thinner.
            boot = ([days[rng.randrange(len(days))] for _ in range(len(days))]
                    if resample_days else days)
            scores, labels = _subject_score_label(boot)
            per.append((f"{nm}#{i}", auc_mann_whitney(scores, labels)))
        a, _ = pooled_auc(per)
        if not math.isnan(a.auc):
            draws.append(a.auc)
    if len(draws) < 20:
        return float("nan"), float("nan"), len(draws)
    draws.sort()
    lo = draws[int(0.025 * (len(draws) - 1))]
    hi = draws[int(0.975 * (len(draws) - 1))]
    return lo, hi, len(draws)


def pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return float("nan")
    mx, my = sum(xs) / n, sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx <= 0 or syy <= 0:
        return float("nan")
    return sxy / math.sqrt(sxx * syy)


def fisher_p(r, n):
    """Two-sided p via Fisher's z. Normal-approximate, stdlib-only, and adequate at the n this
    feature reaches; it is never the basis of a decision on its own — Holm below is."""
    if n < 5 or math.isnan(r) or abs(r) >= 1:
        return float("nan")
    z = math.atanh(r) * math.sqrt(n - 3)
    return 2 * (1 - statistics.NormalDist().cdf(abs(z)))


def fisher_ci(r, n):
    if n < 5 or math.isnan(r) or abs(r) >= 1:
        return float("nan"), float("nan")
    se = 1 / math.sqrt(n - 3)
    z = math.atanh(r)
    return math.tanh(z - Z95 * se), math.tanh(z + Z95 * se)


def holm(pvalues):
    """Holm–Bonferroni adjusted p-values, in the input order.

    Nine features tested at once gives ~37 % chance of at least one p<0.05 under the null, and
    §6.5 already records that an uncorrected per-feature flip is a fatal flaw in this design.
    An uncorrected table would be read as "we found the signal feature" on pure noise.
    """
    indexed = [(p, i) for i, p in enumerate(pvalues) if not math.isnan(p)]
    indexed.sort()
    m = len(indexed)
    out = [float("nan")] * len(pvalues)
    running = 0.0
    for rank, (p, i) in enumerate(indexed):
        adj = min(1.0, (m - rank) * p)
        running = max(running, adj)
        out[i] = running
    return out


def percentile_linear(sorted_values, p):
    """Mirrors `HeadacheSignals.percentile` — linear interpolation over a SORTED array."""
    if not sorted_values:
        return float("inf")
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = p * (len(sorted_values) - 1)
    lo = int(math.floor(rank))
    hi = min(lo + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (rank - lo) * (sorted_values[hi] - sorted_values[lo])


def percentile_ranks(values):
    """Within-subject percentile rank in [0,1], ties shared. The ONLY score that is comparable
    across people here, because the shipped operating point is itself a per-user percentile."""
    n = len(values)
    if n <= 1:
        return [0.5] * n
    out = []
    for v in values:
        less = sum(1 for u in values if u < v)
        equal = sum(1 for u in values if u == v)
        out.append((less + 0.5 * (equal - 1)) / (n - 1))
    return out


# ====================================================================================
# Re-derivation of the shipped arithmetic — used for (a) a parse self-check on real
# data and (b) the LOSO weight experiment. It never overwrites a frozen index.
# ====================================================================================
def apply_single_feature_cap(weights):
    """Port of `HeadacheSignals.applySingleFeatureCap` (iterative, 3 passes)."""
    w = dict(weights)
    for _ in range(MAX_CAP_PASSES):
        total = sum(w.values())
        if total <= 0:
            return w
        top = max(w, key=lambda k: w[k])
        if w[top] / total <= MAX_SINGLE_FEATURE_SHARE:
            return w
        others = total - w[top]
        share = MAX_SINGLE_FEATURE_SHARE
        w[top] = share * others / max(1 - share, 1e-300)
    return w


def recompute_index(row, weights=None, use_frozen_weights=False):
    """Re-derive the 0–100 index from a row's frozen contributions.

    `use_frozen_weights=True` uses each row's own recorded `w` (post-quality-multiplier,
    post-cap), so it should reproduce the frozen index almost exactly — which makes it a
    PARSE CHECK: a mismatch on real data means this harness is reading the export wrong, not
    that the app is wrong. With a supplied weight vector it is the re-weighting experiment,
    and is deliberately a different number with a different name.
    """
    present = {f: rec for f, rec in row.contributions.items() if rec[1] is not None}
    if not present:
        return None
    if use_frozen_weights:
        w = {f: rec[2] for f, rec in present.items()}
    else:
        base = weights or FEATURE_WEIGHT
        w = apply_single_feature_cap({f: base.get(f, 0.0) for f in present})
    total = sum(w.values())
    if total <= 0:
        return None
    return 100.0 * sum(w[f] * present[f][1] for f in present) / total


def recompute_bands(rows):
    """Replay `HeadacheSignals.band` over the rows in freeze order.

    Two uses: it checks the parse against the frozen `bandRaw` (they must agree), and it lets
    the shipped operating point be evaluated on a rollup where the user never unlocked, since
    the band is what "the top 10 % of your own days" actually means in code — including the
    floor at index 0 and the ≥3-contributing-features rule that stops one input reaching the
    top band on its own.
    """
    out = []
    prior = []
    for row in rows:
        band = 0
        window = prior[-BAND_WINDOW_DAYS:] if len(prior) > BAND_WINDOW_DAYS else list(prior)
        if len(window) >= MIN_DAYS_FOR_BANDING and row.index > 0:
            contributions = [c for c in (row.c(f) for f in FEATURES) if c is not None]
            # Swift applies both contribution rules only when it HAS contributions: an empty list
            # means "banding was asked without them", not "nothing contributed", so it neither
            # vetoes on `no positive contribution` nor demands the 3-feature minimum. Mirrored
            # rather than simplified, because a Diagnostics row whose `present:` line could not be
            # parsed lands in exactly that state and would otherwise be reported as a band
            # disagreement — i.e. as an app bug that isn't one.
            has_contributions = bool(contributions)
            vetoed = has_contributions and not any(c > 0 for c in contributions)
            if not vetoed:
                s = sorted(float(v) for v in window)
                value = float(row.index)
                if value >= percentile_linear(s, FLAGGED_PERCENTILE):
                    contributing = sum(1 for c in contributions if c >= CONTRIBUTING_THRESHOLD)
                    band = 2 if (not has_contributions
                                 or contributing >= MIN_CONTRIBUTING_FEATURES) else 1
                elif value >= percentile_linear(s, ELEVATED_PERCENTILE):
                    band = 1
        out.append(band)
        prior.append(row.index)
    return out


# ====================================================================================
# Evaluation arms
# ====================================================================================
def subject_auc(days):
    scores, labels = _subject_score_label(days)
    return auc_mann_whitney(scores, labels)


def reweighted_auc(days, weights):
    scores, labels, kept = [], [], 0
    for d in days:
        s = recompute_index(d.row, weights=weights)
        if s is None:
            continue                    # a row with nothing present cannot be re-weighted
        scores.append(s)
        labels.append(d.label)
        kept += 1
    if kept == 0:
        return AUCResult(float("nan"), 0, 0, float("nan"), float("nan"))
    return auc_mann_whitney(scores, labels)


WEIGHT_MULTIPLIERS = [0.0, 0.5, 1.0, 2.0]


def fit_weights(train, passes=2):
    """Coordinate ascent over per-feature weight multipliers, maximising pooled TRAIN AUC.

    Deliberately coarse (4 multipliers, 2 passes). A fine search over 9 weights on a handful of
    subjects would fit the training subjects' noise and make the held-out number look worse for
    the wrong reason; the question being asked is whether a re-weighting TRANSFERS at all, not
    what the optimal weights are.
    """
    weights = dict(FEATURE_WEIGHT)

    def score(w):
        per = [(name, reweighted_auc(days, w)) for name, days in train]
        return pooled_auc(per)[0].auc

    best = score(weights)
    if math.isnan(best):
        return weights, best
    for _ in range(passes):
        improved = False
        for f in FEATURES:
            base = FEATURE_WEIGHT[f]
            current = weights[f]
            best_val = current
            for mult in WEIGHT_MULTIPLIERS:
                cand = dict(weights)
                cand[f] = base * mult
                if sum(cand.values()) <= 0:
                    continue
                s = score(cand)
                if not math.isnan(s) and s > best + 1e-12:
                    best, best_val = s, cand[f]
            if best_val != current:
                weights[f] = best_val
                improved = True
        if not improved:
            break
    return weights, best


def loso(subject_days_map, min_subjects=3):
    """Leave-one-subject-out: fit weights on the others, score the held-out subject.

    The point of the whole harness. A model tuned on a subject and evaluated on that same
    subject tells you nothing, and this literature has repeatedly failed to generalise across
    people, so a within-subject gain that does not survive this is not a result.
    """
    if len(subject_days_map) < min_subjects:
        return None
    folds = []
    for i, (name, days) in enumerate(subject_days_map):
        train = [p for j, p in enumerate(subject_days_map) if j != i]
        weights, train_auc = fit_weights(train)
        test = reweighted_auc(days, weights)
        shipped = subject_auc(days)
        folds.append({"subject": name, "weights": weights, "train_auc": train_auc,
                      "test": test, "shipped": shipped})
    return folds


# ====================================================================================
# Reporting
# ====================================================================================
def fmt_auc(res, min_pos, min_neg):
    """The refusal lives here so no caller can print a number it has not earned."""
    if not res.usable:
        return f"REFUSED — no {'positives' if res.n_pos == 0 else 'negatives'} " \
               f"(n+={res.n_pos}, n−={res.n_neg})"
    if res.n_pos < min_pos or res.n_neg < min_neg:
        return (f"REFUSED — n+={res.n_pos} (min {min_pos}), n−={res.n_neg} (min {min_neg}); "
                "an AUC on this few labels is noise")
    return (f"AUC {res.auc:.3f}  95% CI [{res.ci_low:.3f}, {res.ci_high:.3f}]  "
            f"n+={res.n_pos} n−={res.n_neg}")


def print_header():
    print("=" * 86)
    print("headache_backtest — DEV TOOL, never ships in the app. #183 Tier-5 cross-user check.")
    print("Every estimate prints its n and positive count. Nothing here is a probability of a")
    print("headache; the label rule is docs/HEADACHE_SIGNALS.md §5.1 (onset in (freeze, +24h]).")
    print("=" * 86)


def print_subject_summary(subjects, labelled, obs_ends):
    print("\n=== SUBJECTS ===")
    for subj in subjects:
        days = labelled[subj.name]
        ev = evaluable(days)
        pos = sum(1 for d in ev if d.label)
        excl = {}
        for d in days:
            if d.excluded:
                excl[d.excluded] = excl.get(d.excluded, 0) + 1
        span = ""
        if subj.rows:
            span = f"  {subj.rows[0].day.date()} → {subj.rows[-1].day.date()}"
        open_entries = sum(1 for h in subj.headaches if h.end is None)
        print(f"  {subj.name}: {len(subj.rows)} frozen row(s), {len(subj.headaches)} logged "
              f"headache(s){span}")
        print(f"      evaluable {len(ev)} day(s), {pos} positive"
              + ("  ·  excluded: " + ", ".join(f"{k} {v}" for k, v in sorted(excl.items()))
                 if excl else "  ·  no exclusions")
              + f"  ·  source: {subj.source_kind}")
        end = obs_ends.get(subj.name)
        if end is not None:
            print("      observation ends "
                  f"{datetime.fromtimestamp(end, timezone.utc).strftime('%Y-%m-%d %H:%M')}Z — rows "
                  "whose 24 h outcome window runs past it are 'unresolved', never counted negative")
        if open_entries:
            # Not used by the default rule (the Kit's in-progress test is an onset lookback), but a
            # log full of unresolved entries is worth seeing: it is the signal that `--exclude-
            # spanning` would change the answer, and that the diary is being half-filled.
            print(f"      {open_entries} of {len(subj.headaches)} entries have no logged end")
        for note in subj.notes:
            print(f"      note: {note}")
    # `StoredHeadacheRisk.day` is a LOCAL start-of-day on the tester's device and the backup does
    # not record which timezone that was. It is only ever a display key here — every label decision
    # uses the absolute `computedAt` — but the printed dates can sit one day off the tester's
    # calendar, and a reader comparing this output to a screenshot deserves to know.
    if any(s.source_kind.startswith("rollup") for s in subjects):
        print("  (rollup dates are printed in UTC; the device's own local day may differ by one —")
        print("   labels are decided on the absolute freeze instant, so this is display only)")


def print_parse_check(subjects):
    """Does our reading of the frozen columns reproduce the frozen index?

    On real data this is the first thing to look at: if the frozen-weight reproduction is not
    ≈0, this harness is mis-reading the export and every number below it is void.
    """
    print("\n=== PARSE / RE-DERIVATION CHECK ===")
    print("  frozen-weight MAE re-derives the stored index from the stored weights, so it should")
    print("  be ≤0.5 — the residual is the engine's own rounding to an integer index, not error.")
    print("  shipped-weight MAE is EXPECTED to be larger: the frozen w carries the truncated-")
    print("  sleep quality multiplier and the 35 % single-feature cap, which shipped w does not.")
    for subj in subjects:
        rows = [r for r in subj.rows if r.present_features()]
        if not rows:
            print(f"  {subj.name}: {len(subj.rows)} row(s), none with a present feature — "
                  "nothing to re-derive")
            continue
        d_frozen, d_shipped = [], []
        for r in rows:
            a = recompute_index(r, use_frozen_weights=True)
            b = recompute_index(r)
            if a is not None:
                d_frozen.append(abs(a - r.index))
            if b is not None:
                d_shipped.append(abs(b - r.index))
        band_repro = recompute_bands(subj.rows)
        agree = sum(1 for r, b in zip(subj.rows, band_repro) if r.band == b)
        # A row can legitimately yield no re-derivation (every present feature carries weight 0 in
        # a malformed column), and `statistics.mean([])` raises — which would cost the operator the
        # whole report over one bad row, the opposite of what a diagnostics reader should do.
        mae_frozen = statistics.mean(d_frozen) if d_frozen else float("nan")
        mae_shipped = statistics.mean(d_shipped) if d_shipped else float("nan")
        print(f"  {subj.name}: n={len(rows)}  frozen-weight MAE {mae_frozen:.3f}"
              f"  ·  shipped-weight MAE {mae_shipped:.3f}"
              f"  ·  band reproduced {agree}/{len(subj.rows)}")
        if not math.isnan(mae_frozen) and mae_frozen > 1.0:
            print("      WARNING: the stored index does not follow from the stored contributions —"
                  " suspect the parse or a build mismatch before believing anything below")


def print_auc_section(subject_days_map, args):
    print("\n=== USER-INDEPENDENT AUC (shipped weights — fitted on nobody) ===")
    print("  Within-subject ranking, pooled over subject strata. Days from different people are")
    print("  never ranked against each other; the index is not comparable across people.")
    per = []
    for name, days in subject_days_map:
        res = subject_auc(days)
        per.append((name, res))
        print(f"  {name:>16}: {fmt_auc(res, args.min_positives, args.min_negatives)}")
    pooled, used = pooled_auc(per)
    print(f"  {'POOLED':>16}: {fmt_auc(pooled, args.min_positives, args.min_negatives)}"
          f"  (subjects contributing: {len(used)})")
    if pooled.usable and pooled.n_pos >= args.min_positives:
        lo, hi, draws = cluster_bootstrap_ci(subject_days_map, resamples=args.bootstrap)
        if not math.isnan(lo):
            n_subj = len(subject_days_map)
            print(f"  {'':>16}  two-stage cluster bootstrap 95% CI [{lo:.3f}, {hi:.3f}] "
                  f"({draws} resamples over {n_subj} subject(s))")
            print(f"  {'':>16}  Resamples people AND their days, so it carries between-person")
            print(f"  {'':>16}  variation that the day-level CI above cannot see. Quote THIS one")
            print(f"  {'':>16}  for a claim about people; the CI above is about these people only.")
            # A percentile CI over a handful of clusters under-covers no matter how many resamples
            # are drawn — the resampling can only reuse the subjects present. Saying so is the
            # difference between a wide honest interval and a narrow fake one.
            if n_subj < 5:
                print(f"  {'':>16}  ⚠ {n_subj} subject(s): too few clusters for this interval to")
                print(f"  {'':>16}  have its nominal coverage. Read it as 'we cannot yet put a CI")
                print(f"  {'':>16}  on the population', not as a population CI.")
        else:
            print(f"  {'':>16}  subject-level bootstrap: needs ≥2 subjects")
        p, perms = permutation_p_pooled(subject_days_map, pooled.auc,
                                        permutations=args.permutations)
        if not math.isnan(p):
            print(f"  {'':>16}  permutation p = {p:.4f} ({perms} within-subject label shuffles, "
                  f"seed 0x{PERMUTATION_SEED:X})")
    else:
        print("  (pooled AUC withheld — see the refusal above)")
    return pooled


def print_loso_section(subject_days_map, pooled_shipped, args):
    print("\n=== LEAVE-ONE-SUBJECT-OUT (weights fitted on the OTHER subjects) ===")
    if args.no_loso:
        print("  skipped (--no-loso)")
        return
    folds = loso(subject_days_map)
    if folds is None:
        print(f"  skipped — needs ≥3 subjects, have {len(subject_days_map)}. With 2 subjects the")
        print("  'training set' is one person and the held-out number measures that person, not")
        print("  the population.")
        return
    per_test = []
    for f in folds:
        per_test.append((f["subject"], f["test"]))
        changed = [k for k in FEATURES if abs(f["weights"][k] - FEATURE_WEIGHT[k]) > 1e-12]
        print(f"  hold out {f['subject']:>14}: train AUC {f['train_auc']:.3f}  →  "
              f"test {fmt_auc(f['test'], args.min_positives, args.min_negatives)}")
        print(f"  {'':>25}re-weighted: "
              + (", ".join(f"{k}×{f['weights'][k] / FEATURE_WEIGHT[k]:g}" for k in changed)
                 if changed else "(no change from shipped)"))
        # A fitted vector that zeroes every feature a given night measured leaves that night with
        # no score at all, so the held-out n can be smaller than the shipped-weight n. Say so
        # rather than letting two differently-sized samples be compared silently.
        if f["test"].usable and f["shipped"].usable and f["test"].n_pos != f["shipped"].n_pos:
            print(f"  {'':>25}  n+ {f['shipped'].n_pos} → {f['test'].n_pos}: the fitted weights "
                  "score nothing on some nights (every feature they measured got weight 0)")
    pooled_fit, _ = pooled_auc(per_test)
    print(f"  {'POOLED LOSO':>25}: {fmt_auc(pooled_fit, args.min_positives, args.min_negatives)}")
    if pooled_fit.usable and pooled_shipped.usable:
        delta = pooled_fit.auc - pooled_shipped.auc
        print(f"  {'':>25}  vs shipped weights: {delta:+.3f}")
        print(f"  {'':>25}  A gain smaller than the CI width is not a gain. Re-weighting is only")
        print(f"  {'':>25}  worth shipping if it survives here AND on a further held-out subject.")
    # Which features the fit consistently kept or killed is more informative than any single
    # fold: a weight that is dropped in every fold is dead weight for these people.
    print("  per-feature multiplier across folds (1 = shipped):")
    for k in FEATURES:
        mults = [f["weights"][k] / FEATURE_WEIGHT[k] for f in folds]
        print(f"    {k:<24} " + " ".join(f"{m:>4g}" for m in mults)
              + ("   ← dropped in every fold" if all(m == 0 for m in mults) else ""))


def feature_stats(subject_days_map, args):
    """Point-biserial r between each feature's ramp contribution and the label, per feature.

    Computed WITHIN each subject and combined with Fisher's z, NOT by pooling contributions
    across people — the same stratification argument as the AUC, and here it also protects
    against Simpson's paradox, since two people's contribution distributions are not on one
    scale. Days where the feature was ABSENT are dropped from that feature's n rather than
    scored 0, which is why `n` varies row to row and is printed.

    One implementation, used by both the printed table and the self-check: two copies of a
    statistic is two chances for the number in the report to stop being the number that was
    tested.
    """
    out = []
    for f in FEATURES:
        zs, weights_n, n_total, n_pos_total, subj_used = [], [], 0, 0, 0
        for _name, days in subject_days_map:
            xs, ys = [], []
            for d in days:
                c = d.row.c(f)
                if c is None:
                    continue
                xs.append(c)
                ys.append(1.0 if d.label else 0.0)
            n_total += len(xs)
            n_pos_total += int(sum(ys))
            # A subject contributes to a feature only with enough labelled present days for the
            # correlation to mean anything on their own data.
            if len(xs) < max(10, args.min_positives * 2) or sum(ys) < args.min_positives:
                continue
            r = pearson(xs, ys)
            if math.isnan(r) or abs(r) >= 1:
                continue
            subj_used += 1
            zs.append(math.atanh(r))
            weights_n.append(len(xs) - 3)
        if subj_used == 0:
            out.append({"feature": f, "subjects": 0, "n": n_total, "n_pos": n_pos_total,
                        "r": float("nan"), "ci": (float("nan"), float("nan")),
                        "p": float("nan")})
            continue
        r_pooled = math.tanh(sum(z * w for z, w in zip(zs, weights_n)) / sum(weights_n))
        n_eff = sum(weights_n) + 3
        out.append({"feature": f, "subjects": subj_used, "n": n_total, "n_pos": n_pos_total,
                    "r": r_pooled, "ci": fisher_ci(r_pooled, n_eff),
                    "p": fisher_p(r_pooled, n_eff)})
    return out


def print_feature_table(stats):
    print("\n=== PER-FEATURE POINT-BISERIAL WITH THE LABEL ===")
    print("  This is the table that retires or re-weights the 🔴 PROVISIONAL weights in")
    print("  HeadacheSignals.Feature.weight. Absent days are EXCLUDED, never scored 0.")
    print(f"  {'feature':<24}{'w':>6}{'subj':>6}{'n':>7}{'n+':>5}{'r':>8}"
          f"{'95% CI':>18}{'p':>9}{'p(Holm)':>10}")
    adjusted = holm([s["p"] for s in stats])
    for s, padj in zip(stats, adjusted):
        f = s["feature"]
        if s["subjects"] == 0:
            print(f"  {f:<24}{FEATURE_WEIGHT[f]:>6.2f}{0:>6}{s['n']:>7}{s['n_pos']:>5}"
                  f"{'REFUSED — too few labelled present days':>45}")
            continue
        star = " *" if (not math.isnan(padj) and padj < 0.05) else ""
        print(f"  {f:<24}{FEATURE_WEIGHT[f]:>6.2f}{s['subjects']:>6}{s['n']:>7}{s['n_pos']:>5}"
              f"{s['r']:>8.3f}  [{s['ci'][0]:>6.3f},{s['ci'][1]:>6.3f}]"
              f"{s['p']:>9.3f}{padj:>10.3f}{star}")
    print("  * = survives Holm correction across the nine features. Nine uncorrected tests")
    print("  produce at least one p<0.05 about 37 % of the time under the null; §6.5 already")
    print("  records that acting on an uncorrected per-feature result is a fatal design flaw.")


def print_roc(subject_days_map, args):
    """ROC over WITHIN-SUBJECT percentile ranks — the only cross-person-comparable score, and
    the one whose thresholds map directly onto the shipped rule ("the top X % of your days")."""
    pooled = []
    for _name, days in subject_days_map:
        scores = [d.index for d in days]
        for pr, d in zip(percentile_ranks(scores), days):
            pooled.append((pr, d.label))
    n_pos = sum(1 for _, y in pooled if y)
    n_neg = len(pooled) - n_pos
    print("\n=== ROC (within-subject percentile rank) ===")
    print("  Each day is placed on ITS OWN subject's percentile scale first, then the curves are")
    print("  overlaid. The area under THIS curve is not identical to the pooled AUC above: that")
    print("  one is a pair-weighted mean of per-subject AUCs, this one weights every day equally,")
    print("  so a subject with more days pulls the shape. Read the curve for its SHAPE — where")
    print("  the operating point sits — and take the number from the pooled AUC.")
    if n_pos < args.min_positives or n_neg < args.min_negatives:
        print(f"  REFUSED — n+={n_pos}, n−={n_neg}")
        return
    pooled.sort(key=lambda t: -t[0])
    pts = [(0.0, 0.0)]
    tp = fp = 0
    i = 0
    while i < len(pooled):
        j = i
        while j + 1 < len(pooled) and pooled[j + 1][0] == pooled[i][0]:
            j += 1
        for k in range(i, j + 1):
            if pooled[k][1]:
                tp += 1
            else:
                fp += 1
        pts.append((fp / n_neg, tp / n_pos))
        i = j + 1

    height, width = 17, 46
    grid = [[" "] * width for _ in range(height)]
    for x, y in pts:
        col = min(width - 1, int(round(x * (width - 1))))
        rowi = min(height - 1, int(round((1 - y) * (height - 1))))
        grid[rowi][col] = "*"
    for k in range(min(height, width)):          # chance diagonal
        col = int(round(k * (width - 1) / (min(height, width) - 1)))
        rowi = height - 1 - int(round(k * (height - 1) / (min(height, width) - 1)))
        if grid[rowi][col] == " ":
            grid[rowi][col] = "."
    print(f"  TPR 1.0 ┤" + "".join(grid[0]))
    for r in range(1, height - 1):
        print("          │" + "".join(grid[r]))
    print(f"      0.0 ┼" + "".join(grid[height - 1]))
    print("           " + "0.0" + " " * (width - 6) + "1.0   FPR   ('.' = chance)")
    print(f"  n+={n_pos}  n−={n_neg}  over {len(subject_days_map)} subject(s)")


def print_calibration(subject_days_map, args):
    print("\n=== CALIBRATION (observed rate by within-subject index decile) ===")
    print("  Descriptive only: the observed rate in THESE files. It is not a probability the")
    print("  app may show, and the app shows none.")
    buckets = [[] for _ in range(10)]
    total_pos = 0
    for _name, days in subject_days_map:
        scores = [d.index for d in days]
        for pr, d in zip(percentile_ranks(scores), days):
            buckets[min(9, int(pr * 10))].append(d.label)
            total_pos += 1 if d.label else 0
    if total_pos < args.min_positives:
        # Ten buckets over a handful of positives is ten numbers each computed from one or two
        # days. Wilson would report that honestly as a 0–80 % interval, but a table of them still
        # reads as a shape, and a shape is exactly what a reader takes away.
        print(f"  REFUSED — {total_pos} positive(s) in total (min {args.min_positives}).")
        print("  Ten deciles over this few labels is a picture of nothing.")
        return
    print(f"  {'decile':<10}{'n':>6}{'n+':>6}{'observed':>11}{'95% CI (Wilson)':>22}")
    for i, b in enumerate(buckets):
        n = len(b)
        k = sum(1 for y in b if y)
        if n == 0:
            print(f"  {f'{i*10}-{i*10+10}%':<10}{0:>6}{0:>6}{'—':>11}")
            continue
        lo, hi = wilson_ci(k, n)
        print(f"  {f'{i*10}-{i*10+10}%':<10}{n:>6}{k:>6}{k / n:>10.1%}"
              f"{f'[{lo:.1%}, {hi:.1%}]':>22}")


def print_operating_point(subjects, subject_days_map, args):
    """Alerts-per-week and precision at the SHIPPED operating point.

    Two readings, because they answer different questions:
      · FROZEN band == flagged — what the app actually decided on this data, including the
        ≥3-contributing-features rule.
      · RE-DERIVED band — the same rule replayed here, which also works on a user who never
        unlocked and lets the parse be checked against the frozen value.
    """
    print("\n=== SHIPPED OPERATING POINT (band == flagged: the top 10 % of a user's own days) ===")
    print("  The copy claims a MEASUREMENT ('last night was unusual for you'), which is true by")
    print("  construction. These numbers are here so nobody upgrades that into a forecast.")
    print(f"  {'subject':>16}{'days':>7}{'n+':>5}{'flagged':>9}{'TP':>5}{'precision':>11}"
          f"{'base':>8}{'lift':>7}{'alerts/wk':>11}")
    tot_days = tot_pos = tot_flag = tot_tp = 0
    for subj in subjects:
        days = dict(subject_days_map).get(subj.name)
        if not days:
            continue
        repro = dict(zip([r.day for r in subj.rows], recompute_bands(subj.rows)))
        flagged = [d for d in days if d.band == 2]
        tp = sum(1 for d in flagged if d.label)
        pos = sum(1 for d in days if d.label)
        n = len(days)
        base = pos / n if n else float("nan")
        weeks = n / 7.0
        # Precision needs a DENOMINATOR of alerts. On one or two flagged days it is 0 % or 50 %
        # and neither is information, so it is withheld while the alert RATE — which needs no
        # labels at all and is what the alert budget is actually about — is always printed.
        enough = len(flagged) >= args.min_positives
        prec = tp / len(flagged) if flagged else float("nan")
        lift = prec / base if flagged and base > 0 else float("nan")
        print(f"  {subj.name:>16}{n:>7}{pos:>5}{len(flagged):>9}{tp:>5}"
              + (f"{prec:>10.1%}" if enough else f"{'n/a':>11}")
              + f"{base:>8.1%}"
              + (f"{lift:>7.2f}" if enough and base > 0 else f"{'—':>7}")
              + f"{len(flagged) / weeks if weeks else 0:>11.2f}")
        agree = sum(1 for d in days if repro.get(d.day) == d.band)
        if agree != len(days):
            print(f"  {'':>16}  note: re-derived band differs on {len(days) - agree} day(s) — "
                  "expected when the export is truncated (<21 priors) or rows were dropped")
        tot_days += n
        tot_pos += pos
        tot_flag += len(flagged)
        tot_tp += tp
    if tot_flag and tot_days:
        lo, hi = wilson_ci(tot_tp, tot_flag)
        base = tot_pos / tot_days
        enough = tot_flag >= args.min_positives
        print(f"  {'POOLED':>16}{tot_days:>7}{tot_pos:>5}{tot_flag:>9}{tot_tp:>5}"
              + (f"{tot_tp / tot_flag:>10.1%}" if enough else f"{'n/a':>11}")
              + f"{base:>8.1%}"
              + (f"{(tot_tp / tot_flag) / base:>7.2f}" if enough and base > 0 else f"{'—':>7}")
              + f"{tot_flag / (tot_days / 7.0):>11.2f}")
        if enough:
            print(f"  {'':>16}  precision 95% CI (Wilson) [{lo:.1%}, {hi:.1%}] on {tot_flag} "
                  "flagged day(s)")
        else:
            print(f"  {'':>16}  precision withheld — only {tot_flag} flagged day(s) in total "
                  f"(min {args.min_positives})")
        print(f"  {'':>16}  §1's prior for this operating point is ~26 % precision at ~0.8 "
              "alerts/week.")
    else:
        print("  no flagged days in the evaluable set — nothing fired, so precision is undefined")
        print("  (a band needs ≥21 prior frozen days; a 14-day Diagnostics export cannot reach it)")

    alerted = sum(1 for _n, days in subject_days_map for d in days if d.row.alerted)
    if alerted:
        alerted_tp = sum(1 for _n, days in subject_days_map for d in days
                         if d.row.alerted and d.label)
        print(f"  rows that ACTUALLY notified: {alerted}, of which {alerted_tp} were followed by a "
              "logged headache")


# ====================================================================================
# Synthetic mode — a runnable demo with a KNOWN planted effect, so the harness itself
# is validated. A backtest nobody has tested is just a second thing to be wrong.
# ====================================================================================
# Features carrying the planted effect. The other six are DEAD WEIGHT by construction, so the
# point-biserial table can be checked for its ability to tell them apart — which is the whole
# reason that table exists.
SYNTH_CARRIERS = ("sleepEfficiencyDrop", "restingHRDeviation", "hrvDeviation")

# Per-feature probability the input is ABSENT on any given night. skinTemp is high on purpose:
# skin temp is LIVE-only (0x10/0x87) and is not in the drainable 0x4c history, so a missed
# window can never be back-filled (project memory: skin-temp-capture).
SYNTH_ABSENCE = {
    "sleepEfficiencyDrop": 0.05, "arousalLetdown": 0.35, "hrvDeviation": 0.10,
    "restingHRDeviation": 0.05, "sleepFragmentation": 0.05, "sleepDurationDeviation": 0.05,
    "scheduleShift": 0.15, "skinTempDeviation": 0.60, "perimenstrual": 1.00,
}
SYNTH_ABSENT_REASON = {
    "sleepEfficiencyDrop": "noDataThisDay", "arousalLetdown": "noDataThisDay",
    "hrvDeviation": "noDataThisDay", "restingHRDeviation": "noDataThisDay",
    "sleepFragmentation": "noDataThisDay", "sleepDurationDeviation": "noDataThisDay",
    "scheduleShift": "noBaseline", "skinTempDeviation": "noDataThisDay",
    "perimenstrual": "notApplicable",
}


def _ramp(feature, value):
    """Port of the two ramps in `HeadacheSignals.assess`: |z| for the series features, signed °C
    for skin temp, binary for cycle phase."""
    if feature == "skinTempDeviation":
        return max(0.0, min(1.0, (abs(value) - TEMP_ONSET_C)
                            / max(TEMP_SATURATION_C - TEMP_ONSET_C, 1e-300)))
    if feature == "perimenstrual":
        return 1.0 if value else 0.0
    return max(0.0, min(1.0, (abs(value) - ONSET_Z) / max(SATURATION_Z - ONSET_Z, 1e-300)))


def _synth_day_features(rng, label, effect, subject_shift):
    """One night's raw feature values. A headache day shifts the CARRIER features' z by
    `effect` (in z units, one-sided-ish via the |z| ramp the engine actually uses); every other
    feature is drawn from the same distribution regardless of the label."""
    out = {}
    for f in FEATURES:
        if rng.random() < SYNTH_ABSENCE[f]:
            out[f] = None
            continue
        if f == "skinTempDeviation":
            mu = (effect * 0.35) if (label and f in SYNTH_CARRIERS) else 0.0
            out[f] = rng.gauss(mu, 0.45)
        elif f == "perimenstrual":
            out[f] = False
        else:
            mu = (effect + subject_shift) if (label and f in SYNTH_CARRIERS) else 0.0
            out[f] = rng.gauss(mu, 1.0)
    return out


def _synth_index(values):
    """The engine's arithmetic on one night: ramp, cap, renormalise over PRESENT features."""
    present = {f: _ramp(f, v) for f, v in values.items() if v is not None}
    if not present:
        return None, {}, {}
    w = apply_single_feature_cap({f: FEATURE_WEIGHT[f] for f in present})
    total = sum(w.values())
    index = round(100.0 * sum(w[f] * present[f] for f in present) / total) if total > 0 else 0
    contributions = {}
    absent = {}
    for f in FEATURES:
        v = values.get(f)
        if v is None:
            contributions[f] = (None, None, 0.0)
            absent[f] = SYNTH_ABSENT_REASON[f]
        else:
            contributions[f] = (float(v), present[f], w[f])
    return float(index), contributions, absent


def synth_subject(name, seed, days=180, base_rate=0.14, effect=1.2, start=None):
    """One synthetic person: frozen rows + a headache log consistent with them.

    The generative story is deliberately the one the design assumes: a headache day's carrier
    features deviate MORE, in an unpredictable direction (the engine takes |z|), and everything
    else is noise. Subject heterogeneity is real — each subject gets its own effect shift, so a
    pooled number is not being computed over nine clones.

    It also plants `postUnlock` where a real install sets it, because the STATE of an install is
    part of the data it emits. An earlier version of this generator left the flag off on every
    row, so the dominant real-world case — a row scored after the notification unlocked — was
    never generated, and a default exclusion that dropped every row after a tester's third week
    ran green through every self-check below. A generator that cannot produce the common case
    cannot fail on it.
    """
    rng = random.Random(seed)
    start = start or datetime(2026, 1, 1, tzinfo=timezone.utc)
    subject_shift = rng.uniform(-0.35, 0.35)

    rows, headaches = [], []
    unlocked = False
    for i in range(days):
        day = start + timedelta(days=i)
        label = rng.random() < base_rate
        values = _synth_day_features(rng, label, effect, subject_shift)
        index, contributions, absent = _synth_index(values)
        if index is None:
            continue                    # a night with nothing measured never freezes a row
        ring_present = sum(1 for f in FEATURES
                           if contributions[f][1] is not None and RING_DERIVED[f])
        if ring_present < MIN_RING_FEATURES_FOR_SCORE:
            continue                    # GATE 3 — coverage; no score exists at all
        # The freeze happens the morning after the night, ~3 h after wake (§5.1).
        computed_at = (day + timedelta(hours=9)).timestamp()
        coverage = sum(FEATURE_WEIGHT[f] for f in FEATURES
                       if contributions[f][1] is not None and RING_DERIVED[f])
        rows.append(Row(day=day, index=index, band=0, ring_feature_count=ring_present,
                        coverage=min(1.0, coverage), contributions=contributions,
                        absent=absent, computed_at=computed_at, post_unlock=unlocked))
        # `HeadacheEngine.unlockIfBandExists`, mirrored (read 2026-07-31). `refreshToday` freezes
        # FIRST and then lets the monitor look, and the monitor counts rows STRICTLY BEFORE today
        # inside the trailing `bandWindowDays` CALENDAR window — so the morning that reaches 21
        # priors is itself still pre-unlock, and every row after it carries the flag. Nothing
        # clears it here: only a retirement can, and the monitor cannot retire before its first
        # decision interval has elapsed.
        if not unlocked:
            window_start = day - timedelta(days=BAND_WINDOW_DAYS)
            priors = sum(1 for r in rows[:-1] if window_start <= r.day < day)
            unlocked = priors >= MIN_DAYS_FOR_BANDING
        if label:
            # Onset strictly inside (computedAt, computedAt+24h] so §5.1 credits it. Four in five
            # entries carry a logged end, matching a diary where most attacks resolve and some are
            # logged mid-attack and never closed — the open ones exercise the assumed-duration
            # branch of the in-progress exclusion, which is the part most able to surprise us.
            onset = computed_at + rng.uniform(0.5, 23.5) * 3600.0
            end = None if rng.random() < 0.2 else onset + rng.uniform(2, 10) * 3600.0
            headaches.append(Headache(onset=onset, end=end, severity=rng.choice([2, 3, 4])))

    # Bands come from the SAME replay the harness uses, so a disagreement in the parse check is
    # a parse bug and can be nothing else.
    for row, band in zip(rows, recompute_bands(rows)):
        row.band = band

    return Subject(name=name, rows=rows, headaches=headaches, tz_name="UTC",
                   source_kind="synthetic", planted_shift=subject_shift)


def oracle_auc(seed, days=40000, base_rate=0.14, effect=1.2, shift=0.0):
    """Monte-Carlo the SAME generator at large n to get the target the estimators must recover.

    This is what makes `--synthetic` a validation rather than a demo: the planted effect implies
    a specific AUC, computed here independently of the code path under test (no files, no
    parsers, no exclusion logic), and the self-check asserts the measured number lands on it.

    `shift` MUST be the subject's own planted heterogeneity. An oracle averaged over the
    population instead is a different number from the truth for the four people actually drawn,
    and the gap looked like an estimator bug at one seed — the check would then be failing for
    a reason that has nothing to do with the code it is testing, which is worse than no check.
    """
    rng = random.Random(seed)
    scores, labels = [], []
    for _ in range(days):
        label = rng.random() < base_rate
        values = _synth_day_features(rng, label, effect, shift)
        index, contributions, _absent = _synth_index(values)
        if index is None:
            continue
        ring_present = sum(1 for f in FEATURES
                           if contributions[f][1] is not None and RING_DERIVED[f])
        if ring_present < MIN_RING_FEATURES_FOR_SCORE:
            continue
        scores.append(index)
        labels.append(label)
    return auc_mann_whitney(scores, labels)


def write_rollup(path, subject):
    """Serialise a synthetic subject in the app's OWN backup shape — Apple-epoch Dates and all —
    so the demo exercises the real loader instead of an in-memory shortcut."""
    def apple(ts):
        return None if ts is None else ts - APPLE_EPOCH_OFFSET
    obj = {
        "sleep": [], "daily": [], "periods": [], "naps": [],
        "headaches": [{"onset": apple(h.onset), "end": apple(h.end), "severityRaw": h.severity,
                       "symptoms": [], "customSymptoms": [], "factors": [], "notes": "",
                       "sourceRaw": h.source, "healthWritten": True, "hkSampleUUIDs": [],
                       "updatedAt": apple(h.onset)} for h in subject.headaches],
        "riskDays": [{
            "day": apple(r.day.timestamp()), "nightKey": apple(r.day.timestamp()),
            "index": r.index, "bandRaw": r.band, "ringFeatureCount": r.ring_feature_count,
            "coverageFraction": r.coverage,
            "contributionsJSON": json.dumps(
                {f: {"z": r.contributions[f][0], "c": r.contributions[f][1],
                     "w": r.contributions[f][2]} for f in FEATURES if f in r.contributions},
                sort_keys=True),
            "absentJSON": json.dumps(r.absent, sort_keys=True),
            "computedAt": apple(r.computed_at), "sleepUpdatedAt": None,
            "sleepRestaged": r.restaged, "alerted": r.alerted, "postUnlock": r.post_unlock,
            "updatedAt": apple(r.computed_at)} for r in subject.rows],
    }
    with open(path, "w") as fh:
        json.dump(obj, fh)


def write_diagnostics(path, subject, window_days=14):
    """Emit the `# Headache signals` section byte-for-byte in `DiagnosticsReport`'s format, so
    the text parser is exercised against the real layout — including its 2 dp rounding."""
    rows = subject.rows[-window_days:]
    # The header has to agree with the rows under it. A bundle that says the alerts are locked
    # while its rows carry `postUnlock` is a document the app cannot emit, and the fixture's job
    # is to be a document the app CAN emit. `promotedOnDayKey` is the Int `yyyymmdd` written on
    # the morning the unlock was granted — the last still-locked row's own day.
    locked_rows = [r for r in subject.rows if not r.post_unlock]
    unlocked = len(locked_rows) < len(subject.rows)
    promoted = locked_rows[-1].day.strftime("%Y%m%d") if unlocked and locked_rows else "—"
    out = ["OpenCircuit — diagnostics bundle", "", "# Headache signals",
           f"  enabled: true · alerts unlocked: {'true' if unlocked else 'false'} · "
           f"promotedOnDayKey: {promoted} · lookCount: 0"]
    if rows:
        out.append(f"  Window: {rows[0].day.date()} → {rows[-1].day.date()} "
                   f"({window_days} days, UTC)")
    out.append("")
    out.append(f"Frozen daily rows (latest {len(rows)} of {len(subject.rows)} — written once, "
               "never recomputed)")
    for r in sorted(rows, key=lambda x: x.day, reverse=True):
        flags = [n for n, on in (("restaged", r.restaged), ("alerted", r.alerted),
                                 ("postUnlock", r.post_unlock)) if on]
        out.append(f"  {r.day.date()}  index {r.index:g}  {BAND_NAMES.get(r.band, r.band)}"
                   f"  ring {r.ring_feature_count}/8  coverage {r.coverage:.2f}"
                   + (f"  [{' '.join(flags)}]" if flags else ""))
        present = []
        for f in FEATURES:
            rec = r.contributions.get(f)
            if not rec or rec[1] is None:
                continue
            z = f"{rec[0]:+.2f}" if rec[0] is not None else "—"
            present.append(f"{f}={rec[1]:.2f} (z {z}, w {rec[2]:.2f})")
        out.append("      present: " + (", ".join(present) if present else "(none)"))
        missing = [f"{f}={r.absent.get(f, '(no reason recorded)')}"
                   for f in FEATURES if (r.contributions.get(f) or (None, None, 0))[1] is None]
        out.append("      absent: "
                   + (", ".join(missing) if missing else "(none — every feature present)"))
    # The per-feature presence table. Reproduced because it sits BETWEEN the rows and the trailing
    # lines in the real export and its rows also begin with two spaces and contain numbers — so
    # emitting it is what proves the row regex cannot swallow it. A fixture that omits the
    # neighbouring layout tests the parser against a document that does not exist.
    out.append("")
    name_width = max(len(f) for f in FEATURES) + 2
    out.append(f"Per-feature presence over those {len(rows)} row(s):")
    for f in FEATURES:
        present = sum(1 for r in rows if (r.contributions.get(f) or (None, None, 0))[1] is not None)
        reasons = {}
        for r in rows:
            if (r.contributions.get(f) or (None, None, 0))[1] is None:
                reason = r.absent.get(f, "(no reason recorded)")
                reasons[reason] = reasons.get(reason, 0) + 1
        ranked = sorted(reasons.items(), key=lambda kv: (-kv[1], kv[0]))
        out.append(f"  {f}{' ' * (name_width - len(f))}present {present}/{len(rows)}"
                   + (" · absent: " + ", ".join(f"{k} {v}" for k, v in ranked) if ranked else "")
                   + ("" if RING_DERIVED[f] else "   (cycle phase — not ring-derived)"))

    window_start = rows[0].day if rows else None
    in_window = sum(1 for h in subject.headaches
                    if window_start is not None and h.onset >= window_start.timestamp())
    by_source = {"user": len(subject.headaches), "healthImport": 0, "periodLogImport": 0}
    out += ["",
            f"Nights with skinTempC > 0: 4/{window_days} ({len(rows)} night(s) stored in the window)",
            f"Headache log: {len(subject.headaches)} entries · {in_window} in the window · 0 "
            "awaiting the Apple Health mirror",
            "  by source: " + " · ".join(f"{k} {v}" for k, v in by_source.items())
            + " · consumed import UUIDs 0",
            "", "# Raw-frame capture", "  (none)"]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))


def write_log_csv(path, subject):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["onset", "end", "severity", "source"])
        for h in subject.headaches:
            w.writerow([datetime.fromtimestamp(h.onset, timezone.utc).isoformat(),
                        "" if h.end is None else
                        datetime.fromtimestamp(h.end, timezone.utc).isoformat(),
                        h.severity, h.source])


def known_answer_checks(seed=3):
    """Known-answer tests for the arithmetic itself, run as part of `--synthetic`.

    The planted-effect arm proves the PIPELINE recovers a truth; these prove the ESTIMATORS are
    the estimators they claim to be. Both are needed: a subtly wrong AUC would still recover a
    planted effect monotonically and look fine.
    """
    checks = []

    # AUC against the definition, brute-forced over tie-heavy random samples. Ties matter here:
    # a great many days score index 0, so a tie-blind AUC would be systematically wrong on
    # exactly the data this feature produces.
    rng = random.Random(seed)
    worst = 0.0
    for _ in range(200):
        n = rng.randint(6, 40)
        s = [rng.choice([0, 1, 1, 2, 3, 5, 5, 8]) for _ in range(n)]
        y = [rng.random() < 0.3 for _ in range(n)]
        if not any(y) or all(y):
            continue
        pos = [a for a, b in zip(s, y) if b]
        neg = [a for a, b in zip(s, y) if not b]
        brute = sum((1.0 if p > q else 0.5 if p == q else 0.0)
                    for p in pos for q in neg) / (len(pos) * len(neg))
        worst = max(worst, abs(brute - auc_mann_whitney(s, y).auc))
    checks.append(("AUC equals P(pos>neg)+½P(tie) on 200 tie-heavy samples", worst < 1e-12))

    checks.append(("AUC is 1 / 0 / 0.5 on perfect / reversed / all-tied inputs",
                   auc_mann_whitney([1, 2, 3, 4], [0, 0, 1, 1]).auc == 1.0
                   and auc_mann_whitney([4, 3, 2, 1], [0, 0, 1, 1]).auc == 0.0
                   and auc_mann_whitney([2, 2, 2, 2], [0, 0, 1, 1]).auc == 0.5))

    lo, hi = wilson_ci(5, 10)                      # textbook 95 % Wilson for 5/10
    checks.append(("Wilson 5/10 = [0.2366, 0.7634]",
                   abs(lo - 0.2366) < 5e-4 and abs(hi - 0.7634) < 5e-4))

    checks.append(("Holm step-down on [.01,.04,.03] = [.03,.06,.06]",
                   [round(v, 10) for v in holm([0.01, 0.04, 0.03])] == [0.03, 0.06, 0.06]))

    # The banding percentile MUST match `HeadacheSignals.percentile` — a different convention
    # here would silently re-derive a different operating point from the shipped one.
    checks.append(("percentile matches the Swift linear interpolation (p90 of 0…9 = 8.1)",
                   abs(percentile_linear(list(range(10)), 0.9) - 8.1) < 1e-9))

    # The 35 % cap is what stops one input owning a verdict; if this port drifts, the re-weighted
    # score stops being the shipped arithmetic.
    capped = apply_single_feature_cap({"a": 0.9, "b": 0.1})
    total = sum(capped.values())
    checks.append(("single-feature cap holds the top weight at 35 % of the pool",
                   abs(capped["a"] / total - MAX_SINGLE_FEATURE_SHARE) < 1e-9))

    # Apple-epoch coercion: 2001-01-01 is 0 on that epoch, 978307200 on unix.
    checks.append(("Apple-reference dates decode to the right instant",
                   abs(_coerce_time(0.0) - APPLE_EPOCH_OFFSET) < 1e-6
                   and abs(_coerce_time("2001-01-01T00:00:00Z") - APPLE_EPOCH_OFFSET) < 1e-6))
    return checks


def run_synthetic(args):
    print_header()
    print("\nSYNTHETIC MODE — a KNOWN planted effect, so the harness itself is under test.")
    print(f"  {args.subjects} subject(s) × {args.days} days, base rate {args.base_rate:.0%}, "
          f"planted carrier shift {args.effect:g} z on "
          + ", ".join(SYNTH_CARRIERS))
    print("  Every other feature is dead weight by construction. Files are WRITTEN to disk and")
    print("  RELOADED through the real loaders, so the parsers are exercised end to end.")

    tmp = args.synthetic_out or tempfile.mkdtemp(prefix="headache_backtest_")
    os.makedirs(tmp, exist_ok=True)
    subjects = []
    planted_shift = {}
    for k in range(args.subjects):
        planted = synth_subject(f"synth{k + 1}", seed=args.seed + k, days=args.days,
                                base_rate=args.base_rate, effect=args.effect)
        planted_shift[planted.name] = planted.planted_shift
        rollup_path = os.path.join(tmp, f"{planted.name}_rollup.json")
        write_rollup(rollup_path, planted)
        subjects.append(load_rollup(rollup_path, name=planted.name))
    # One subject also round-trips through the DIAGNOSTICS text path, so both parsers are
    # covered and can be checked against each other on the same underlying rows.
    diag_subject = synth_subject("synth1", seed=args.seed, days=args.days,
                                 base_rate=args.base_rate, effect=args.effect)
    diag_path = os.path.join(tmp, "synth1_diagnostics.txt")
    log_path = os.path.join(tmp, "synth1_log.csv")
    write_diagnostics(diag_path, diag_subject)
    write_log_csv(log_path, diag_subject)
    diag_loaded = load_diagnostics(diag_path, name="synth1-diag", assumed_freeze_hour=9.0)
    diag_loaded.headaches = load_log(log_path, diag_loaded)
    print(f"  wrote + reloaded under {tmp}")

    report = run_report(subjects, args)

    # ------------------------------------------------------------------ self-check
    print("\n=== SELF-CHECK (the harness validating itself against the planted truth) ===")
    checks = known_answer_checks()

    # The oracle is computed PER SUBJECT at that subject's own planted shift and pooled with the
    # same pair weights the measurement used, so the only difference left between the two numbers
    # is finite-sample noise over ~180 days — which is what the tolerance is for.
    per_subject_pairs = report["per_subject"]
    oracle_num = oracle_den = 0.0
    oracle_n = 0
    for i, (name, res) in enumerate(per_subject_pairs):
        if not res.usable:
            continue
        o = oracle_auc(args.seed + 9999 + i, days=max(2000, args.oracle_days // args.subjects),
                       base_rate=args.base_rate, effect=args.effect,
                       shift=planted_shift.get(name, 0.0))
        if math.isnan(o.auc):
            continue
        oracle_num += res.pairs * o.auc
        oracle_den += res.pairs
        oracle_n += o.n_pos + o.n_neg
    oracle_value = oracle_num / oracle_den if oracle_den else float("nan")
    measured = report["pooled"]
    print(f"  oracle AUC from the same generator (per-subject shifts, n={oracle_n} simulated "
          f"days): {oracle_value:.3f}")
    print(f"  measured pooled AUC: {measured.auc:.3f} "
          f"[{measured.ci_low:.3f}, {measured.ci_high:.3f}]  n+={measured.n_pos}")
    checks.append(("pooled AUC recovers the planted effect (±0.08)",
                   not math.isnan(measured.auc) and not math.isnan(oracle_value)
                   and abs(measured.auc - oracle_value) <= 0.08))
    checks.append(("planted effect is detected above chance",
                   not math.isnan(measured.auc) and measured.auc > 0.5))

    # The carrier features must outrank the dead weight in the point-biserial table. If they
    # don't, that table cannot be trusted to retire a weight on real data — which is its only job.
    ranked = report["feature_r"]
    def strength(kv):
        return -abs(kv[1]) if not math.isnan(kv[1]) else 0.0
    top3 = [f for f, _r in sorted(ranked.items(), key=strength)[:3]]
    print(f"  strongest three |r| features: {', '.join(top3)}")
    checks.append(("point-biserial ranks the planted carriers first",
                   set(top3) == set(SYNTH_CARRIERS)))

    # Parse cross-check: the text export and the rollup describe the SAME nights. They must
    # agree to the export's 2 dp, and no further — a tighter check would be a false claim about
    # what a Diagnostics bundle preserves.
    by_day = {r.day.date(): r for r in diag_subject.rows}
    deltas = []
    flag_mismatches = 0
    for r in diag_loaded.rows:
        src = by_day.get(r.day.date())
        if src is None:
            continue
        deltas.append(abs(r.index - src.index))
        # The `[postUnlock]` flag is now load-bearing on BOTH input paths — whether a row is in
        # the sample at all depends on reading it, so a text parser that dropped it would move
        # the answer, not just a printed detail.
        flag_mismatches += int(r.post_unlock != src.post_unlock)
        for f in FEATURES:
            a, b = r.c(f), src.c(f)
            if (a is None) != (b is None):
                deltas.append(9.9)      # presence disagreement is a hard failure
            elif a is not None:
                deltas.append(abs(a - b))
    print(f"  diagnostics-vs-rollup agreement over {len(diag_loaded.rows)} shared row(s): "
          f"max |Δ| {max(deltas) if deltas else float('nan'):.4f}"
          f" · postUnlock disagreements {flag_mismatches}")
    checks.append(("the text parser reproduces the rows to the export's 2 dp",
                   bool(deltas) and max(deltas) <= 0.006))
    checks.append(("the text export round-trips the postUnlock flag",
                   bool(diag_loaded.rows) and flag_mismatches == 0))

    # THE DEFAULT PATH MUST RETAIN POST-UNLOCK ROWS. This is a regression test for a real defect
    # in this file: the exclusion was written for the old design, where the notification was gated
    # behind proof, and it survived the redesign that unlocks at 21 scored nights. Because the
    # flag latches on in week three and never clears, the default harness was analysing the first
    # three weeks of each export and reporting it as the cross-user result. Nothing in the output
    # said so — the excluded count was printed, but a small sample looks exactly like a small
    # study. The opt-in arm is asserted too, so restoring the old sample stays possible.
    total_rows = sum(len(s.rows) for s in subjects)
    post_rows = sum(1 for s in subjects for r in s.rows if r.post_unlock)
    kept_post = sum(1 for _n, d in report["subject_map"] for x in d if x.row.post_unlock)
    default_days = sum(len(d) for _n, d in report["subject_map"])
    strict = [evaluable(label_days(
        s, horizon_hours=args.horizon_hours,
        lookback_hours=args.in_progress_lookback_hours,
        obs_end=(args.observation_end if args.observation_end is not None
                 else observation_end(s)),
        exclude_spanning=args.exclude_spanning, include_restaged=args.include_restaged,
        exclude_post_unlock=True)) for s in subjects]
    strict_days = sum(len(d) for d in strict)
    print(f"  post-unlock rows: {post_rows} of {total_rows} loaded"
          + (f" ({post_rows / total_rows:.0%})" if total_rows else "")
          + f" · evaluable days {default_days} by default vs {strict_days} under "
            "--exclude-post-unlock")
    # Predicted here from the row COUNTS alone, independently of the generator's own loop, so the
    # check is an assertion rather than an echo: the monitor unlocks on the morning that sees 21
    # prior rows and that morning's row is itself still pre-unlock, so a subject with n rows
    # carries n − 22 post-unlock ones. A short run (`--days 20`) predicts 0 and passes on 0 — a
    # check that fails on a valid argument teaches its reader to ignore checks. The trailing
    # 60-day window cannot bind: this generator would have to skip 38 nights in a row.
    expected_post = sum(max(0, len(s.rows) - (MIN_DAYS_FOR_BANDING + 1)) for s in subjects)
    checks.append(("the generator plants post-unlock rows exactly where an install would "
                   f"(expected {expected_post})", post_rows == expected_post))
    # The IDENTITY is the strong form: the two paths may differ by the post-unlock rows and by
    # nothing else. It holds at any run length, and it fails the moment the exclusion returns.
    checks.append(("the DEFAULT path keeps every post-unlock row (default = strict + post-unlock)",
                   default_days == strict_days + kept_post))
    checks.append(("--exclude-post-unlock still drops them (the sensitivity check survives)",
                   not any(x.row.post_unlock for d in strict for x in d)))

    # Regression test for a defect that shipped in the first version of this file: the subject-level
    # CI was a ONE-STAGE cluster bootstrap, which drops within-subject sampling error entirely. It
    # reported width 0.075 against Hanley–McNeil's 0.125 while the copy above it told the reader to
    # quote it as the more conservative number. Nothing in the output revealed the contradiction,
    # because both intervals looked perfectly reasonable on their own.
    #
    # The assertion is two-stage > ONE-STAGE, which is structural (stage 2 adds an independent
    # noise source). It is deliberately NOT "two-stage > Hanley–McNeil": that looked like the
    # obvious check and passed at six seeds out of eight, then failed at seeds 23 and 123 where a
    # high AUC and closely-agreeing subjects make the parametric formula the wider one. A
    # self-check that fails on a quarter of seeds teaches its reader to ignore self-checks.
    boot_lo, boot_hi, boot_draws = cluster_bootstrap_ci(
        report["subject_map"], resamples=min(args.bootstrap, 1000))
    one_lo, one_hi, _ = cluster_bootstrap_ci(
        report["subject_map"], resamples=min(args.bootstrap, 1000), resample_days=False)
    day_width = measured.ci_high - measured.ci_low
    boot_width, one_width = boot_hi - boot_lo, one_hi - one_lo
    print(f"  CI widths — two-stage subject {boot_width:.3f} · one-stage subject {one_width:.3f}"
          f" · day-level {day_width:.3f} ({boot_draws} resamples)")
    checks.append(("the two-stage bootstrap is wider than the one-stage form (stage 2 restores "
                   "within-subject sampling error)",
                   not math.isnan(boot_width) and not math.isnan(one_width)
                   and boot_width > one_width))

    # NULL ARM: the same machine, zero planted effect, must NOT report skill. A backtest that
    # cannot fail is not a test — this is the arm that would catch a leak between score and label.
    null_subjects = []
    null_tmp = os.path.join(tmp, "null")
    os.makedirs(null_tmp, exist_ok=True)
    for k in range(max(3, args.subjects)):
        planted = synth_subject(f"null{k + 1}", seed=args.seed + 500 + k, days=args.days,
                                base_rate=args.base_rate, effect=0.0)
        p = os.path.join(null_tmp, f"null{k + 1}.json")
        write_rollup(p, planted)
        null_subjects.append(load_rollup(p, name=planted.name))
    null_labelled = {s.name: label_days(s) for s in null_subjects}
    null_map = [(s.name, evaluable(null_labelled[s.name])) for s in null_subjects]
    null_per = [(n, subject_auc(d)) for n, d in null_map]
    null_pooled, _ = pooled_auc(null_per)
    null_p, _ = permutation_p_pooled(null_map, null_pooled.auc, permutations=500)
    print(f"  NULL arm (effect 0): pooled AUC {null_pooled.auc:.3f} "
          f"[{null_pooled.ci_low:.3f}, {null_pooled.ci_high:.3f}]  n+={null_pooled.n_pos}  "
          f"permutation p {null_p:.3f}")
    checks.append(("the null arm shows no skill (0.40 ≤ AUC ≤ 0.60)",
                   0.40 <= null_pooled.auc <= 0.60))

    # The refusal must actually refuse. One positive is not an AUC.
    tiny = [d for d in null_map[0][1][:20]]
    for d in tiny:
        d.label = False
    if tiny:
        tiny[0].label = True
    refusal = fmt_auc(subject_auc(tiny), args.min_positives, args.min_negatives)
    checks.append(("an AUC on 1 positive is REFUSED, not printed", refusal.startswith("REFUSED")))

    print()
    for name, ok in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    passed = all(ok for _, ok in checks)
    print("\nSELF-CHECK PASSED" if passed else "\nSELF-CHECK FAILED")
    return 0 if passed else 1


# ====================================================================================
# Pipeline
# ====================================================================================
def run_report(subjects, args):
    labelled = {}
    obs_ends = {}
    for s in subjects:
        obs_ends[s.name] = (args.observation_end
                            if args.observation_end is not None else observation_end(s))
        labelled[s.name] = label_days(
            s, horizon_hours=args.horizon_hours,
            lookback_hours=args.in_progress_lookback_hours,
            obs_end=obs_ends[s.name],
            exclude_spanning=args.exclude_spanning,
            include_restaged=args.include_restaged,
            exclude_post_unlock=args.exclude_post_unlock)
    print_subject_summary(subjects, labelled, obs_ends)
    print_parse_check(subjects)

    subject_map = [(s.name, evaluable(labelled[s.name])) for s in subjects]
    subject_map = [(n, d) for n, d in subject_map if d]
    if not subject_map:
        print("\nNo evaluable days in any subject — nothing can be estimated.")
        return {"pooled": AUCResult(float("nan"), 0, 0, float("nan"), float("nan")),
                "feature_r": {}, "per_subject": [], "subject_map": []}

    pooled = print_auc_section(subject_map, args)
    print_loso_section(subject_map, pooled, args)
    stats = feature_stats(subject_map, args)
    print_feature_table(stats)
    print_roc(subject_map, args)
    print_calibration(subject_map, args)
    print_operating_point(subjects, subject_map, args)

    print("\n=== WHAT THIS DOES AND DOES NOT LICENCE ===")
    print("  docs/HEADACHE_SIGNALS.md §12 Tier 4: no accuracy number, no 'predicts', and no")
    print("  headache claim outside the app until ≥3 testers each have ≥50 labelled days AND the")
    print("  pooled leave-one-subject-out AUC exceeds 0.60 with a CI excluding 0.50.")
    ready = [n for n, d in subject_map if sum(1 for x in d if x.label) >= 1 and len(d) >= 50]
    print(f"  subjects with ≥50 evaluable (labelled) days: {len(ready)} of {len(subject_map)}"
          f"  ·  pooled positives: {pooled.n_pos}")
    if getattr(args, "synthetic", False):
        # A synthetic subject clears any bar you like — the effect was planted by this file. Saying
        # "MET" here without this line is how a demo run ends up quoted as evidence.
        print("  Tier-4 bar: NOT ASSESSED — this run is SYNTHETIC. Planted data proves the")
        print("  arithmetic runs; it says nothing about whether the detector works on people.")
    elif pooled.usable and not math.isnan(pooled.ci_low):
        bar = (len(ready) >= 3 and pooled.auc > 0.60 and pooled.ci_low > 0.50)
        print(f"  Tier-4 bar: {'MET on this data' if bar else 'NOT met'} — until it is met on"
              " REAL subjects the external")
        print("  description stays 'surfaces unusual patterns in your own data'.")
    return {"pooled": pooled,
            "feature_r": {s["feature"]: s["r"] for s in stats},
            "per_subject": [(n, subject_auc(d)) for n, d in subject_map],
            "subject_map": subject_map}


def _parse_iso(s):
    ts = _coerce_time(s)
    if ts is None:
        raise argparse.ArgumentTypeError(f"bad instant {s!r}; use YYYY-MM-DD or an ISO-8601 time")
    return ts


def _split(arg):
    return [p.strip() for p in arg.split(",") if p.strip()] if arg else []


def _dedupe_names(subjects):
    """Subject name is the KEY everything downstream joins on — the bootstrap's lookup table, the
    operating-point join, the pooled strata. Two files with the same basename (`rollup-backup.json`
    from two testers is the likely case) would silently collapse into one subject and quietly
    shrink the sample, so the collision is renamed and announced instead."""
    seen = {}
    for s in subjects:
        if s.name in seen:
            seen[s.name] += 1
            new = f"{s.name}#{seen[s.name]}"
            print(f"  (duplicate subject name {s.name!r} — renamed to {new!r})")
            s.name = new
        else:
            seen[s.name] = 1
    return subjects


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rollup", help="rollup-backup.json path(s), comma-separated (one per subject)")
    ap.add_argument("--diagnostics", help="Diagnostics export path(s), comma-separated")
    ap.add_argument("--log", help="headache log path(s), comma-separated, paired with --diagnostics")
    ap.add_argument("--subjects-named", help="override subject names, comma-separated")

    ap.add_argument("--horizon-hours", type=float, default=OUTCOME_WINDOW_HOURS,
                    help="outcome window after the freeze instant (§5.1 and the shipped "
                         "HeadacheEvaluation.Tuning both pin 24)")
    ap.add_argument("--in-progress-lookback-hours", type=float,
                    default=IN_PROGRESS_LOOKBACK_HOURS,
                    help="an onset this long before the freeze means the attack had already "
                         "started, so the row is unclassifiable (shipped default 24)")
    ap.add_argument("--exclude-spanning", action="store_true",
                    help="ALSO exclude a row when a logged headache's onset…end spans the freeze "
                         "instant. A deliberate divergence from the shipped rule — sensitivity "
                         "check only")
    ap.add_argument("--observation-end", type=_parse_iso,
                    help="ISO instant after which these files say nothing; rows whose outcome "
                         "window runs past it are dropped. Inferred per subject when omitted")
    ap.add_argument("--assumed-freeze-hour", type=float, default=9.0,
                    help="local hour assumed as the freeze instant on the diagnostics path, "
                         "which does not export computedAt")
    ap.add_argument("--tz", help="override the timezone of a diagnostics export")
    ap.add_argument("--include-restaged", action="store_true",
                    help="include rows whose sleep re-staged after the freeze (§5.1 excludes them)")
    ap.add_argument("--exclude-post-unlock", action="store_true",
                    help="drop days scored after the morning notification unlocked. They are KEPT "
                         "by default — the notification now unlocks at 21 scored nights, so the "
                         "flag latches on early and excluding it discards nearly every row. "
                         "Sensitivity check / old gated-design data only")

    ap.add_argument("--min-positives", type=int, default=5,
                    help="refuse to print an AUC below this many positives")
    ap.add_argument("--min-negatives", type=int, default=5)
    ap.add_argument("--permutations", type=int, default=PERMUTATION_COUNT)
    ap.add_argument("--bootstrap", type=int, default=2000)
    ap.add_argument("--no-loso", action="store_true", help="skip the weight-fitting LOSO arm")

    ap.add_argument("--synthetic", action="store_true",
                    help="generate data with a KNOWN planted effect and validate the harness")
    ap.add_argument("--subjects", type=int, default=4, help="synthetic subject count")
    ap.add_argument("--days", type=int, default=180, help="synthetic days per subject")
    ap.add_argument("--base-rate", type=float, default=0.14,
                    help="synthetic headache days per day (0.14 ≈ 4/month)")
    ap.add_argument("--effect", type=float, default=1.2,
                    help="synthetic planted carrier-feature shift, in z")
    ap.add_argument("--oracle-days", type=int, default=40000,
                    help="Monte-Carlo sample for the oracle AUC the self-check asserts against")
    ap.add_argument("--synthetic-out", help="keep the generated demo files in this directory "
                                            "(they are the fixture format the real loaders read)")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args(argv)

    if args.synthetic:
        return run_synthetic(args)

    rollups = _split(args.rollup)
    diags = _split(args.diagnostics)
    logs = _split(args.log)
    names = _split(args.subjects_named)
    if not rollups and not diags:
        ap.error("provide --rollup, or --diagnostics with --log (or use --synthetic)")
    if diags and len(logs) != len(diags):
        ap.error("--diagnostics and --log must list the same number of files")

    subjects = []
    for path in rollups:
        subjects.append(load_rollup(path))
    for path, logpath in zip(diags, logs):
        s = load_diagnostics(path, assumed_freeze_hour=args.assumed_freeze_hour,
                             tz_override=args.tz)
        s.headaches = load_log(logpath, s)
        subjects.append(s)
    for i, n in enumerate(names):
        if i < len(subjects):
            subjects[i].name = n

    print_header()
    _dedupe_names(subjects)
    run_report(subjects, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
