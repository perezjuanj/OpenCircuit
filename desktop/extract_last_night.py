#!/usr/bin/env python3
"""Extract the sleep/vitals the ring actually held — the data our app failed to sync.

Decodes the 0x4c sleep-vitals epochs from a `decode-log` txt into REAL HR / HRV /
SpO2 / respiratory-rate values, faithfully mirroring OpenCircuitKit's BulkSleep.swift
(the on-device decoder) so the numbers match what the app would have surfaced. No
fabrication: every value is a byte off the wire; out-of-band values are flagged, not
clamped or invented (project rule — tag 🟢/🟡/🔴).

0x4c record geometry (PROTOCOL.md §5.3, BulkSleep.swift):
  23-byte records, counter [0:4] BE = seconds since 1577793600, epoch step 0x96=150s.
  Layouts keyed structurally:
    idle        : [4:8]=05 00 0c 00, [9]=0a, motion 01x5, [15:22]=00x7  (unworn/charging)
    activity    : [8]=0x12/0x13                                          (awake/active)
    sleepVitals : everything else → HR=[4], HRV=[5], RR=[7]/8, SpO2=[8]
Skin temp / steps are NOT in 0x4c (they ride the 0x10/0x87 descriptor), so they are
not recovered here — they are a live-descriptor metric, not history.

Usage: python3 extract_last_night.py captures/ppg_align_20260616_decoded.txt
"""
from __future__ import annotations
import sys
import statistics
from datetime import datetime, timezone, timedelta

SYNC_EPOCH = 1_577_793_600       # PROTOCOL.md §5.6
REC_LEN = 23
MARKER = 0x0C
# Display in the machine's LOCAL timezone (DST-correct), not a hardcoded offset — a fixed
# UTC-7 mislabels every timestamp by an hour in PST (winter) and can push a late-evening onset
# across midnight onto the wrong calendar night. Counters/spans use raw UTC seconds throughout.
LOCAL = datetime.now().astimezone().tzinfo


def toks_after(line: str, marker: str) -> list[int]:
    if marker not in line:
        return []
    tail = line.split(marker, 1)[1].strip()
    out = []
    for t in tail.split():
        if len(t) == 2:
            try:
                out.append(int(t, 16))
            except ValueError:
                break
        else:
            break
    return out


def page_records(body: list[int]) -> list[list[int]]:
    """[0x4c][00][countdown][N x 23][xor] → list of 23-byte records (0x0c-delimited)."""
    if len(body) < 4 or body[0] != 0x4C:
        return []
    recs = body[3:-1]
    out = []
    for off in range(0, len(recs) - REC_LEN + 1, REC_LEN):
        r = recs[off:off + REC_LEN]
        if r[0] == MARKER:
            out.append(r)
    return out


def layout(r: list[int]) -> str:
    if (r[4] == 0x05 and r[5] == 0x00 and r[6] == 0x0c and r[7] == 0x00 and r[9] == 0x0a
            and r[10:15] == [1, 1, 1, 1, 1] and r[15:22] == [0, 0, 0, 0, 0, 0, 0]):
        return "idle"
    if r[8] in (0x12, 0x13):
        return "activity"
    return "sleepVitals"


def counter(r: list[int]) -> int:
    return (r[0] << 24) | (r[1] << 16) | (r[2] << 8) | r[3]


def decode(r: list[int]) -> dict:
    lay = layout(r)
    d = {"counter": counter(r), "layout": lay}
    if lay == "sleepVitals":
        d["hr"] = r[4] if r[4] > 0 else None
        d["hrv"] = r[5] if r[5] > 0 else None
        d["rr"] = round(r[7] / 8.0, 1) if r[7] > 0 else None
        spo2 = r[8]
        d["spo2"] = spo2 if 70 <= spo2 <= 100 else None
        d["spo2_raw"] = spo2
        d["motion"] = r[10:15]
    return d


def fmt(ts: int) -> str:
    return datetime.fromtimestamp(ts, LOCAL).strftime("%Y-%m-%d %H:%M")


