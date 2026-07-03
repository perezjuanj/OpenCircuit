"""Stream RSP 0x13 — raw multi-channel optical PPG from RingConn Gen 2 Air.

BREAKTHROUGH 2026-06-26: CMD `96 01 XX XX XX` (5-byte payload) while in
mode01 triggers RSP 0x13 — 25 × 6-byte multi-channel optical records per frame.
This is the first confirmed pulse-resolution raw PPG accessible via BLE.

Frame format (160 bytes):
  [13][00][seq:1][01][00][9d][25 × 6-byte records][00][00][cumulative:1][XOR:1]

Record format (6 bytes):
  bytes[0:2] = chA (big-endian uint16)  — green LED channel, DC ~539 counts
  bytes[2:4] = chB (big-endian int16)   — channel B (red?), DC ~-654 counts
  bytes[4:6] = chC (big-endian int16)   — channel C (IR?),  DC ~-588 counts

AC/DC ratios (verified):
  chA: 5.4%  chB: 2.6%  chC: 5.8%  — all pulse-resolution PPG quality

Sampling: PULL model. Each `96 01 00 00 00` fetches the NEXT 25 samples from
the ring's internal circular buffer. Poll every ~1s for gapless 25 Hz stream.

Mode01 (CMD `06 01 00`) must be entered FIRST to start the optical engine.

Usage:
    .venv/bin/python stream_ppg_13.py <CBPeripheral-UUID> [--duration 60] [--csv]

Output:
  - Console: per-frame stats (seq, HR estimate, channel amplitudes)
  - If --csv: ppg_<timestamp>.csv with per-sample rows
"""
from __future__ import annotations
import asyncio, sys, argparse, time, struct, datetime, statistics, math
from bleak import BleakClient, BleakError
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

ADDR = sys.argv[1] if len(sys.argv) > 1 else None
N_SAMPLES = 25
RECORD_BYTES = 6
SAMPLE_RATE_HZ = 25.0  # assumed; verify by timing seq increments

# Command to request one batch of PPG samples
PPG_FETCH = bytes.fromhex("9601000000")  # CMD 0x96, param[0]=0x01, rest=0x00


def parse_0x13(frame: bytes) -> dict | None:
    """Parse a 0x13 PPG frame. Returns None if frame is invalid."""
    if len(frame) < 10 or frame[0] != 0x13:
        return None
    # XOR check
    xor = 0
    for b in frame[:-1]:
        xor ^= b
    if xor != frame[-1]:
        return None  # XOR fail — corrupted

    seq = frame[2]
    cumulative = frame[-2]  # total samples delivered so far

    body = frame[6:-4]
    if len(body) != N_SAMPLES * RECORD_BYTES:
        return None

    chA, chB, chC = [], [], []
    for i in range(N_SAMPLES):
        r = body[i * RECORD_BYTES:(i + 1) * RECORD_BYTES]
        chA.append(struct.unpack('>H', r[0:2])[0])       # uint16 BE (green)
        chB.append(struct.unpack('>h', r[2:4])[0])       # int16 BE (red?)
        chC.append(struct.unpack('>h', r[4:6])[0])       # int16 BE (IR?)

    return {"seq": seq, "cumulative": cumulative, "chA": chA, "chB": chB, "chC": chC}


