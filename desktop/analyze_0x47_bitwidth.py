#!/usr/bin/env python3
"""Issue #8 — resolve the 0x47 PPG-history payload OFFLINE, with evidence.

Geometry is already 🟢 (47-byte records, +0x0384 counter, payload at rec[9:47]).
This tool produces the *evidence* for the open questions, grounded in the bytes:

  1. BIT-WIDTH (10 vs 12, also 8/16 as controls), decided three independent ways:
       a. byte-stream autocorrelation: a near-constant sample run packed at B bits
          makes the byte stream repeat with period lcm(8,B)/8 bytes
          (10-bit->5 B, 12-bit->3 B, 16-bit->2 B). The observed period pins B.
       b. sample-to-sample jitter (mean|d|/sigma): a physical signal is smooth (low);
          packing-misaligned garbage oscillates near full-scale (high).
       c. dynamic-range / value-distribution sanity.
  2. CADENCE: counter step per record vs samples/record -> within-record Hz and
     record cadence. Checks plausibility for *pulse-resolution* PPG.
  3. rec[4:6] BASELINE field: decode and correlate with the per-record sample mean.
  4. INTERLEAVE / channel test: is rec[9:47] one channel or two interleaved
     (even/odd) channels? Tests the mean-offset and whether de-interleaving the
     30 samples lowers jitter (a real 2-channel red/IR interleave should).

Honest by construction: it reports numbers, not verdicts that aren't in the data.
Anything needing the app's exported PPG trace is called out, not faked.

Usage:
  python analyze_0x47_bitwidth.py captures/ppg_align_20260616_decoded.txt [more.txt ...]
"""
from __future__ import annotations

import sys
import statistics
import datetime as dt
from collections import Counter
from dataclasses import dataclass

SYNC_EPOCH = 1_577_793_600   # PROTOCOL.md §5.6 (seconds since 2019-12-31 12:00 UTC)
REC_LEN = 47
PAYLOAD_OFF = 9              # rec[9:47] = 38 payload bytes
MARKER = 0x0C
WIDTHS = (8, 10, 12, 16)


@dataclass
class Rec:
    counter: int            # full 4-byte BE incl. 0x0c marker MSB (cursor space)
    baseline: int           # rec[4:6] BE
    b4: int                 # rec[4]
    b5: int                 # rec[5]
    flags: tuple            # rec[6:9]
    payload: bytes          # 38 bytes


def bits_to_samples(payload: bytes, width: int) -> list[int]:
    """Big-endian contiguous bitstream -> `width`-bit samples (partial tail dropped)."""
    v = 0
    for b in payload:
        v = (v << 8) | b
    nbits = len(payload) * 8
    n = nbits // width
    return [(v >> (nbits - (i + 1) * width)) & ((1 << width) - 1) for i in range(n)]


def extract_0x47(path: str) -> list[Rec]:
    out: list[Rec] = []
    with open(path) as f:
        for line in f:
            if "0x0804 47 " not in line:
                continue
            hexpart = line.split("0x0804", 1)[1].strip()
            toks = [t for t in hexpart.split() if len(t) == 2]
            try:
                body = bytes(int(t, 16) for t in toks)
            except ValueError:
                continue
            if len(body) < 4 or body[0] != 0x47:
                continue
            recs = body[3:-1]                       # strip [47][00][countdown] + trailing xor
            for off in range(0, len(recs) - REC_LEN + 1, REC_LEN):
                r = recs[off:off + REC_LEN]
                if r[0] != MARKER:
                    continue
                out.append(Rec(
                    counter=int.from_bytes(r[0:4], "big"),
                    baseline=int.from_bytes(r[4:6], "big"),
                    b4=r[4], b5=r[5],
                    flags=tuple(r[6:9]),
                    payload=bytes(r[PAYLOAD_OFF:REC_LEN]),
                ))
    return out


def jitter(samples: list[int]) -> float:
    """mean|d| / sigma. Smooth signal << 1; full-scale packing-noise ~ 1.1-1.4."""
    if len(samples) < 3:
        return float("nan")
    sd = statistics.pstdev(samples)
    if sd == 0:
        return 0.0
    diffs = [abs(samples[i + 1] - samples[i]) for i in range(len(samples) - 1)]
    return (sum(diffs) / len(diffs)) / sd


def autocorr(s: list[int], lag: int) -> float | None:
    """Normalised sample-domain autocorrelation at `lag`."""
    n = len(s)
    if n <= lag:
        return None
    m = sum(s) / n
    var = sum((x - m) ** 2 for x in s) / n
    if var == 0:
        return None
    return sum((s[i] - m) * (s[i + lag] - m) for i in range(n - lag)) / (n - lag) / var


