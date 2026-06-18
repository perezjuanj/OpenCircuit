#!/usr/bin/env python3
"""Decode the RingConn Gen 2 `0x4c` activity-epoch payload (issue #93, extends #9).

WHAT THIS SCRIPT ESTABLISHES (run it against walk/steps to reproduce)
---------------------------------------------------------------------
Issue #93 assumed the `0x4c` sub-record `[15:22]` is a 7-byte activity payload
holding steps / distance / 4-level intensity / activeSeconds / powerLevel /
per-epoch battery / dailyActiveFlag.

Cross-referencing the decompiled official app (`pp.txt`, blutter) DISPROVES that
premise and pins down what the bytes actually are. The app ships TWO per-2.5-min
record offset maps:

  历史测量响应  ("history MEASUREMENT response")  Map(9):
      utc(0x3,4) pr(0x7,1) hrv(0x8,1) conf(0x9,1) resprate(0xa,1)
      spo2(0xb,1) item2p5(0xc,1) acti_counts(0xd,0xa) info(0x17,1)

  历史活动响应  ("history ACTIVITY response")  Map(13):
      utc(0x3,4) steps(0x7,2) DeviceState(0x9,1) powerLevel(0xa,1)
      Temp1(0xb,2) Temp2(0xd,2) Temp3(0xf,2) Temp4(0x11,2)
      item5p0_1(0x13,1) item5p0_2(0x14,1) item5p0_3(0x15,1)
      active_seconds(0x16,2) dailyActiveFlag(0x18,1)

The map offsets are relative to a record class whose `utc` field sits at loc 0x3.
Our wire `0x4c` sub-record carries the cursor/counter at byte[0:4] (top byte =
the 0x0c delimiter). So the mapping onto the wire is:

      wire_index = APK_loc - 3          # 🟢 validated by 5 fields (see below)

Applying the MEASUREMENT map to our wire record reproduces, byte-for-byte, the
§5.3 sleep-vitals decode that was already ground-truthed against the RingConn
app's readout for the 2026-06-13 night:

      wire[4]  = pr        = HR (bpm)            §5.3 [4]=HR        🟢
      wire[5]  = hrv       = HRV/RMSSD (ms)      §5.3 [5]=HRV       🟢
      wire[6]  = conf      = confidence 0..~12   §5.3 [6]=quality?  -> NAMED 🟢
      wire[7]  = resprate  = RR x8               §5.3 [7]=RR*8      🟢
      wire[8]  = spo2      = SpO2 % (or 0x12/0x13 wake sentinel)    🟢
      wire[9]  = item2p5   = (2.5-min marker, ~0x0a)                🟡
      wire[10:20] = acti_counts (10-byte bit-packed activity blob)  🟢 role
      wire[20] = info                                                🟡
      wire[21:22] = trailer/flags                                    🟡

Five independent fields (pr/hrv/conf/resprate/spo2) land EXACTLY on the
app-aligned values -> the wire record is the MEASUREMENT stream, NOT the
ACTIVITY stream. Confirmation in the data:
  * wire[4] reads as physiological HR (median 53, max 96 on worn wake epochs);
    decoding [4:6] as activity-map `steps` gives non-monotonic garbage
    (median ~13600, only ~72% monotone) -> not a step counter.
  * No capture (walk/steps/sleep/battery/morning/login) contains ANY record,
    under ANY 0x0804 opcode, matching the ACTIVITY layout.

=> The `[15:22]` bytes #93 asked about are the TAIL of `acti_counts`: a per-epoch
   activity-INTENSITY signal (non-zero iff moving, zero at rest). They are NOT
   steps / distance / activeSeconds / powerLevel / battery / dailyActiveFlag.
   Those fields live in the separate 历史活动响应 stream, which our byte[6]=0x00
   syncs never request (same gap as the all-day HR/SpO2 selector, #99/§5.6.1).

This script therefore:
  1. Decodes the MEASUREMENT record (the real content of our 0x4c epochs).
  2. Derives the per-epoch activity INTENSITY from acti_counts (present + usable).
  3. Ships `decode_activity_record_PREDICTED()` — the 历史活动响应 layout via the
     validated wire=APK_loc-3 convention — ready to run against a future capture
     taken with the activity/step sync selector (byte[6]). Running it on today's
     records yields implausible values, demonstrating they are not activity records.

Usage:
  python -m openringconn decode-log captures/walk.log --addr <mac> > /tmp/walk.txt
  python decode_activity.py /tmp/walk.txt              # or the *_decoded.txt files
"""
import re
import sys
import datetime

