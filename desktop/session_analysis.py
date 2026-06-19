"""Session-boundary analysis for #61 (charging/worn state byte).

The ring drops BLE on the charger, so the descriptor stream has GAPS. We split
frames into sessions (gap > GAP_S), then for each session ask the decisive
question: did the battery RISE across the preceding gap? If yes, the ring was
*charging* during that gap. We then compare the opening bytes of post-charge
sessions vs post-idle-disconnect sessions to see whether any descriptor byte
encodes "just came off charger" / charging state.
"""
from __future__ import annotations
import sys
from datetime import datetime, timezone
from collections import Counter
from opencircuit.sniff import _iter_att

GAP_S = 120

def temp_mean(f):
    a = (f[6] << 8) | f[7]; b = (f[8] << 8) | f[9]
    if not (150 <= a <= 500 and 150 <= b <= 500):
        return None
    return (a + b) / 20.0

def hhmm(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%m-%d %H:%M:%S")

def main(path):
    with open(path, "rb") as fh:
        blob = fh.read()
    frames = [(ev.ts_unix, ev.value) for ev in _iter_att(blob)
              if ev.opcode in (0x1B, 0x1D) and ev.value and ev.value[0] in (0x10, 0x87)
              and len(ev.value) >= 19]
    frames.sort(key=lambda r: r[0])

    # split into sessions
    sessions = []
    cur = [frames[0]]
    for prev, nxt in zip(frames, frames[1:]):
        if nxt[0] - prev[0] > GAP_S:
            sessions.append(cur); cur = []
        cur.append(nxt)
    sessions.append(cur)

    print(f"{len(frames)} frames -> {len(sessions)} sessions (gap>{GAP_S}s)\n")
    print(f"{'#':<3}{'start':<15}{'dur':<7}{'n':<5}{'batt':<10}{'Δgap':<6}{'temp0':<7}"
          f"{'[14]':<6}{'opening [2] seq':<26}{'[16]nz'}")
    print("-" * 110)
    prev_end_batt = None
    for i, s in enumerate(sessions):
        b0, bN = s[0][1][1], s[-1][1][1]
        dur = s[-1][0] - s[0][0]
        dgap = "" if prev_end_batt is None else f"{b0 - prev_end_batt:+d}"
        t0 = temp_mean(s[0][1]); t0s = f"{t0:.1f}" if t0 else "--"
        seq = " ".join(f"{f[1][2]:02x}" for f in s[:10])
        b16 = Counter(f[1][16] for f in s if f[1][16] != 0)
        b16s = " ".join(f"{v:02x}×{n}" for v, n in b16.most_common(4)) or "-"
        b14 = s[0][1][14]
        flag = ""
        if prev_end_batt is not None and b0 - prev_end_batt >= 2:
            flag = "  <<CHARGED in prev gap"
        print(f"{i:<3}{hhmm(s[0][0]):<15}{dur:5.0f}s {len(s):<5}{b0}->{bN:<6}{dgap:<6}"
              f"{t0s:<7}{b14:02x}    {seq:<26}{b16s}{flag}")
        prev_end_batt = bN

    # aggregate: opening [2] multiset for charged-gap vs idle-gap sessions
    print("\n=== opening-frame byte profile: charged-gap vs idle-gap sessions ===")
    charged_open2, idle_open2 = Counter(), Counter()
    charged_t0, idle_t0 = [], []
    prev_end = None
    for s in sessions:
        b0 = s[0][1][1]
        opens2 = [f[1][2] for f in s[:5]]
        t0 = temp_mean(s[0][1])
        if prev_end is not None:
            if b0 - prev_end >= 2:
                charged_open2.update(opens2)
                if t0: charged_t0.append(t0)
            else:
                idle_open2.update(opens2)
                if t0: idle_t0.append(t0)
        prev_end = s[-1][1][1]
    print(f"  charged-gap sessions, opening [2]: {dict(charged_open2)}")
    print(f"  idle-gap   sessions, opening [2]: {dict(idle_open2)}")
    if charged_t0:
        print(f"  charged-gap opening temp: min {min(charged_t0):.1f} max {max(charged_t0):.1f} "
              f"mean {sum(charged_t0)/len(charged_t0):.1f}")
    if idle_t0:
        print(f"  idle-gap   opening temp: min {min(idle_t0):.1f} max {max(idle_t0):.1f} "
              f"mean {sum(idle_t0)/len(idle_t0):.1f}")

if __name__ == "__main__":
    main(sys.argv[1])