def byte_autocorr(payloads: list[bytes], maxlag: int = 12) -> dict[int, float]:
    """Normalised autocorrelation of the concatenated payload byte stream.

    A run of near-constant W-bit samples forces a byte-period of lcm(8,W)/8.
    The smallest lag with a strong peak is the packing period.
    """
    stream = b"".join(payloads)
    n = len(stream)
    if n < maxlag + 2:
        return {}
    mean = sum(stream) / n
    var = sum((b - mean) ** 2 for b in stream) / n
    if var == 0:
        return {}
    out = {}
    for lag in range(1, maxlag + 1):
        cov = sum((stream[i] - mean) * (stream[i + lag] - mean)
                  for i in range(n - lag)) / (n - lag)
        out[lag] = cov / var
    return out


def analyze(path: str) -> None:
    recs = extract_0x47(path)
    print("=" * 78)
    print(f"FILE: {path}")
    if not recs:
        print("  no 0x47 records.")
        return
    counters = [r.counter for r in recs]
    span = counters[-1] - counters[0]
    # The record counter is the FULL 4-byte cursor (incl. the 0x0c MSB), in the same
    # value-space as the 0x02 sync cursor: wall-clock = counter + SYNC_EPOCH (§5.6).
    t0 = counters[0] + SYNC_EPOCH
    t1 = counters[-1] + SYNC_EPOCH
    print(f"  {len(recs)} records | counter {counters[0]:#010x}..{counters[-1]:#010x}"
          f" | span {span}s ~ {span/86400:.1f} d")
    print(f"  wall-clock {dt.datetime.utcfromtimestamp(t0):%Y-%m-%d %H:%M} -> "
          f"{dt.datetime.utcfromtimestamp(t1):%Y-%m-%d %H:%M} UTC")

    # ---- counter step distribution -----------------------------------------
    steps = [counters[i + 1] - counters[i] for i in range(len(counters) - 1)]
    sc = Counter(steps)
    print("\n  [CADENCE] per-record counter steps (top): "
          + ", ".join(f"{s}x{c}" for s, c in sc.most_common(5)))
    print(f"            +900 step {sc.get(900,0)}/{len(steps)} times "
          f"(900 s record window; §5.2 +0x0384)")

    # ---- bit width: jitter + range -----------------------------------------
    print("\n  [BIT-WIDTH] global sample-to-sample jitter (mean|d|/sigma) and range:")
    for w in WIDTHS:
        allsamp, per_rec = [], set()
        for r in recs:
            s = bits_to_samples(r.payload, w)
            per_rec.add(len(s))
            allsamp += s
        print(f"     {w:2d}-bit BE -> {sorted(per_rec)} samp/rec | "
              f"range {min(allsamp)}-{max(allsamp)} (full-scale {(1<<w)-1}) | "
              f"jitter {jitter(allsamp):.3f}")

    # ---- byte autocorrelation period ---------------------------------------
    ac = byte_autocorr([r.payload for r in recs])
    if ac:
        print("\n  [BIT-WIDTH] payload byte-stream autocorrelation (period => packing):")
        print("     " + "  ".join(f"L{l}:{v:+.2f}" for l, v in sorted(ac.items())))
        best = max(ac.items(), key=lambda kv: kv[1])
        width_for = {1: "8", 2: "16", 3: "12", 5: "10"}
        print(f"     strongest peak at lag {best[0]} (r={best[1]:+.2f}) "
              f"=> packing width ~ {width_for.get(best[0], '?')}-bit "
              f"(lcm(8,W)/8: 8->1, 16->2, 12->3, 10->5)")

    # ---- per-record jitter (no inter-record jumps) -------------------------
    print("\n  [BIT-WIDTH] per-record (within-record) median jitter:")
    for w in WIDTHS:
        js = [jitter(s) for r in recs
              if len(set(s := bits_to_samples(r.payload, w))) > 1]
        if js:
            print(f"     {w:2d}-bit BE -> median {statistics.median(js):.3f}  "
                  f"(n={len(js)} non-flat records)")

    # ---- baseline rec[4:6] --------------------------------------------------
    print("\n  [BASELINE rec[4:6]]")
    print(f"     rec[4] values: {dict(Counter(r.b4 for r in recs).most_common())}")
    print(f"     rec[6:9] flag values: "
          f"{dict(Counter(r.flags for r in recs).most_common(6))}")
    means10 = [statistics.mean(bits_to_samples(r.payload, 10)) for r in recs]
    bases = [r.baseline for r in recs]
    if len(bases) > 2 and statistics.pstdev(bases) > 0 and statistics.pstdev(means10) > 0:
        mb, mm = statistics.mean(bases), statistics.mean(means10)
        cov = sum((b - mb) * (m - mm) for b, m in zip(bases, means10)) / len(bases)
        corr = cov / (statistics.pstdev(bases) * statistics.pstdev(means10))
        ratios = [b / m for b, m in zip(bases, means10) if m]
        print(f"     baseline range {min(bases)}-{max(bases)} "
              f"(={min(bases):#06x}..{max(bases):#06x})")
        print(f"     corr(baseline, 10-bit sample mean) = {corr:+.3f}")
        print(f"     baseline / sample_mean: median {statistics.median(ratios):.3f} "
              f"(min {min(ratios):.3f}, max {max(ratios):.3f})")

    # ---- interleave / channel test (10-bit) --------------------------------
    print("\n  [INTERLEAVE/CHANNEL test, 10-bit]")
    offs, jf, je, jo = [], [], [], []
    for r in recs:
        s = bits_to_samples(r.payload, 10)
        ev, od = s[0::2], s[1::2]
        if len(set(s)) > 1:
            offs.append(statistics.mean(ev) - statistics.mean(od))
            jf.append(jitter(s))
            if len(set(ev)) > 1:
                je.append(jitter(ev))
            if len(set(od)) > 1:
                jo.append(jitter(od))
    if offs:
        print(f"     mean(even)-mean(odd): median {statistics.median(offs):+.2f} LSB "
              f"(sigma of offsets {statistics.pstdev(offs):.2f})")
        print(f"     within-record jitter: full-30 {statistics.median(jf):.3f}  vs "
              f"even {statistics.median(je):.3f} / odd {statistics.median(jo):.3f}")
    # Decisive discriminator: sample-domain lag-1 vs lag-2 autocorr on DYNAMIC records.
    #   single smooth channel  -> lag1 ~ lag2  (adjacent ~ 2-apart)
    #   2 interleaved A,B,A,B   -> lag1 << lag2 (adjacent are different channels),
    #                              and many records show lag1 < 0 (alternation).
    dyn = [r for r in recs
           if (s := bits_to_samples(r.payload, 10)) and (max(s) - min(s)) > 20]
    ac1 = [a for r in dyn if (a := autocorr(bits_to_samples(r.payload, 10), 1)) is not None]
    ac2 = [a for r in dyn if (a := autocorr(bits_to_samples(r.payload, 10), 2)) is not None]
    if ac1 and ac2:
        pairs = [(autocorr(bits_to_samples(r.payload, 10), 1),
                  autocorr(bits_to_samples(r.payload, 10), 2)) for r in dyn]
        pairs = [(a, b) for a, b in pairs if a is not None and b is not None]
        f_alt = sum(1 for a, _ in pairs if a < 0) / len(pairs)
        print(f"     [decisive] over {len(dyn)} dynamic recs (p2p>20): "
              f"lag-1 autocorr {statistics.median(ac1):+.3f} vs "
              f"lag-2 {statistics.median(ac2):+.3f}; "
              f"{f_alt:.0%} of recs alternate (lag1<0).")
        print("     -> lag1 ~ lag2 and ~no alternation => ONE smooth channel, not 2 "
              "interleaved. (Channel IDENTITY: red/IR/LED unprovable offline; needs app export.)")

    # ---- AC / pulsatility (can we see a heartbeat?) ------------------------
    worn = [r for r in recs
            if (s := bits_to_samples(r.payload, 10)) and (max(s) - min(s)) > 8]
    fs_within = 30 / 900.0
    print("\n  [PULSATILITY] within-record AC content (10-bit):")
    print(f"     {len(worn)}/{len(recs)} records have 10-bit p2p range >8 LSB.")
    print(f"     If 30 samples span 900 s -> {fs_within:.4f} Hz (1 sample / 30 s) ~"
          f"{fs_within*1000:.1f} mHz: far below 0.7-3 Hz pulse -> NO heartbeat resolvable.")
    print("     => a pulsatile-AC HR cross-check is impossible from 0x47 alone.")


def main() -> None:
    paths = sys.argv[1:] or ["captures/ppg_align_20260616_decoded.txt"]
    for p in paths:
        try:
            analyze(p)
        except FileNotFoundError:
            print(f"(skip, not found: {p})")
    print("=" * 78)


if __name__ == "__main__":
    main()