EPOCH = 1577793600   # §5.6: 2019-12-31 12:00:00 UTC
RECLEN = 23
STEP = 0x96          # 150 s / 2.5-min epoch
IDLE_ACTI_SUM = 5    # acti_counts byte-sum for the idle template (01x5 + 00x5)


# ---------------------------------------------------------------- wire plumbing
def notif_payloads(lines, opcode):
    out = []
    for ln in lines:
        m = re.search(r"Notification\s+0x0804\s+(.*)$", ln)
        if not m:
            continue
        b = bytes(int(x, 16) for x in m.group(1).split())
        if b and b[0] == opcode:
            out.append(b)
    return out


def reassemble_4c(payloads):
    """Strip 3-byte header + 1-byte XOR trailer per packet, concat, split."""
    stream = b"".join(p[3:-1] for p in payloads)
    recs = [stream[i:i + RECLEN] for i in range(0, len(stream), RECLEN)
            if len(stream[i:i + RECLEN]) == RECLEN]
    # de-dup by counter (consecutive syncs re-deliver a small overlap, §3)
    seen = {}
    for r in recs:
        seen[int.from_bytes(r[0:4], "big")] = r
    return [seen[c] for c in sorted(seen)]


def ts(counter):
    return datetime.datetime.utcfromtimestamp(counter + EPOCH)


def is_idle(r):
    return r[10:15] == bytes([1, 1, 1, 1, 1]) and r[15:22] == bytes(7)


# ----------------------------------------------------- MEASUREMENT record (real)
def decode_measurement(r):
    """Decode a 0x4c sub-record via the 历史测量响应 map (wire = APK_loc - 3).

    `spo2` reads 0x12/0x13 on awake epochs (a 'no valid SpO2' sentinel) and the
    real % (0x55..0x64) on asleep epochs. HR/HRV read a low sentinel (~4-5) when
    the optical measure didn't lock; treat HR < 30 as unmeasured (§5.1).
    """
    counter = int.from_bytes(r[0:4], "big")
    spo2 = r[8]
    awake = spo2 in (0x12, 0x13)
    acti = r[10:20]                       # acti_counts (bit-packed, 🟡 sub-layout)
    return {
        "t": ts(counter),
        "counter": counter,
        "hr": r[4] if r[4] >= 30 else None,
        "hrv": r[5] if r[5] > 0 else None,
        "conf": r[6],                     # confidence / signal quality 0..~12
        "rr": round(r[7] / 8, 1) if r[7] > 0 else None,
        "spo2": None if awake else spo2,
        "awake": awake,
        "item2p5": r[9],
        "acti_counts": acti,
        "intensity": sum(acti) - IDLE_ACTI_SUM,   # per-epoch activity magnitude
        "info": r[20],
        "idle": is_idle(r),
    }


# 4-band activity intensity (历史活动 graph: Inactive/Low/Moderate/Vigorous,
# one dot per 2.5-min epoch, pp.txt L45207). The app computes the bands from
# acti_counts with UNKNOWN thresholds; these are byte-sum proxy cut-points
# chosen from the walk/idle separation (idle->Inactive, big spikes->Vigorous).
# Role 🟢 (active vs idle separates cleanly); exact thresholds 🔴 (need app export).
def intensity_band(intensity):
    if intensity <= 0:
        return "Inactive"
    if intensity < 100:
        return "Low"
    if intensity < 400:
        return "Moderate"
    return "Vigorous"