def fft_hr(samples: list[float], fs: float = SAMPLE_RATE_HZ) -> float | None:
    """FFT-based HR estimate. Needs ≥75 samples (3s at 25Hz) for reliable results.

    Zero-crossing on 1s (25 sample) windows is noise-dominated at these AC/DC levels.
    FFT over ≥10s (250+ samples) integrates away noise and gives a reliable estimate.
    """
    import math
    n = len(samples)
    if n < 75:   # need at least 3s; 10s+ is better
        return None
    mean = sum(samples) / n
    detrended = [s - mean for s in samples]
    # Hanning window to reduce spectral leakage
    windowed = [s * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)))
                for i, s in enumerate(detrended)]
    # Manual DFT over HR band 30-210 bpm (0.5-3.5 Hz)
    best_mag = 0.0
    best_hz = 0.0
    for k in range(1, n // 2 + 1):
        hz = k * fs / n
        if hz < 0.5 or hz > 3.5:
            continue
        re = sum(windowed[i] * math.cos(2 * math.pi * k * i / n) for i in range(n))
        im = sum(windowed[i] * math.sin(2 * math.pi * k * i / n) for i in range(n))
        mag = math.sqrt(re * re + im * im)
        if mag > best_mag:
            best_mag = mag
            best_hz = hz
    return best_hz * 60 if best_hz > 0 else None


async def main(addr: str, duration: int, write_csv: bool) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = f"ppg_{ts}.csv"
    csv_file = open(csv_path, "w") if write_csv else None
    if csv_file:
        csv_file.write("wall_clock_s,seq,sample_idx,chA,chB,chC\n")

    all_chA: list[int] = []
    all_chB: list[int] = []
    all_chC: list[int] = []

    async with BleakClient(device) as client:
        print(f"\nConnected: {addr}")
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        async def tx(hexstr: str) -> None:
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(hexstr), response=True)

        async def drain(max_wait: float, gap: float = 0.5) -> list[bytes]:
            """Read frames until `gap` seconds of silence (not `max_wait` per frame).
            Exits after `gap` seconds with no new frame, or after `max_wait` seconds total.
            This prevents infinite blocking when the ring is pushing frames continuously."""
            frames = []
            deadline = time.monotonic() + max_wait
            while time.monotonic() < deadline:
                try:
                    b = await asyncio.wait_for(q.get(), timeout=min(gap, deadline - time.monotonic()))
                    frames.append(bytes(b))
                except asyncio.TimeoutError:
                    break
            return frames

        # ── Auth ─────────────────────────────────────────────────────────────────
        print("Authenticating...")
        mac = None
        try:
            raw = await client.read_gatt_char(SYSID_CHAR)
            mac = mac_from_sysid(bytes(raw))
        except Exception:
            pass

        await tx("010000")
        await asyncio.sleep(0.3)
        challenge_frame = None
        while not q.empty():
            b = q.get_nowait()
            if b[0] == 0x81:
                challenge_frame = b
        if challenge_frame and mac:
            cmd = auth_command(challenge_frame[2], mac)
            await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            await asyncio.sleep(0.3)
            while not q.empty(): q.get_nowait()
            print("Auth OK")

        # ── Full drain (exhaust any pending history so ring's attention is free) ──
        await tx(ble.SYNC_ALL.hex()); await drain(2.0)
        await tx("070000"); await drain(3.0)
        await tx("d00000"); await drain(1.0)
        while not q.empty(): q.get_nowait()

        # ── Pre-condition: enter mode 0x10 then exit ──────────────────────────────
        # probe_mode_09_plus.py swept modes 10-13 (all accepted: 86 00 86) before
        # the 0x96 probes worked. Mode 0x10 is the suspected PPG-hardware-enable
        # mode — entering it primes the ring's optical engine even after exit.
        # Without this step, 96 01 00 00 00 returns nothing in mode01.
        print("\nPre-conditioning: entering mode 0x10 (PPG hardware activation)...")
        await tx("061000")
        await drain(3.0)          # let ring ACK and settle
        await tx("060000")        # exit mode 0x10
        await asyncio.sleep(0.5)
        while not q.empty(): q.get_nowait()
        print("Mode 0x10 pre-condition done.")

        # ── Enter mode01 ──────────────────────────────────────────────────────────
        # With mode10 pre-conditioning the ring enters PUSH mode and starts
        # streaming 0x13 frames spontaneously. We just need to enter mode01 and
        # immediately start reading — no long warmup needed.
        print("Entering mode01...")
        await tx("060100")
        # Wait for 0x86 ack only — gap-based drain exits after 0.5s of silence.
        # Any spontaneous 0x13 frames will be caught by the main loop below.
        ack_frames = await drain(2.0, gap=0.5)
        has_ack = any(f[0] == 0x86 for f in ack_frames)
        has_push = any(f[0] == 0x13 for f in ack_frames)
        print(f"Mode01 active (ACK={'yes' if has_ack else 'no'}, "
              f"push={'yes — ring is streaming automatically' if has_push else 'no — will use pull'}).\n")
        # If push frames arrived during drain, re-queue them so the main loop processes them.
        for f in ack_frames:
            if f[0] == 0x13:
                q.put_nowait(f)

        print(f"{'Time':>10}  {'seq':>4}  {'chA_DC':>7}  {'chA_AC':>7}  {'chB_DC':>7}  {'chB_AC':>7}  {'chC_DC':>7}  {'chC_AC':>7}  {'HR_FFT':>9}")
        print("-" * 90)

        t0 = time.monotonic()
        prev_seq: int | None = None
        sample_abs_idx = 0
        frame_count = 0
        last_keepalive = t0
        consecutive_misses = 0
        # Rolling buffer for FFT HR (10s = 250 samples at 25Hz)
        hr_buffer_chA: list[float] = []
        HR_BUFFER_SIZE = 250  # 10s; HR_EST_EVERY frames triggers FFT
        HR_EST_EVERY = 10     # re-estimate HR every 10 frames (10s)
        last_hr_est: float | None = None

        while time.monotonic() - t0 < duration:
            # ── Periodic keepalive every 8s (BLE supervision timeout is ~30-40s) ──
            now = time.monotonic()
            if now - last_keepalive >= 8.0:
                try:
                    await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("950000"), response=True)
                    last_keepalive = time.monotonic()
                except BleakError:
                    pass

            # ── Read next 0x13 frame: push first, fall back to pull ───────────────
            ppg_frame: bytes | None = None

            # Step 1: check queue for a pushed frame (ring may stream automatically)
            deadline = time.monotonic() + 1.2  # wait up to 1.2s for push
            while time.monotonic() < deadline and ppg_frame is None:
                try:
                    raw = await asyncio.wait_for(q.get(), timeout=min(0.3, deadline - time.monotonic()))
                    if raw[0] == 0x13:
                        ppg_frame = bytes(raw)
                    # Silently discard 0x86/0x10/0x15/0x87/0x4E/0x11 between frames
                except asyncio.TimeoutError:
                    break  # no more queued frames

            # Step 2: if push stream stalled, trigger a pull fetch
            if ppg_frame is None:
                try:
                    await client.write_gatt_char(ble.WRITE_CHAR, PPG_FETCH, response=True)
                except BleakError as e:
                    print(f"Write failed: {e}")
                    break
                # Wait up to 2s for ring to respond
                deadline2 = time.monotonic() + 2.0
                while time.monotonic() < deadline2 and ppg_frame is None:
                    try:
                        raw = await asyncio.wait_for(q.get(), timeout=min(0.5, deadline2 - time.monotonic()))
                        if raw[0] == 0x13:
                            ppg_frame = bytes(raw)
                    except asyncio.TimeoutError:
                        break

            if ppg_frame is None:
                consecutive_misses += 1
                print(f"  {time.strftime('%H:%M:%S')}  (no RSP 0x13 — miss #{consecutive_misses})")
                if consecutive_misses >= 5:
                    print("  Re-conditioning + re-entering mode01 after 5 misses...")
                    await tx("061000"); await drain(3.0, gap=0.5)
                    await tx("060000"); await asyncio.sleep(0.5)
                    while not q.empty(): q.get_nowait()
                    await tx("060100"); await drain(2.0, gap=0.5)
                    while not q.empty(): q.get_nowait()
                    consecutive_misses = 0
                continue
            consecutive_misses = 0

            parsed = parse_0x13(ppg_frame)
            if parsed is None:
                print(f"  {time.strftime('%H:%M:%S')}  (0x13 frame failed XOR check — len={len(ppg_frame)})")
                continue

            seq = parsed["seq"]
            chA, chB, chC = parsed["chA"], parsed["chB"], parsed["chC"]

            # Gap detection
            if prev_seq is not None and seq != (prev_seq + 1) % 256:
                gap = (seq - prev_seq - 1) % 256
                if gap > 0:
                    print(f"  *** GAP: missed {gap} frames ({gap * N_SAMPLES} samples) ***")
            prev_seq = seq

            chA_dc = statistics.mean(chA)
            chA_ac = max(chA) - min(chA)
            chB_dc = statistics.mean(chB)
            chB_ac = max(chB) - min(chB)
            chC_dc = statistics.mean(chC)
            chC_ac = max(chC) - min(chC)

            # Saturation check: chA > 60000 (uint16 AGC event) → skip HR update
            is_saturated = chA_dc > 60000 or chA_ac > 60000

            if not is_saturated:
                hr_buffer_chA.extend(chA)
                if len(hr_buffer_chA) > HR_BUFFER_SIZE:
                    hr_buffer_chA = hr_buffer_chA[-HR_BUFFER_SIZE:]
                # Re-estimate HR every HR_EST_EVERY good frames
                if frame_count % HR_EST_EVERY == 0 and len(hr_buffer_chA) >= 75:
                    last_hr_est = fft_hr(hr_buffer_chA)

            all_chA.extend(chA)
            all_chB.extend(chB)
            all_chC.extend(chC)

            sat_flag = "  [AGC]" if is_saturated else ""
            print(f"{time.strftime('%H:%M:%S'):>10}  {seq:>4}  {chA_dc:>7.0f}  {chA_ac:>7}  {chB_dc:>7.0f}  {chB_ac:>7}  {chC_dc:>7.0f}  {chC_ac:>7}  "
                  f"{'--' if last_hr_est is None else f'{last_hr_est:>5.1f}bpm':>9}{sat_flag}")

            if csv_file:
                wall = time.time()
                for i, (a, b, c) in enumerate(zip(chA, chB, chC)):
                    csv_file.write(f"{wall:.3f},{seq},{sample_abs_idx + i},{a},{b},{c}\n")

            sample_abs_idx += N_SAMPLES
            frame_count += 1

        await client.stop_notify(ble.NOTIFY_CHAR)

    # Summary
    print(f"\n{'='*60}")
    print(f"Captured {frame_count} frames = {sample_abs_idx} samples "
          f"(~{sample_abs_idx/SAMPLE_RATE_HZ:.1f}s at {SAMPLE_RATE_HZ}Hz assumed)")

    if all_chA:
        for name, vals in [("chA (green)", all_chA), ("chB", all_chB), ("chC", all_chC)]:
            mn, mx = min(vals), max(vals)
            mean = sum(vals) / len(vals)
            print(f"  {name}: DC={mean:.0f}  AC_range={mx - mn}  AC/DC={100*(mx-mn)/abs(mean):.1f}%")

    if csv_file:
        csv_file.close()
        print(f"\nCSV saved: {csv_path}")
        print(f"  Columns: wall_clock_s, seq, sample_idx, chA, chB, chC")
        print(f"  Plot: python -c \"import pandas as pd, matplotlib.pyplot as plt; "
              f"df=pd.read_csv('{csv_path}'); df.chA.plot(); plt.show()\"")

    print("\nNext steps:")
    print("  1. Plot chA to verify heartbeat waveform shape at 25 Hz")
    print("  2. Compute FFT of chA — peak frequency × 60 = HR (should match 0x15/0x29)")
    print("  3. Compute SpO2 from chB/chC ratio (Red/IR ratio → SpO2 lookup)")
    print("  4. Verify sample rate by comparing HR from FFT vs. HR from CMD 0x29")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("addr", help="CBPeripheral UUID from `opencircuit scan`")
    p.add_argument("--duration", type=int, default=60,
                   help="capture duration in seconds (default 60)")
    p.add_argument("--csv", action="store_true",
                   help="write per-sample CSV (for waveform analysis)")
    args = p.parse_args()
    asyncio.run(main(args.addr, args.duration, args.csv))
