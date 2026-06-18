#!/usr/bin/env python3
"""Decode the RingConn Gen 2 bulk PPG stream (`0x47` pages).

Reads the text output of `python -m openringconn decode-log <btsnoop>` and
reassembles the `0x47` record stream into 10-bit PPG samples.

A 0x47 page: [0]=0x47 [1]=00 [2]=remaining-record countdown, then N×47-byte
records, then a 1-byte XOR trailer. Strip the 3-byte header AND the 1-byte
trailer per page; records do not span pages.

Record (47 B), confirmed against captures/sleep_sync_btsnoop.log (FR02.018):
  [0:4]   BE counter, +0x0384 (900 s) per record
  [4:6]   16-bit BE optical baseline/DC ([4] in {0x02,0x03}, NOT const; [5] drifts)
  [6:9]   usually 00 00 00 (per-record flags/quality)
  [9:47]  38 B = 30 × 10-bit big-endian samples (+ 4 zero pad-bits). 10-bit is proven
          3 ways (jitter, lag-5 byte autocorrelation, range) — see issue #8 /
          desktop/analyze_0x47_bitwidth.py. NOTE: the samples are ONE smooth optical
          channel (lag-1 ~ lag-2 sample autocorrelation), NOT two interleaved red/IR
          channels — that earlier claim is RETRACTED. The even/odd split below is kept
          only as a display aid; it does NOT correspond to two physical channels.

Usage:
  python -m openringconn decode-log captures/foo.log --addr <mac> > /tmp/dec.txt
  python decode_ppg.py /tmp/dec.txt
"""
import re
import sys
import datetime

EPOCH = 1577793600  # §5.6
RECLEN = 47
SAMPLE_BITS = 10
N_SAMPLES = 30


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


def reassemble_47(payloads):
    stream = b"".join(p[3:-1] for p in payloads)
    return [stream[i:i + RECLEN] for i in range(0, len(stream), RECLEN)
            if len(stream[i:i + RECLEN]) == RECLEN]


def samples(record):
    """30 × 10-bit big-endian samples from record[9:47]."""
    val = 0
    for byte in record[9:47]:
        val = (val << 8) | byte
    nbits = (RECLEN - 9) * 8
    return [(val >> (nbits - (i + 1) * SAMPLE_BITS)) & 0x3FF for i in range(N_SAMPLES)]


def ts(counter):
    return datetime.datetime.utcfromtimestamp(counter + EPOCH)


def main(path):
    lines = open(path).read().splitlines()
    recs = reassemble_47(notif_payloads(lines, 0x47))
    if not recs:
        print("no 0x47 records found", file=sys.stderr)
        return 1
    print(f"{len(recs)} PPG records "
          f"({ts(int.from_bytes(recs[0][0:4], 'big')):%Y-%m-%d %H:%M} → "
          f"{ts(int.from_bytes(recs[-1][0:4], 'big')):%Y-%m-%d %H:%M} UTC)\n")
    for r in recs:
        c = int.from_bytes(r[0:4], "big")
        s = samples(r)
        rng = max(s) - min(s)
        chA, chB = s[0::2], s[1::2]   # display aid only — NOT two physical channels (see header)
        flag = "" if rng > 5 else "  (flat/idle)"
        print(f"{ts(c):%m-%d %H:%M}  base={r[4:6].hex()} range={rng:4d}{flag}")
        if rng > 5:
            print(f"           even: {chA}")
            print(f"           odd : {chB}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