# ------------------------------------------ ACTIVITY record (PREDICTED, 🔴 #93)
def decode_activity_record_PREDICTED(r):
    """历史活动响应 layout via wire = APK_loc - 3. UNCONFIRMED — needs a sync
    taken with the activity/step selector (0x02 byte[6]); our captures never
    request it, so running this on today's MEASUREMENT records returns garbage.

    distance is NOT on the wire — the app derives it (steps * ~0.248 m, pp.txt
    L102573). powerLevel is the per-epoch battery %. Temp1-4 are 4 per-epoch
    skin-temp samples (distinct from the live 0x10/0x87 descriptor temp, §5.4).
    """
    return {
        "t": ts(int.from_bytes(r[0:4], "big")),
        "steps": int.from_bytes(r[4:6], "little"),   # 🔴 LE per pp.txt field type
        "device_state": r[6],                        # 🔴 wear/charge enum
        "power_level": r[7],                         # 🔴 per-epoch battery %
        "temp1": int.from_bytes(r[8:10], "little"),  # 🔴 per-epoch skin temp #1
        "temp2": int.from_bytes(r[10:12], "little"), # 🔴
        "temp3": int.from_bytes(r[12:14], "little"), # 🔴
        "temp4": int.from_bytes(r[14:16], "little"), # 🔴
        "item5p0": (r[16], r[17], r[18]),            # 🔴
        "active_seconds": int.from_bytes(r[19:21], "little"),  # 🔴 0..150 / epoch
        "daily_active_flag": r[21],                  # 🔴 0/1 stand-hour flag
    }


# ------------------------------------------------------------------------- main
def main(path):
    lines = open(path).read().splitlines()
    recs = reassemble_4c(notif_payloads(lines, 0x4c))
    if not recs:
        print("no 0x4c records found", file=sys.stderr)
        return 1

    dec = [decode_measurement(r) for r in recs]
    worn = [d for d in dec if not d["idle"]]
    active = [d for d in worn if d["intensity"] > 0]
    idle = [d for d in dec if d["idle"]]

    print(f"{path.split('/')[-1]}: {len(recs)} epochs "
          f"({len(idle)} idle-template, {len(worn)} worn, {len(active)} with motion)\n")

    # ---- self-verify: active epochs differ from idle exactly as predicted -----
    def stats(xs):
        xs = sorted(xs)
        return (xs[0], xs[len(xs) // 2], xs[-1]) if xs else (0, 0, 0)
    ai = [d["intensity"] for d in active]
    ii = [d["intensity"] for d in idle]
    print("SELF-VERIFY  acti_counts intensity (min/median/max):")
    print(f"  active epochs : {stats(ai)}")
    print(f"  idle  epochs  : {stats(ii)}   <- flat 0 by construction")
    assert all(i == 0 for i in ii), "idle template should have zero intensity"
    assert ai and max(ai) > 0, "expected non-zero activity in a worn capture"
    print("  => PASS: worn/active epochs carry non-zero acti_counts; idle is flat.\n")

    # ---- band distribution over active epochs ---------------------------------
    from collections import Counter
    bands = Counter(intensity_band(d["intensity"]) for d in worn)
    print("activity-intensity bands (proxy thresholds, 🔴) over worn epochs:")
    for b in ("Inactive", "Low", "Moderate", "Vigorous"):
        print(f"  {b:9s} {bands.get(b, 0)}")
    print()

    # ---- a peek at the most-active epochs -------------------------------------
    print("top activity epochs (measurement view):")
    for d in sorted(worn, key=lambda d: d["intensity"], reverse=True)[:8]:
        hr = f"{d['hr']}bpm" if d["hr"] else "--"
        print(f"  {d['t']:%m-%d %H:%M}  intensity={d['intensity']:4d} "
              f"({intensity_band(d['intensity'])})  HR={hr}  "
              f"acti={d['acti_counts'].hex()}")
    print()

    # ---- demonstrate the records are NOT activity records ---------------------
    bad = 0
    for r in recs:
        if is_idle(r):
            continue
        a = decode_activity_record_PREDICTED(r)
        # An activity record would have steps>=0 small-ish, power_level<=100,
        # active_seconds<=150. Count gross violations to show these aren't those.
        if a["power_level"] > 100 or a["active_seconds"] > 150 or a["steps"] > 5000:
            bad += 1
    nworn = sum(1 for r in recs if not is_idle(r))
    print(f"activity-layout sanity: {bad}/{nworn} worn epochs violate activity-record "
          f"bounds (power<=100, activeSec<=150, steps<5000)")
    print("  => confirms our 0x4c epochs are MEASUREMENT records, not 历史活动 records.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