def stat_line(name: str, vals: list[float], unit: str) -> str:
    vals = [v for v in vals if v is not None]
    if not vals:
        return f"  {name:<16} —  (no epochs carried this field)"
    return (f"  {name:<16} n={len(vals):<4} "
            f"min={min(vals):g}  median={statistics.median(vals):g}  max={max(vals):g} {unit}")


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "captures/ppg_align_20260616_decoded.txt"
    records: list[list[int]] = []
    with open(path) as f:
        for line in f:
            if "0x0804 4c " in line:
                records += page_records(toks_after(line, "0x0804"))
    if not records:
        print(f"No 0x4c records in {path}.")
        return

    # Dedup by counter (the same epoch can appear across overlapping app syncs) and order.
    seen, uniq = set(), []
    for r in records:
        c = counter(r)
        if c not in seen:
            seen.add(c)
            uniq.append(r)
    uniq.sort(key=counter)
    decoded = [decode(r) for r in uniq]

    sv = [d for d in decoded if d["layout"] == "sleepVitals"]
    idle = [d for d in decoded if d["layout"] == "idle"]
    act = [d for d in decoded if d["layout"] == "activity"]

    t0, t1 = counter(uniq[0]) + SYNC_EPOCH, counter(uniq[-1]) + SYNC_EPOCH
    print(f"{path}")
    print(f"{len(uniq)} unique 0x4c epochs  ({len(records)} raw, {len(records)-len(uniq)} dup)")
    print(f"span {fmt(t0)} → {fmt(t1)}  ({(t1-t0)/3600:.1f} h of ring history)")
    print(f"layouts: {len(sv)} sleep-vitals · {len(idle)} idle/unworn · {len(act)} activity\n")

    print("Decoded sleep-vitals (🟢 HR/HRV/SpO2/RR per BulkSleep.swift):")
    print(stat_line("Heart rate", [d.get("hr") for d in sv], "bpm"))
    print(stat_line("HRV (RMSSD)", [d.get("hrv") for d in sv], "ms"))
    print(stat_line("SpO2", [d.get("spo2") for d in sv], "%"))
    print(stat_line("Respiratory", [d.get("rr") for d in sv], "brpm"))

    # Physiological sanity (flag, never clamp).
    warns = []
    for d in sv:
        if d.get("hr") and not (30 <= d["hr"] <= 180):
            warns.append(f"HR {d['hr']} @ {fmt(d['counter']+SYNC_EPOCH)}")
        if d.get("spo2_raw") and not (70 <= d["spo2_raw"] <= 100):
            warns.append(f"SpO2_raw {d['spo2_raw']} @ {fmt(d['counter']+SYNC_EPOCH)} (dropped)")
    if warns:
        print(f"\n  ⚠️ {len(warns)} out-of-band readings (flagged, not clamped): " + "; ".join(warns[:6]))

    # Contiguous worn runs (epochs ≤ 2 epochs apart). Report the MOST RECENT substantial run —
    # the tool is "last night," so the longest run ANYWHERE in a multi-week backlog is the wrong
    # answer (an older night could be longer). Also note the longest separately when it differs.
    runs = [r for r in contiguous_runs(sv) if len(r) >= 8]   # ≥ ~20 min worn
    if runs:
        recent = runs[-1]                       # latest in time (sv is sorted)
        longest = max(runs, key=len)
        def report(label: str, run: list[dict]) -> None:
            a, b = run[0]["counter"] + SYNC_EPOCH, run[-1]["counter"] + SYNC_EPOCH
            hrs = [d["hr"] for d in run if d.get("hr")]
            line = f"\n{label}: {fmt(a)} → {fmt(b)}  ({(b-a)/3600:.1f} h, {len(run)} epochs)"
            if hrs:
                line += f"\n  HR {min(hrs)}–{max(hrs)} bpm (median {statistics.median(hrs):g})"
            print(line)
        report("Most recent worn block (≈ last night if the capture ends in the morning)", recent)
        if longest is not recent:
            report("Longest worn block in the capture (an EARLIER night)", longest)
        print("  ↑ this is the kind of sleep data our app dropped while history opened with syncAll.")

    # Sample rows.
    print("\nFirst 8 sleep-vitals epochs:")
    print(f"  {'time':<17}{'HR':>4}{'HRV':>5}{'SpO2':>6}{'RR':>6}  motion")
    for d in sv[:8]:
        print(f"  {fmt(d['counter']+SYNC_EPOCH):<17}"
              f"{(d.get('hr') or '-'):>4}{(d.get('hrv') or '-'):>5}"
              f"{(d.get('spo2') or '-'):>6}{(str(d.get('rr')) if d.get('rr') else '-'):>6}  "
              f"{d.get('motion')}")

    csv = "captures/last_night_extracted.csv"
    with open(csv, "w") as out:
        out.write("utc_iso,local,counter,layout,hr_bpm,hrv_ms,spo2_pct,rr_brpm,motion\n")
        for d in decoded:
            ts = d["counter"] + SYNC_EPOCH
            iso = datetime.fromtimestamp(ts, timezone.utc).isoformat()
            out.write(f"{iso},{fmt(ts)},{d['counter']},{d['layout']},"
                      f"{d.get('hr','')},{d.get('hrv','')},{d.get('spo2','')},"
                      f"{d.get('rr','')},\"{d.get('motion','')}\"\n")
    print(f"\nwrote {csv}")


def contiguous_runs(sv: list[dict], max_gap_epochs: int = 2) -> list[list[dict]]:
    """All runs of sleep-vitals epochs spaced ≤ max_gap_epochs * 150 s apart, in time order."""
    if not sv:
        return []
    runs, cur = [], [sv[0]]
    for prev, d in zip(sv, sv[1:]):
        if d["counter"] - prev["counter"] <= max_gap_epochs * 150:
            cur.append(d)
        else:
            runs.append(cur)
            cur = [d]
    runs.append(cur)
    return runs


if __name__ == "__main__":
    main()
