"""Dump the most-recent descriptor frames, time-sorted, full bytes.

The btsnoop buffer holds days of data out of order; the maintainer's labeled
finger->charger->off-charger->finger test is the LATEST wall-clock window.
We sort by timestamp and print the tail at full resolution so the 4 phases
(warm/steady, cold/rising-batt, cold/steady, warm/steady) are visible.
"""
from __future__ import annotations
import sys
from datetime import datetime, timezone
from opencircuit.sniff import _iter_att

def temp_mean(f):
    a = (f[6] << 8) | f[7]; b = (f[8] << 8) | f[9]
    if not (150 <= a <= 500 and 150 <= b <= 500):
        return None
    return (a + b) / 20.0

def main(path, tail=90):
    with open(path, "rb") as fh:
        blob = fh.read()
    frames = [(ev.ts_unix, ev.value, ev.opcode, ev.att_handle)
              for ev in _iter_att(blob)
              if ev.opcode in (0x1B, 0x1D) and ev.value and ev.value[0] in (0x10, 0x87)
              and len(ev.value) >= 19]
    frames.sort(key=lambda r: r[0])
    print(f"{len(frames)} descriptor frames, showing last {tail} (time-sorted)\n")
    hdr = "time(UTC)     resp batt [2] temp   " + " ".join(f"[{i}]" for i in range(10, 19))
    print(hdr); print("-" * len(hdr))
    prev_b = None
    for ts, f, op, h in frames[-tail:]:
        t = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%H:%M:%S")
        tm = temp_mean(f)
        tms = f"{tm:4.1f}" if tm is not None else "  --"
        arrow = ""
        if prev_b is not None:
            if f[1] > prev_b: arrow = "^"
            elif f[1] < prev_b: arrow = "v"
        prev_b = f[1]
        rest = " ".join(f"{f[i]:02x}" for i in range(10, 19))
        print(f"{t}     {f[0]:02x}   {f[1]:3d}{arrow:1} {f[2]:02x}  {tms}   {rest}")

if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 90)
