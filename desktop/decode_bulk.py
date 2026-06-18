#!/usr/bin/env python3
"""Decode the RingConn Gen 2 bulk activity/sleep stream (`0x4c` pages).

Reads the text output of `python -m openringconn decode-log <btsnoop>` and
reassembles the `0x4c` record stream into per-epoch records, converting the
24-bit counter to wall-clock via the §5.6 epoch.

Each 0x4c notification: [0]=0x4c [1]=00 [2]=remaining-record countdown,
then 6 x 23-byte records, then a 1-byte XOR trailer. Records concatenate
across packets (strip the 3-byte header AND the 1-byte trailer per packet).

Record (23 B), confirmed against captures/sleep_sync_btsnoop.log (FR02.018),
aligned to the RingConn app's readout for the 2026-06-13 night. Two layouts,
keyed on [8]:

  Sleep-vitals epoch ([8] in 0x57..0x63):
    [0:4]   BE counter, +0x96 (150 s) per record
    [4]     heart rate (bpm)            CONFIRMED
    [5]     HRV / RMSSD (ms)            CONFIRMED
    [6]     ~1-10, signal quality?      unresolved
    [7]     ~120, pulse amplitude?      unresolved
    [8]     SpO2 (%)                    CONFIRMED
    [9]     ~0x0a                       flag
    [10:15] 5x per-30s motion counts (01 baseline = still)
    [15:22] ~zero during sleep
    [22]    trailer flags

  Activity/awake epoch ([8]=0x12/0x13):
    [4]     heart rate (bpm)   CONFIRMED  <- ALL-DAY HR (same head as sleep-vitals;
            mined 2026-06-17: activity [4] tracks adjacent sleep HR +-4.6 bpm / corr +0.76,
            continuous across layout boundaries). No separate 0x0a HrSync stream exists.
    [10:15] 5x motion counts (elevated when moving)
    [15:22] 7-byte activity/physiology payload (unresolved, #93)

Respiratory rate + skin temp are NOT per-epoch here (derived/summary).
Sleep stages are app-computed from these signals, not stored on the wire.

Usage:
  python -m openringconn decode-log captures/foo.log --addr <mac> > /tmp/dec.txt
  python decode_bulk.py /tmp/dec.txt
"""
import re
import sys
import datetime

EPOCH = 1577793600  # §5.6: 2019-12-31 12:00:00 UTC
RECLEN = 23
STEP = 0x96  # 150 s


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
    """Strip 3-byte header + 1-byte XOR trailer per packet, concat, split to records."""
    stream = b"".join(p[3:-1] for p in payloads)
    return [stream[i:i + RECLEN] for i in range(0, len(stream), RECLEN)
            if len(stream[i:i + RECLEN]) == RECLEN]


def ts(counter):
    return datetime.datetime.utcfromtimestamp(counter + EPOCH)


def is_idle(r):
    return r[10:15] == bytes([1, 1, 1, 1, 1]) and r[15:22] == bytes(7)


def is_sleep_vitals(r):
    return 0x57 <= r[8] <= 0x63


def main(path):
    lines = open(path).read().splitlines()
    recs = reassemble_4c(notif_payloads(lines, 0x4c))
    if not recs:
        print("no 0x4c records found", file=sys.stderr)
        return 1
    print(f"{len(recs)} records ({sum(is_idle(r) for r in recs)} idle)\n")

    # segment into sessions (gap > 600 s)
    prev = None
    seg = []
    sessions = []
    for r in recs:
        c = int.from_bytes(r[0:4], "big")
        if prev is not None and c - prev > 600:
            sessions.append(seg)
            seg = []
        seg.append(r)
        prev = c
    sessions.append(seg)

    for s in sessions:
        c0 = int.from_bytes(s[0][0:4], "big")
        c1 = int.from_bytes(s[-1][0:4], "big")
        worn = sum(1 for r in s if not is_idle(r))
        print(f"== session {ts(c0)} -> {ts(c1)} UTC | {len(s)} epochs, "
              f"{worn} worn / {len(s)-worn} idle ==")
        for r in s:
            c = int.from_bytes(r[0:4], "big")
            mot = r[10:15]
            msum = sum(v for v in mot if v != 1)
            if is_idle(r):
                line = "IDLE"
            elif is_sleep_vitals(r):
                line = f"HR={r[4]:3d}bpm  HRV={r[5]:3d}ms  SpO2={r[8]:2d}%"
            else:
                bar = "#" * min(msum, 40)
                hr = f"HR={r[4]:3d}bpm " if 30 <= r[4] <= 220 else ""        # all-day HR on activity epochs
                line = f"activity {hr}mot={mot.hex()} {bar}"
            print(f"  {ts(c):%H:%M}  {line}")
        print()
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
