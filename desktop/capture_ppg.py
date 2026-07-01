"""Stage 1 Production PPG Capture Tool — RingConn Air 2.

Connects to the ring, streams RSP 0x13 raw multi-channel optical PPG (25 Hz),
applies the Stage 1 signal processing pipeline in real time, and writes a
two-section CSV ready for Stage 2 (ML / BP inference).

Stage 1 pipeline applied per frame:
  1. AGC saturation detection + linear interpolation over gaps
  2. Bandpass filter  0.5–8 Hz  (4th-order Butterworth IIR, causal, state-continuous)
  3. Contact detection  (chA AC/DC ≥ 1.0%)
  4. FFT HR  (rolling 250-sample = 10s window, updated every 10 frames)
  5. SpO2 estimate  (per-frame R ratio, rolling 20-frame average — needs calibration)

Features:
  - Auto-reconnect: re-auths and re-enters mode10+mode01 on BLE drop
  - Filter state reset after reconnect (avoids startup transient corruption)
  - Quality gate: records whether each frame has valid contact
  - CSV has both raw AND filtered columns (Stage 2 model may want either)
  - Periodic CMD 0x29 HR+SpO2 ground-truth poll every 30s for cross-check

CSV output columns:
  wall_clock_s, seq, sample_idx, chA_raw, chB_raw, chC_raw,
  chA_filt, chB_filt, chC_filt, hr_fft_bpm, spo2_pct, contact, saturated

Usage:
    .venv/bin/python capture_ppg.py <CBPeripheral-UUID>
    .venv/bin/python capture_ppg.py <CBPeripheral-UUID> --duration 300 --output my_capture.csv
    .venv/bin/python capture_ppg.py <CBPeripheral-UUID> --no-reconnect

After capture, analyse with:
    .venv/bin/python analyze_ppg_13.py <output.csv>
"""
from __future__ import annotations
import asyncio
import argparse
import csv
import datetime
import struct
import sys
import time
from typing import Optional

from bleak import BleakClient, BleakError
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

from ppg_pipeline import PPGFrame, PPGPipeline, FRAME_SIZE, SAT_THRESHOLD

# ── Protocol ────────────────────────────────────────────────────────────────
KEEPALIVE_INTERVAL_S = 8.0     # BLE supervision timeout is ~30-40s; keepalive every 8s
PPG_KEEPALIVE_INTERVAL_S = 30.0  # fetch cmd resets ring's PPG-mode timer (app-layer timeout)
POLL_HR_SPO2_EVERY_S = 30.0    # CMD 0x29 ground-truth poll interval
MAX_RECONNECT_ATTEMPTS = 5
RECONNECT_WAIT_S = 5.0


# ── RSP 0x13 frame parser ────────────────────────────────────────────────────

def parse_0x13(frame: bytes) -> Optional[PPGFrame]:
    """Parse a raw RSP 0x13 frame into a PPGFrame.

    Frame format (160 bytes):
      [13][00][seq][01][00][9D][25 × 6-byte records][00][00][cumulative][XOR]
    Each 6-byte record:
      [0:2] chA  big-endian uint16  (GREEN LED — confirmed)
      [2:4] chB  big-endian  int16  (RED 660nm — confirmed by SpO2 ratiometry)
      [4:6] chC  big-endian  int16  (IR 940nm  — confirmed by SpO2 ratiometry)
    """
    if len(frame) < 10 or frame[0] != 0x13:
        return None
    # XOR integrity check
    if (x := 0) or True:
        x = 0
        for b in frame[:-1]:
            x ^= b
        if x != frame[-1]:
            return None

    seq = frame[2]
    body = frame[6:-4]
    if len(body) != FRAME_SIZE * 6:
        return None

    chA, chB, chC = [], [], []
    for i in range(FRAME_SIZE):
        r = body[i * 6:(i + 1) * 6]
        chA.append(struct.unpack('>H', r[0:2])[0])   # uint16 BE
        chB.append(struct.unpack('>h', r[2:4])[0])   # int16 BE
        chC.append(struct.unpack('>h', r[4:6])[0])   # int16 BE

    saturated = any(s > SAT_THRESHOLD for s in chA)
    return PPGFrame(seq=seq, chA=chA, chB=chB, chC=chC,
                    wall_time=time.time(), saturated=saturated)


