"""#61 — find the charging/worn state byte in the 0x10/0x87 descriptor.

Capture sequence (ground truth, labeled by the maintainer):
  finger (worn) -> charger -> off charger (off-wrist idle) -> finger (worn)

Method: we don't have exact transition wall-clock times, so we *derive* the true
state of every descriptor frame from two already-decoded fields and then look for
the unknown byte that partitions along that derived state:
  - battery [1] strictly rising  => CHARGING   (the confirmed indirect signal)
  - temp mean ([6:8]/[8:10]) warm => WORN, cold => OFF-WRIST

Then we print, for each candidate byte ([2], [15], [16], [17], [18], [11..14]),
its value distribution within each derived state. The byte whose value is
constant-and-distinct per state is the charging/worn enum (#61 acceptance).

Usage: python analyze_state_byte.py <btsnoop.log>
"""

from __future__ import annotations

import sys
from collections import Counter, defaultdict

from opencircuit.sniff import _iter_att

WARM_C = 28.0  # >= worn (matches ActivityPeriod.wornMinTemperatureC)


def temp_mean(f: bytes):
    a = (f[6] << 8) | f[7]
    b = (f[8] << 8) | f[9]
    if not (150 <= a <= 500 and 150 <= b <= 500):
        return None
    return (a + b) / 20.0  # mean of two 0.1C channels -> C


def main(path: str) -> None:
    frames = []  # (ts, payload)
    for ev in _iter_att(path_blob(path)):
        if ev.opcode in (0x1B, 0x1D) and ev.value and ev.value[0] in (0x10, 0x87) and len(ev.value) >= 19:
            frames.append((ev.ts_unix, ev.value))

    print(f"{len(frames)} descriptor (0x10/0x87) frames\n")
    if not frames:
        return

    # battery trend for charging inference (rising = charging)
    rows = []
    prev_batt = None
    for ts, f in frames:
        batt = f[1]
        t = temp_mean(f)
        rising = prev_batt is not None and batt > prev_batt
        rows.append({"ts": ts, "batt": batt, "temp": t, "rising": rising, "f": f})
        prev_batt = batt

    # smoothed charging label: a frame is "charging" if battery rose within a short
    # forward/backward window (battery ticks up coarsely, not every frame).
    n = len(rows)
    for i, r in enumerate(rows):
        window = rows[max(0, i - 4): min(n, i + 5)]
        b0, b1 = window[0]["batt"], window[-1]["batt"]
        r["charging"] = b1 > b0
        if r["temp"] is None:
            r["worn"] = None
        else:
            r["worn"] = r["temp"] >= WARM_C

    def state(r):
        if r["charging"]:
            return "CHARGING"
        if r["worn"] is True:
            return "WORN"
        if r["worn"] is False:
            return "OFFWRIST"
        return "UNKNOWN"

    # ---- timeline (downsampled) ----
    print("=== timeline (every ~Nth frame) ===")
    print(f"{'time':<13}{'batt':<5}{'temp':<7}{'state':<10}"
          f"{'[2]':<5}{'[11]':<6}{'[12]':<6}{'[13]':<6}{'[14]':<6}{'[15]':<6}{'[16]':<6}{'[17]':<6}{'[18]':<6}")
    step = max(1, n // 80)
    from datetime import datetime, timezone
    for i in range(0, n, step):
        r = rows[i]
        f = r["f"]
        ts = datetime.fromtimestamp(r["ts"], tz=timezone.utc).strftime("%H:%M:%S")
        tp = f"{r['temp']:.1f}" if r["temp"] is not None else "--"
        print(f"{ts:<13}{r['batt']:<5}{tp:<7}{state(r):<10}"
              + "".join(f"{f[j]:02x}   " for j in (2, 11, 12, 13, 14, 15, 16, 17, 18)))

    # ---- per-state byte distributions ----
    print("\n=== candidate byte value distribution per derived state ===")
    candidates = [2, 11, 12, 13, 14, 15, 16, 17, 18]
    by_state = defaultdict(list)
    for r in rows:
        by_state[state(r)].append(r["f"])

    for j in candidates:
        print(f"\n  byte[{j}]:")
        for st in ("WORN", "CHARGING", "OFFWRIST", "UNKNOWN"):
            fs = by_state.get(st)
            if not fs:
                continue
            c = Counter(f[j] for f in fs)
            dist = " ".join(f"{v:02x}×{n}" for v, n in c.most_common(6))
            print(f"    {st:<10} n={len(fs):<5} {dist}")

    # ---- which byte best separates states? ----
    print("\n=== separation score (lower entropy within state + distinct across = better) ===")
    states_present = [s for s in ("WORN", "CHARGING", "OFFWRIST") if by_state.get(s)]
    for j in candidates:
        modes = {}
        pure = True
        for st in states_present:
            c = Counter(f[j] for f in by_state[st])
            mode, cnt = c.most_common(1)[0]
            purity = cnt / len(by_state[st])
            modes[st] = (mode, purity)
            if purity < 0.8:
                pure = False
        distinct = len({m for m, _ in modes.values()}) == len(modes)
        flag = "  <== CANDIDATE" if (pure and distinct and len(modes) >= 2) else ""
        ms = " ".join(f"{st}={m:02x}({p:.0%})" for st, (m, p) in modes.items())
        print(f"  byte[{j}]: {ms}{flag}")


def path_blob(path: str):
    # _iter_att takes a blob in this codebase version? No—it takes bytes. Read file.
    with open(path, "rb") as fh:
        return fh.read()


if __name__ == "__main__":
    main(sys.argv[1])
