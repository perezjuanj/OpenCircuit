#!/usr/bin/env python3
"""Record the ring's 100 Hz raw pulse waveform, and pair it with a cuff reading.

    python3 bp_collect.py                    # 45 s capture, then asks for your cuff numbers
    python3 bp_collect.py --seconds 60
    python3 bp_collect.py --replay <btsnoop> # offline: decode a capture, no radio, no ring

WHAT THIS IS FOR
  Blood-pressure calibration data. RingConn computes their BP number on their servers, so
  there is nothing to copy off the wire — but the raw optical signal it is computed FROM
  travels over Bluetooth, and that is what a cuffless estimate is actually built on. What
  turns that signal into a reading is pairs of (waveform, real cuff reading) taken at the
  same moment. This tool collects one pair per run.

  Decoded 2026-08-27 from a Gen 3 tester capture (FW FR05.011, app 4.3.1) — PROTOCOL.md
  §5.10. Command `06 05 00` puts the ring in "mode 5", after which it PUSHES 135-byte
  `0x12` frames at ~100 Hz with no acknowledgement of any kind. `06 00 00` stops it.

⚠️ THE ONE REAL HAZARD — WHY THE STOP IS GUARANTEED
  `06 05` is in the same `0x06` mode family as native sport mode, and we have measured, on
  this hardware, that a ring left stranded in sport mode records ZERO history indefinitely
  while still looking perfectly healthy in the app. Mode 5 is WORSE to detect: sport mode
  raises the descriptor state byte to 0x06, but mode 5 leaves it at the ordinary idle
  0x02/0x03 (measured across all three assessments in the reference capture). So a stranded
  mode 5 is INVISIBLE in telemetry — the stream itself is the only witness.

  Therefore: `06 00 00` is sent from a `finally`, on every exit path — normal end, Ctrl-C,
  exception, or a ring that vanishes mid-run — and retried. And on startup this tool
  listens BEFORE sending anything: if `0x12` frames are already arriving, a previous run
  died badly, and it clears that first.

⚠️ WHAT THIS DELIBERATELY DOES NOT DO
  It does not open a history sync session (`02 00 ...`). The ring hands its backlog to
  whoever asks first and then advances a single shared resume pointer, so draining here
  could silently take sleep/HR history away from your official RingConn app. If mode 5
  turns out to need an open session we will add it as an explicit, warned opt-in.

STDLIB + BLEAK ONLY — no numpy/scipy, so it runs in the same `.venv-probe` the vibrate
runbook already builds. The pulse check is a hand-rolled band-limited DFT.
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import datetime
import math
import struct
import sys
from pathlib import Path

from opencircuit import ble
from opencircuit.auth import SYSID_CHAR, auth_command, mac_from_sysid

CMD_STATUS      = bytes.fromhex("010000")
CMD_DESCRIPTOR  = bytes.fromhex("d00000")
CMD_SENSOR_READ = bytes.fromhex("290000")   # the app sends this ~3 s before every BP run
CMD_MODE5_START = bytes.fromhex("060500")
CMD_MODE_STOP   = bytes.fromhex("060000")

PPG_DENSE = 0x12    # 135 B, 10 samples x 4 ch x 24-bit BE, ~100 Hz
PPG_SLOW  = 0x13    # 160 B, 25 samples x 3 ch x int16 BE, ~25 Hz

DENSE_LEN, DENSE_HDR, DENSE_TAIL, DENSE_STRIDE = 135, 6, 9, 12


def xor_trailer(body: bytes) -> int:
    acc = 0
    for b in body:
        acc ^= b
    return acc


def decode_dense(frame: bytes):
    """One `0x12` frame -> (seq, [(ch0..ch3), ...]). None if it isn't a valid one.

    ch0/ch1 are the LED channels (large DC, pulsatile). ch3 is a small SIGNED 20-bit
    ambient/dark-current residual, so it is sign-corrected here; ch0-ch2 are unsigned.
    """
    if len(frame) != DENSE_LEN or frame[0] != PPG_DENSE:
        return None
    if xor_trailer(frame[:-1]) != frame[-1]:
        return None
    seq = struct.unpack_from(">H", frame, 1)[0]
    body = frame[DENSE_HDR:len(frame) - DENSE_TAIL]
    out = []
    for i in range(0, len(body), DENSE_STRIDE):
        rec = body[i:i + DENSE_STRIDE]
        if len(rec) < DENSE_STRIDE:
            break
        ch = [(rec[j] << 16) | (rec[j + 1] << 8) | rec[j + 2] for j in (0, 3, 6, 9)]
        if ch[3] & (1 << 19):          # 20-bit two's complement
            ch[3] -= (1 << 20)
        out.append(tuple(ch))
    return seq, out


# ── pulse check (pure Python; no numpy) ──────────────────────────────────────
def _decimate(x, factor):
    """Average groups of `factor`. Mild anti-alias; we only care below 3 Hz."""
    return [sum(x[i:i + factor]) / len(x[i:i + factor])
            for i in range(0, len(x) - factor + 1, factor)]


def _detrend(x, window):
    """Subtract a centred moving average — a high-pass well below the pulse band."""
    n = len(x)
    ps = [0.0] * (n + 1)
    for i, v in enumerate(x):
        ps[i + 1] = ps[i] + v
    half = max(1, window // 2)
    out = []
    for i in range(n):
        a, b = max(0, i - half), min(n, i + half + 1)
        out.append(x[i] - (ps[b] - ps[a]) / (b - a))
    return out


def pulse_estimate(samples, fs, lo=0.7, hi=3.0, step=0.005, settle_s=2.0):
    """-> (bpm, snr). Band-limited DFT peak vs the median of the band.

    Two steps here are load-bearing, and both were found by replaying a real capture
    against a known answer (74.4 bpm) rather than by reasoning:

    1. DROP THE SETTLING RAMP. Every run opens with ~2 s of monotone AGC/DC-cancellation
       sweep (PROTOCOL.md §5.10) that moves the channel by more than half its full range.
       Left in, that step dominates the spectrum.
    2. WINDOW BEFORE TRANSFORMING. Without a Hann taper the leftover edge discontinuity
       leaks across the whole band and the peak pins to the bottom edge — the first
       version of this function confidently reported 42.0 bpm (= exactly `lo`) for a
       waveform whose true rate is 74.4. A peak sitting on a band edge is a filter
       artefact, not a measurement, so it is also rejected explicitly below.
    """
    if len(samples) < int(8 * fs):
        return None, None
    x = samples[int(settle_s * fs):]
    if len(x) < int(8 * fs):
        return None, None
    factor = max(1, int(fs // 25))
    x = _decimate(x, factor)
    fs2 = fs / factor
    x = _detrend(x, int(2.5 * fs2))
    n = len(x)
    win = [0.5 - 0.5 * math.cos(2.0 * math.pi * i / (n - 1)) for i in range(n)]
    x = [v * w for v, w in zip(x, win)]
    mags = []
    f = lo
    while f <= hi:
        w = 2.0 * math.pi * f / fs2
        re = im = 0.0
        for i, v in enumerate(x):
            a = w * i
            re += v * math.cos(a)
            im -= v * math.sin(a)
        mags.append((f, math.hypot(re, im) / n))
        f += step
    peak_f, peak_m = max(mags, key=lambda t: t[1])
    ordered = sorted(m for _, m in mags)
    median = ordered[len(ordered) // 2] or 1e-12
    snr = peak_m / median
    if peak_f <= lo + 2 * step or peak_f >= hi - 2 * step:
        return peak_f * 60.0, 0.0        # band-edge pin: report it, trust it as zero
    return peak_f * 60.0, snr


def quality_verdict(snr):
    if snr is None:
        return "UNUSABLE — too few samples"
    if snr >= 15:
        return "GOOD — clear pulse, this pair is worth keeping"
    if snr >= 6:
        return "MARGINAL — usable, but sit stiller and try another"
    return "POOR — no clear pulse. Stay still, ring snug, redo this one"


class Session:
    def __init__(self, path):
        self.path, self.lines, self.frames = path, [], []
        self.stopped_cleanly = False

    def note(self, s=""):
        print(s)
        self.lines.append(s)

    def on_notify(self, _sender, data):
        self.frames.append((datetime.datetime.now().timestamp(), bytes(data)))

    def recent(self, opcode, since):
        return [f for t, f in self.frames if t >= since and f and f[0] == opcode]

    def flush(self):
        self.path.write_text("\n".join(self.lines) + "\n")
        print(f"\nWrote {self.path}")


async def _write(client, payload):
    await client.write_gatt_char(ble.WRITE_CHAR, payload, response=True)


async def _force_stop(client, s):
    """Send `06 00 00` and mean it. Runs on EVERY exit path — see the header warning."""
    for attempt in (1, 2, 3):
        try:
            await _write(client, CMD_MODE_STOP)
            await asyncio.sleep(0.4)
            s.stopped_cleanly = True
            s.note(f"Mode 5 stopped (`06 00 00`, attempt {attempt}).")
            return
        except Exception as exc:
            s.note(f"WARN: stop attempt {attempt} failed ({exc})")
            await asyncio.sleep(0.5)
    s.note("")
    s.note("!! COULD NOT CONFIRM THE STOP. Almost certainly the link simply dropped, which")
    s.note("!! ends the mode anyway. To be certain: put the ring on its charger for a few")
    s.note("!! seconds, then re-run this tool — it clears a stranded stream on startup.")


async def collect(address, seconds, s):
    from bleak import BleakClient, BleakScanner

    if address:
        dev = await BleakScanner.find_device_by_address(address, timeout=30.0) or address
    else:
        s.note("Scanning up to 30 s for a RingConn …")
        dev = await BleakScanner.find_device_by_filter(
            lambda d, ad: bool(d.name and d.name.startswith(ble.NAME_PREFIXES)), timeout=30.0)
        if dev is None:
            s.note("No RingConn found. Check all three:")
            s.note("  1. Bluetooth OFF on your iPhone (or the RingConn app force-quit) —")
            s.note("     the ring takes one connection at a time and the phone wins.")
            s.note("  2. System Settings > Privacy & Security > Bluetooth > allow Terminal.")
            s.note("  3. The ring is awake and off the charger — move it.")
            return 1
        s.note(f"Found: {dev.name}")

    async with BleakClient(dev) as client:
        s.note("Connected.")
        await client.start_notify(ble.NOTIFY_CHAR, s.on_notify)
        await asyncio.sleep(0.3)

        # ── auth ────────────────────────────────────────────────────────────
        try:
            mac = mac_from_sysid(bytes(await client.read_gatt_char(SYSID_CHAR)))
        except Exception as exc:
            s.note(f"WARN: could not read System ID ({exc})")
            mac = None
        mark = datetime.datetime.now().timestamp()
        await _write(client, CMD_STATUS)
        await asyncio.sleep(0.6)
        challenge = next((f[2] for f in s.recent(0x81, mark) if len(f) >= 3), None)
        if challenge is None or mac is None:
            s.note("")
            s.note("AUTH FAILED — no challenge, or the MAC is unreadable. Unauthenticated the")
            s.note("ring ignores commands, so anything recorded now would be a false negative.")
            return 1
        await _write(client, auth_command(challenge, mac))
        await asyncio.sleep(0.5)
        s.note(f"Authenticated (challenge 0x{challenge:02x}).")

        # ── battery / state, for the record ─────────────────────────────────
        mark = datetime.datetime.now().timestamp()
        await _write(client, CMD_DESCRIPTOR)
        await asyncio.sleep(2.0)
        desc = next((f for f in s.recent(0x10, mark) + s.recent(0x87, mark) if len(f) >= 19), None)
        if not desc:
            # Measured 2026-08-28 on Gen 3 FR05.011: an authenticated session with no
            # sync-open can produce NO descriptor for 65 s+ (PROTOCOL.md §5.4 counter-
            # observation). That is expected, not an error — but the sport-mode guard
            # below depends on it, so say plainly that the check did not run rather than
            # letting a skipped safety check look like a passed one.
            s.note("No descriptor returned — battery/state unknown (this is a known Gen 3")
            s.note("behaviour, not a failure). The sport-mode pre-check could NOT run.")
        if desc:
            s.note(f"Battery {desc[1]}%   state byte 0x{desc[2]:02x}   "
                   f"skin temp {struct.unpack_from('>H', desc, 6)[0] / 10.0:.1f} C")
            if desc[2] == 0x06:
                s.note("")
                s.note("STOP — the ring is in native SPORT mode (state 0x06). It will not")
                s.note("record history in that state. Clearing it, then re-run this tool.")
                await _write(client, CMD_MODE_STOP)
                return 1

        # ── stranded-stream guard (mode 5 is invisible in the state byte) ───
        mark = datetime.datetime.now().timestamp()
        await asyncio.sleep(2.5)
        if s.recent(PPG_DENSE, mark):
            s.note("A previous run left mode 5 running. Clearing it first …")
            await _write(client, CMD_MODE_STOP)
            await asyncio.sleep(1.5)

        # ── the measurement ─────────────────────────────────────────────────
        s.note("")
        s.note("Sit still. Arm supported, ring hand relaxed at about heart height.")
        for n in (5, 4, 3, 2, 1):
            print(f"  starting in {n} …", end="\r", flush=True)
            await asyncio.sleep(1.0)
        print(" " * 30, end="\r")

        await _write(client, CMD_SENSOR_READ)
        await asyncio.sleep(2.0)

        start = datetime.datetime.now().timestamp()
        try:
            await _write(client, CMD_MODE5_START)
            s.note(f"Mode 5 started. Recording {seconds} s — hold still.")
            for elapsed in range(seconds):
                await asyncio.sleep(1.0)
                got = len(s.recent(PPG_DENSE, start))
                print(f"  {elapsed + 1:3d}/{seconds} s   {got:5d} frames", end="\r", flush=True)
                if elapsed == 7 and got == 0:
                    s.note("")
                    s.note("No `0x12` frames after 8 s. Mode 5 may need something we haven't")
                    s.note("identified (an open sync session is the leading suspect). Stopping.")
                    break
            print(" " * 40, end="\r")
        finally:
            # The whole point of this tool's safety story. Do not restructure.
            await _force_stop(client, s)

        return 0 if s.recent(PPG_DENSE, start) else 2


def analyse_and_write(s, out_stem, seconds):
    """Decode, integrity-check, judge quality, write the CSV. Returns a summary dict."""
    dense = [(t, f) for t, f in s.frames if f and f[0] == PPG_DENSE and len(f) == DENSE_LEN]
    slow = [f for _, f in s.frames if f and f[0] == PPG_SLOW]
    if not dense:
        s.note("No dense PPG frames were captured — nothing to write.")
        return None

    # Split into separate measurement runs. A live session has exactly one, so this is a
    # no-op there — but a replayed capture holds several, and averaging them together
    # would invent a sample rate and a heart rate that no run actually had.
    runs, current = [], [dense[0]]
    for prev, cur in zip(dense, dense[1:]):
        (current.append(cur) if cur[0] - prev[0] <= 5.0
         else (runs.append(current), current := [cur]))
    runs.append(current)
    if len(runs) > 1:
        s.note(f"Capture holds {len(runs)} separate measurement runs; "
               f"analysing the longest.")
    dense = max(runs, key=len)

    rows, seqs, bad_xor = [], [], 0
    for _, f in dense:
        d = decode_dense(f)
        if d is None:
            bad_xor += 1
            continue
        seq, samples = d
        seqs.append(seq)
        rows.extend(samples)

    span = dense[-1][0] - dense[0][0]
    fs = (len(rows) / span) if span > 0 else 0.0
    gaps = sum(1 for a, b in zip(seqs, seqs[1:]) if (b - a) % 65536 != 1)

    ch0 = [r[0] for r in rows]
    ch1 = [r[1] for r in rows]
    bpm0, snr0 = pulse_estimate(ch0, fs) if fs > 1 else (None, None)
    bpm1, snr1 = pulse_estimate(ch1, fs) if fs > 1 else (None, None)

    csv_path = Path(f"{out_stem}.csv")
    with csv_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["sample_idx", "t_s", "ch0", "ch1", "ch2", "ch3_ambient"])
        for i, r in enumerate(rows):
            w.writerow([i, round(i / fs, 5) if fs else "", *r])

    s.note("")
    s.note(f"Frames {len(dense)} dense + {len(slow)} slow · samples {len(rows)} · "
           f"{span:.1f} s · {fs:.1f} Hz")
    s.note(f"Integrity: {bad_xor} bad checksums, {gaps} sequence gaps")
    if bpm0:
        s.note(f"Pulse ch0 {bpm0:.1f} bpm (SNR {snr0:.1f}) · ch1 {bpm1:.1f} bpm (SNR {snr1:.1f})")
        s.note(f"Quality: {quality_verdict(max(snr0, snr1))}")
    s.note(f"Waveform: {csv_path}")
    return {"fs": fs, "samples": len(rows), "bpm": bpm0, "snr": snr0,
            "gaps": gaps, "bad_xor": bad_xor}


def ask_cuff(s):
    s.note("")
    s.note("Now the cuff reading — take it on the OTHER arm, right now.")
    s.note("(Press Enter alone to skip if you don't have one.)")
    try:
        sys_ = input("  Systolic  (top number):    ").strip()
        dia = input("  Diastolic (bottom number): ").strip()
        note = input("  Anything worth noting?     ").strip()
    except (EOFError, KeyboardInterrupt):
        sys_ = dia = note = ""
    if sys_ or dia:
        s.note(f"CUFF: {sys_}/{dia}   {note}")
    else:
        s.note("CUFF: not recorded")


def replay(path, s):
    """Offline decode of a btsnoop capture — the tool's own known-answer test."""
    from opencircuit import sniff
    blob = Path(path).read_bytes()
    for ev in sniff._iter_att(blob):
        if not ev.sent and ev.value and ev.value[0] in (PPG_DENSE, PPG_SLOW):
            s.frames.append((ev.ts_unix, ev.value))
    s.note(f"Replayed {path}: {len(s.frames)} PPG frames")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Record the ring's raw pulse waveform + a cuff pair.")
    ap.add_argument("--seconds", type=int, default=45, help="recording length (default 45)")
    ap.add_argument("--addr", default=None, help="ring address / UUID (default: scan by name)")
    ap.add_argument("--label", default="", help="free-text note stored with the run")
    ap.add_argument("--replay", default=None, help="offline: decode a btsnoop file, no radio")
    args = ap.parse_args(argv)

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    # Into `captures/`, which is gitignored, because a waveform IS health data and the
    # repo's rule is that only decoded findings are ever committed. Writing these beside
    # the script would leave a tester's pulse trace one `git add .` from being published.
    outdir = Path(__file__).with_name("captures")
    outdir.mkdir(exist_ok=True)
    stem = outdir / f"bp_pair_{ts}"
    s = Session(Path(f"{stem}.txt"))
    s.note("OpenCircuit — blood-pressure calibration pair")
    s.note(f"Started: {datetime.datetime.now().isoformat(timespec='seconds')}")
    if args.label:
        s.note(f"Label:   {args.label}")
    s.note("")

    rc = 1
    try:
        if args.replay:
            rc = replay(args.replay, s)
            analyse_and_write(s, stem, args.seconds)
            return rc
        rc = asyncio.run(collect(args.addr, args.seconds, s))
        analyse_and_write(s, stem, args.seconds)
        if rc == 0:
            ask_cuff(s)
    except KeyboardInterrupt:
        s.note("\nInterrupted by you — the stop command still ran.")
    finally:
        s.flush()
        print("Send back BOTH files (.txt and .csv) — including if it failed.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