def parse_0xa9(frame: bytes) -> Optional[tuple[int, int]]:
    """Parse CMD 0x29 → RSP 0xA9 HR+SpO2 snapshot.
    Returns (hr_bpm, spo2_pct) or None if invalid/not-worn."""
    if len(frame) < 6 or frame[0] != 0xA9:
        return None
    valid_hr, hr = frame[2], frame[3]
    valid_spo2, spo2 = frame[4], frame[5]
    if valid_hr == 0x01 and valid_spo2 == 0x01:
        return (int(hr), int(spo2))
    return None


# ── BLE session helpers ──────────────────────────────────────────────────────

async def authenticate(client: BleakClient, q: asyncio.Queue) -> bool:
    """SM3 challenge-response auth. Returns True on success."""
    mac = None
    try:
        raw = await client.read_gatt_char(SYSID_CHAR)
        mac = mac_from_sysid(bytes(raw))
    except Exception:
        return False

    await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("010000"), response=True)
    await asyncio.sleep(0.3)

    challenge = None
    while not q.empty():
        b = q.get_nowait()
        if b[0] == 0x81:
            challenge = b

    if challenge is None or mac is None:
        return False

    cmd = auth_command(challenge[2], mac)
    await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
    await asyncio.sleep(0.3)
    while not q.empty():
        q.get_nowait()
    return True


async def drain(client: BleakClient, q: asyncio.Queue,
                max_wait: float, gap: float = 0.5) -> list[bytes]:
    """Read frames until `gap` seconds of silence, max `max_wait` total."""
    frames: list[bytes] = []
    deadline = time.monotonic() + max_wait
    while time.monotonic() < deadline:
        try:
            b = await asyncio.wait_for(q.get(), timeout=min(gap, deadline - time.monotonic()))
            frames.append(bytes(b))
        except asyncio.TimeoutError:
            break
    return frames


async def enter_ppg_mode(client: BleakClient, q: asyncio.Queue) -> bool:
    """Enter mode10 pre-condition then mode01. Returns True if mode01 ACK received."""
    # Pre-condition: enter mode 0x10 (primes PPG hardware engine)
    await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("061000"), response=True)
    await drain(client, q, 3.0, gap=0.5)
    await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("060000"), response=True)
    await asyncio.sleep(0.5)
    while not q.empty():
        q.get_nowait()

    # Enter mode01 (ring starts push-streaming RSP 0x13 frames)
    await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("060100"), response=True)
    ack_frames = await drain(client, q, 2.0, gap=0.5)
    has_ack = any(f[0] == 0x86 for f in ack_frames)

    # Re-queue any RSP 0x13 frames that arrived during the ack drain
    for f in ack_frames:
        if f[0] == 0x13:
            q.put_nowait(f)
    return has_ack


# ── Main streaming coroutine ─────────────────────────────────────────────────

async def stream_session(
    client: BleakClient,
    q: asyncio.Queue,
    pipeline: PPGPipeline,
    writer: csv.writer,
    csv_file,
    stats: dict,
    duration: float,
    t_start: float,
) -> None:
    """Run one BLE session's worth of streaming. Raises BleakError on disconnect."""

    last_keepalive = time.monotonic()
    last_ppg_keepalive = time.monotonic()
    last_gt_poll = time.monotonic()  # ground-truth CMD 0x29 poll
    fetch_cmd = bytes.fromhex("9601000000")

    print(f"\n  {'Time':8s}  {'seq':>4}  {'chA_DC':>6}  {'RED':>5}  {'IR':>5}  {'AC/DC':>5}  "
          f"{'Contact':7s}  {'HR_FFT':>8}  {'SpO2':>6}  {'Ring HR':>7}  {'Status'}")
    print("  " + "-" * 88)

    ground_truth_hr: Optional[int] = None
    ground_truth_spo2: Optional[int] = None

    while time.monotonic() - t_start < duration:
        now = time.monotonic()

        # ── BLE link keepalive ───────────────────────────────────────────────
        if now - last_keepalive >= KEEPALIVE_INTERVAL_S:
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("950000"),
                                         response=True)
            last_keepalive = time.monotonic()

        # ── PPG-mode keepalive ───────────────────────────────────────────────
        # The ring has an app-layer PPG mode timer separate from BLE keepalive.
        # Sending the fetch cmd every 30s resets it and prevents the ~60s timeout
        # that caused 90s outages (60s wait + 30s AGC re-settle) per session.
        if now - last_ppg_keepalive >= PPG_KEEPALIVE_INTERVAL_S:
            await client.write_gatt_char(ble.WRITE_CHAR, fetch_cmd, response=True)
            last_ppg_keepalive = time.monotonic()

        # ── Ground-truth HR+SpO2 poll (CMD 0x29) ─────────────────────────────
        if now - last_gt_poll >= POLL_HR_SPO2_EVERY_S:
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("290000"),
                                         response=True)
            await asyncio.sleep(0.2)
            while not q.empty():
                b = q.get_nowait()
                parsed = parse_0xa9(b)
                if parsed:
                    ground_truth_hr, ground_truth_spo2 = parsed
            last_gt_poll = time.monotonic()

        # ── Read next frame (push first, fall back to pull) ──────────────────
        raw_frame: Optional[bytes] = None
        try:
            raw_bytes = await asyncio.wait_for(q.get(), timeout=1.2)
            if raw_bytes[0] == 0x13:
                raw_frame = raw_bytes
            # Silently discard 0x86/0x10/0x15/0x87/0x4E/0x11 between PPG frames
        except asyncio.TimeoutError:
            # Push stream stalled — send pull request
            await client.write_gatt_char(ble.WRITE_CHAR, fetch_cmd, response=True)
            try:
                raw_bytes = await asyncio.wait_for(q.get(), timeout=2.0)
                if raw_bytes[0] == 0x13:
                    raw_frame = raw_bytes
            except asyncio.TimeoutError:
                stats["misses"] += 1
                if stats["misses"] % 5 == 0:
                    print(f"  {time.strftime('%H:%M:%S')}  (no RSP 0x13 — "
                          f"{stats['misses']} consecutive misses)")
                # Ring's PPG mode can time out mid-session — re-enter it.
                # Observed: ring stopped sending RSP 0x13 for 3+ minutes at seq 203
                # while BLE stayed connected. keepalive + pull both failed.
                if stats["misses"] == 5:
                    print(f"  {time.strftime('%H:%M:%S')}  Re-entering PPG mode "
                          f"(ring may have timed out)...")
                    try:
                        await enter_ppg_mode(client, q)
                        pipeline.reset_filters()
                        stats["misses"] = 0
                        print(f"  {time.strftime('%H:%M:%S')}  PPG mode re-entered.")
                    except Exception as e:
                        print(f"  {time.strftime('%H:%M:%S')}  Re-entry failed: {e}")
                continue

        if raw_frame is None:
            continue

        # ── Parse + pipeline ─────────────────────────────────────────────────
        stats["misses"] = 0
        ppg_frame = parse_0x13(raw_frame)
        if ppg_frame is None:
            stats["parse_errors"] += 1
            continue

        # Gap detection
        if stats["prev_seq"] is not None:
            expected = (stats["prev_seq"] + 1) % 256
            if ppg_frame.seq != expected:
                gap = (ppg_frame.seq - stats["prev_seq"] - 1) % 256
                stats["seq_gaps"] += gap
                if gap > 0:
                    print(f"  {time.strftime('%H:%M:%S')}  *** GAP: {gap} missing frames ***")
        stats["prev_seq"] = ppg_frame.seq

        # Optical health check — mirrors the four-way gate in SpO2Estimator.
        # dc_B = RED (chB), dc_C = IR (chC). Both channels must be in calibrated zone.
        dc_B = abs(sum(ppg_frame.chB) / len(ppg_frame.chB)) if ppg_frame.chB else 0
        dc_C = abs(sum(ppg_frame.chC) / len(ppg_frame.chC)) if ppg_frame.chC else 0
        ratio_bc = dc_C / dc_B if dc_B > 0 else float("inf")
        red_out_of_range = (dc_B < 300 or dc_B > 800
                            or ratio_bc > 4.0 or ratio_bc < 0.28)

        # IR dead-zone recovery: if IR is completely suppressed (chC_DC < 50) for
        # 60+ consecutive frames (~2.4s), re-enter PPG mode. The stream keeps running
        # (no RSP 0x13 miss) so the normal 15-miss trigger never fires, but the AGC
        # has given up on IR. Re-entry resets the optical AGC to a better initial state.
        # Observed: 18:41 session had chC_DC=0-20 from re-entry onward — never recovered.
        if dc_C < 50:
            stats["ir_dead_frames"] = stats.get("ir_dead_frames", 0) + 1
        else:
            stats["ir_dead_frames"] = 0
        if stats.get("ir_dead_frames", 0) == 60:
            print(f"  {time.strftime('%H:%M:%S')}  [IR DEAD] chC_DC={dc_C:.0f} for 60+ frames "
                  f"— re-entering PPG mode to reset optical AGC...")
            try:
                await enter_ppg_mode(client, q)
                pipeline.reset_filters()
                stats["ir_dead_frames"] = 0
                stats["misses"] = 0
                print(f"  {time.strftime('%H:%M:%S')}  PPG mode re-entered (IR AGC reset).")
            except Exception as e:
                print(f"  {time.strftime('%H:%M:%S')}  Re-entry failed: {e}")

        if not stats.get("red_warned") and red_out_of_range:
            if dc_B > 800:
                reason = f"chB_DC={dc_B:.0f} too high (>800, RED overcalibrated; SpO2 >100%)"
            elif dc_B < 300:
                reason = f"chB_DC={dc_B:.0f} too low (<300, RED suppressed)"
            elif ratio_bc > 4.0:
                reason = f"IR/RED ratio={ratio_bc:.1f} too high (>4, IR overcalibrated)"
            else:
                reason = (f"IR/RED ratio={ratio_bc:.2f} too low (<0.28, "
                          f"chC_DC={dc_C:.0f} suppressed — SpO2 clamps to 100%)")
            print(f"  {time.strftime('%H:%M:%S')}  [OPTICAL OUT-OF-RANGE] {reason} — SpO2 blocked")
            stats["red_warned"] = True
        if stats.get("red_warned") and not red_out_of_range:
            print(f"  {time.strftime('%H:%M:%S')}  [OPTICAL IN RANGE] "
                  f"chB_DC={dc_B:.0f} chC_DC={dc_C:.0f} ratio={ratio_bc:.2f} — SpO2 active")
            stats["red_warned"] = False

        windows = pipeline.feed_frame(ppg_frame)
        for w in windows:
            stats["frames"] += 1
            if w.saturated:
                stats["agc_events"] += 1

            # ── CSV write (raw + filtered, per sample) ────────────────────────
            wall = w.wall_time
            hr_str = f"{w.hr_fft_bpm:.1f}" if w.hr_fft_bpm else ""
            spo2_str = f"{w.spo2_pct:.1f}" if w.spo2_pct else ""
            for i in range(FRAME_SIZE):
                writer.writerow([
                    f"{wall:.3f}",
                    w.seq,
                    stats["sample_idx"] + i,
                    w.chA_raw[i],
                    w.chB_raw[i],
                    w.chC_raw[i],
                    f"{w.chA_filtered[i]:.4f}",
                    f"{w.chB_filtered[i]:.4f}",
                    f"{w.chC_filtered[i]:.4f}",
                    hr_str,
                    spo2_str,
                    1 if w.contact else 0,
                    1 if w.saturated else 0,
                ])
            csv_file.flush()
            stats["sample_idx"] += FRAME_SIZE

            # ── Console display (every frame) ─────────────────────────────────
            ac_dc_pct = (100 * w.chA_ac / w.chA_dc) if w.chA_dc > 0 else 0
            contact_str = "YES    " if w.contact else "NO-CONT"
            hr_disp = f"{w.hr_fft_bpm:>6.1f}bpm" if w.hr_fft_bpm else "  ---   "
            spo2_disp = f"{w.spo2_pct:>5.1f}%" if w.spo2_pct else "  ---  "
            gt_disp = (f"{ground_truth_hr}bpm/{ground_truth_spo2}%"
                       if ground_truth_hr else "  ---  ")
            status = "[AGC]" if w.saturated else ""
            red_str = f"R{w.chB_dc:>4.0f}" if w.chB_dc > 0 else "R   0"
            ir_str  = f"I{w.chC_dc:>4.0f}" if w.chC_dc > 0 else "I   0"

            print(f"  {time.strftime('%H:%M:%S')}  {w.seq:>4}  "
                  f"{w.chA_dc:>6.0f}  {red_str}  {ir_str}  {ac_dc_pct:>5.1f}%  {contact_str}  "
                  f"{hr_disp}  {spo2_disp}  {gt_disp:>8}  {status}")


# ── Top-level session manager ────────────────────────────────────────────────

async def run(addr: str, duration: float, output: str, reconnect: bool) -> None:
    pipeline = PPGPipeline()
    q: asyncio.Queue = asyncio.Queue()
    t_start = time.monotonic()

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = output or f"ppg_capture_{ts}.csv"

    stats = {
        "frames": 0, "agc_events": 0, "misses": 0, "reconnects": 0,
        "parse_errors": 0, "seq_gaps": 0, "sample_idx": 0, "prev_seq": None,
    }

    print(f"\n=== RingConn Stage 1 PPG Capture ===")
    print(f"  Ring UUID  : {addr}")
    print(f"  Duration   : {duration:.0f}s")
    print(f"  Output CSV : {out_path}")
    print(f"  Pipeline   : AGC detection → 0.5-8 Hz Butterworth IIR → FFT HR (10s) → SpO2")
    print(f"  SpO2 cal   : formula 110-19.05×R. AW=98% refs: 17:21→ring96%(chB=683,-2%), 17:35→ring97.6%(chB=334,-0.4%), 18:32→ring98-99%(chB=777,+1%). ±2%.")

    with open(out_path, "w", newline="") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow([
            "wall_clock_s", "seq", "sample_idx",
            "chA_raw", "chB_raw", "chC_raw",
            "chA_filt", "chB_filt", "chC_filt",
            "hr_fft_bpm", "spo2_pct", "contact", "saturated",
        ])
        csv_file.flush()

        attempt = 0
        while time.monotonic() - t_start < duration:
            attempt += 1
            if attempt > 1:
                if not reconnect or stats["reconnects"] >= MAX_RECONNECT_ATTEMPTS:
                    print("\nMax reconnect attempts reached — stopping.")
                    break
                print(f"\n  Reconnecting in {RECONNECT_WAIT_S:.0f}s "
                      f"(attempt {stats['reconnects'] + 1}/{MAX_RECONNECT_ATTEMPTS})...")
                await asyncio.sleep(RECONNECT_WAIT_S)
                pipeline.reset_filters()

            try:
                device = await session._resolve(addr, timeout=15.0)
                print(f"\n  Connecting...")
                async with BleakClient(device) as client:
                    print(f"  Connected.")
                    await client.start_notify(
                        ble.NOTIFY_CHAR,
                        lambda _s, d: q.put_nowait(bytes(d))
                    )
                    await asyncio.sleep(0.3)

                    # Auth
                    if not await authenticate(client, q):
                        print("  Auth FAILED — check ring is in range and charged")
                        stats["reconnects"] += 1
                        continue
                    print("  Auth OK")

                    # Drain pending history
                    await client.write_gatt_char(
                        ble.WRITE_CHAR, ble.SYNC_ALL, response=True)
                    await drain(client, q, 2.0)
                    await client.write_gatt_char(
                        ble.WRITE_CHAR, bytes.fromhex("070000"), response=True)
                    await drain(client, q, 3.0)
                    await client.write_gatt_char(
                        ble.WRITE_CHAR, bytes.fromhex("d00000"), response=True)
                    await drain(client, q, 1.0)
                    while not q.empty():
                        q.get_nowait()

                    # Enter PPG mode
                    ack = await enter_ppg_mode(client, q)
                    push_mode = ack  # if ack received, ring is in push mode
                    print(f"  PPG mode active (ACK={ack}, push={'likely' if push_mode else 'unclear'})")

                    # Flush startup buffer, then wait for AGC to stabilize.
                    # The ring delivers backlogged frames all at once on connect, causing
                    # a mid-capture burst that corrupts the zero-phase filter and spikes
                    # FFT to 192 bpm. After flushing we also wait for chB (RED LED) to
                    # reach a healthy DC level before starting the timed session — AGC
                    # starts with per-channel gain mismatched and takes several seconds
                    # to settle. Waiting here avoids recording RED-suppressed data at
                    # the start of every session (observed chB_DC=17 in first 10-30s).
                    print("  Flushing startup buffer + waiting for AGC settle (max 15s)...")
                    flush_deadline = time.monotonic() + 15.0
                    flushed = 0
                    agc_ok = False
                    while time.monotonic() < flush_deadline:
                        try:
                            b = await asyncio.wait_for(q.get(), timeout=0.5)
                            if b[0] != 0x13:
                                continue
                            flushed += 1
                            # Decode chB and chC DC from this frame to check AGC health
                            if len(b) >= 10:
                                samples_b = [
                                    int.from_bytes(b[6 + i*6 + 2: 6 + i*6 + 4],
                                                   'big', signed=True)
                                    for i in range(25) if 6 + i*6 + 4 <= len(b) - 3
                                ]
                                samples_c = [
                                    int.from_bytes(b[6 + i*6 + 4: 6 + i*6 + 6],
                                                   'big', signed=True)
                                    for i in range(25) if 6 + i*6 + 6 <= len(b) - 3
                                ]
                                if samples_b and samples_c:
                                    dc_b = abs(sum(samples_b) / len(samples_b))
                                    dc_c = abs(sum(samples_c) / len(samples_c))
                                    ratio = dc_c / dc_b if dc_b > 0 else 0
                                    if 300 <= dc_b <= 800 and 0.28 <= ratio < 4.0:
                                        agc_ok = True
                                        break  # both RED and IR in calibrated zone
                        except asyncio.TimeoutError:
                            continue  # keep trying until flush_deadline
                    if agc_ok:
                        print(f"  AGC settled after {flushed} startup frames "
                              f"(RED+IR both calibrated: 300≤chB_DC≤800, 0.3≤IR/RED<4)")
                    else:
                        print(f"  AGC not settled after 15s ({flushed} frames flushed) "
                              f"— RED or IR out of calibrated zone; SpO2 will be blocked")

                    await stream_session(
                        client, q, pipeline, writer, csv_file,
                        stats, duration, t_start
                    )
                    # Clean exit — no reconnect needed
                    break

            except (BleakError, asyncio.TimeoutError) as e:
                stats["reconnects"] += 1
                print(f"\n  BLE error: {e}")
                if not reconnect:
                    break

    # ── Session summary ──────────────────────────────────────────────────────
    elapsed = time.monotonic() - t_start
    print(f"\n{'='*60}")
    print(f"Session Summary")
    print(f"  Duration         : {elapsed:.1f}s")
    print(f"  Frames captured  : {stats['frames']}  "
          f"({stats['frames'] * FRAME_SIZE} samples, "
          f"~{stats['frames'] * FRAME_SIZE / 25:.1f}s at 25Hz)")
    print(f"  AGC events       : {stats['agc_events']} frames (interpolated)")
    print(f"  Seq gaps         : {stats['seq_gaps']} missing frames")
    print(f"  Parse errors     : {stats['parse_errors']}")
    print(f"  BLE reconnects   : {stats['reconnects']}")
    print(f"  CSV written      : {out_path}")
    print(f"\nNext steps:")
    print(f"  1. Run identify_channels.py to confirm green/red/IR channel assignment")
    print(f"  2. Run analyze_ppg_13.py {out_path} for waveform + FFT plots")
    print(f"  3. Compare FFT HR against ring app (or CMD 0x29 column in CSV)")
    print(f"  4. Calibrate SpO2 formula against a pulse oximeter")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("addr", help="CBPeripheral UUID from `opencircuit scan`")
    p.add_argument("--duration", type=float, default=300.0,
                   help="capture duration in seconds (default 300 = 5 min)")
    p.add_argument("--output", default="",
                   help="output CSV filename (default: ppg_capture_<timestamp>.csv)")
    p.add_argument("--no-reconnect", action="store_true",
                   help="exit immediately on BLE drop instead of reconnecting")
    args = p.parse_args()
    asyncio.run(run(args.addr, args.duration, args.output,
                    reconnect=not args.no_reconnect))


if __name__ == "__main__":
    main()
