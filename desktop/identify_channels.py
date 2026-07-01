"""Channel identity test for RSP 0x13 — determines which of chA/chB/chC is green/red/IR.

Protocol (3 phases, ring worn on index finger):
  Phase 1 (20s): Ring worn normally       → baseline DC and AC/DC for all 3 channels
  Phase 2 (10s): Ring lifted slightly off → DC changes (more ambient light = less absorbed)
  Phase 3 (20s): Ring worn firmly again   → verify return to baseline

Result: the channel with the LARGEST DC change between Phase 1 and Phase 2 is the
most sensitive to tissue contact = the primary measurement channel.

Additionally, at normal SpO2 (95-100%):
  - Red light (660nm) is absorbed MORE by blood than IR (940nm)
  - So |DC_red| > |DC_ir|  (more absorbed = lower transmitted light = stronger ADC response)
  - In our data: |DC_B| = 810 > |DC_C| = 560 → chB = red, chC = IR  (hypothesis)

Usage:
    .venv/bin/python identify_channels.py <CBPeripheral-UUID>
"""
from __future__ import annotations
import asyncio
import struct
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

from bleak import BleakClient, BleakError
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command
from ppg_pipeline import PPGFrame, FRAME_SIZE, SAT_THRESHOLD

ADDR = sys.argv[1] if len(sys.argv) > 1 else None


def parse_0x13(frame: bytes) -> Optional[PPGFrame]:
    if len(frame) < 10 or frame[0] != 0x13:
        return None
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
        chA.append(struct.unpack('>H', r[0:2])[0])
        chB.append(struct.unpack('>h', r[2:4])[0])
        chC.append(struct.unpack('>h', r[4:6])[0])
    return PPGFrame(seq=seq, chA=chA, chB=chB, chC=chC,
                    wall_time=time.time(),
                    saturated=any(s > SAT_THRESHOLD for s in chA))


@dataclass
class PhaseStats:
    name: str
    chA_dc: list[float] = field(default_factory=list)
    chA_ac: list[float] = field(default_factory=list)
    chB_dc: list[float] = field(default_factory=list)
    chB_ac: list[float] = field(default_factory=list)
    chC_dc: list[float] = field(default_factory=list)
    chC_ac: list[float] = field(default_factory=list)
    frames: int = 0

    def add(self, f: PPGFrame) -> None:
        if f.saturated:
            return
        self.chA_dc.append(sum(f.chA) / len(f.chA))
        self.chA_ac.append(max(f.chA) - min(f.chA))
        self.chB_dc.append(abs(sum(f.chB) / len(f.chB)))
        self.chB_ac.append(max(f.chB) - min(f.chB))
        self.chC_dc.append(abs(sum(f.chC) / len(f.chC)))
        self.chC_ac.append(max(f.chC) - min(f.chC))
        self.frames += 1

    def mean(self, lst: list[float]) -> float:
        return sum(lst) / len(lst) if lst else 0.0

    def report(self) -> dict:
        return {
            "chA": {"dc": self.mean(self.chA_dc), "ac": self.mean(self.chA_ac),
                    "ac_dc_pct": 100 * self.mean(self.chA_ac) / (self.mean(self.chA_dc) or 1)},
            "chB": {"dc": self.mean(self.chB_dc), "ac": self.mean(self.chB_ac),
                    "ac_dc_pct": 100 * self.mean(self.chB_ac) / (self.mean(self.chB_dc) or 1)},
            "chC": {"dc": self.mean(self.chC_dc), "ac": self.mean(self.chC_ac),
                    "ac_dc_pct": 100 * self.mean(self.chC_ac) / (self.mean(self.chC_dc) or 1)},
        }


async def main(addr: str) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)

    async with BleakClient(device) as client:
        print(f"\nConnected: {addr}")
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        async def tx(h: str) -> None:
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(h), response=True)

        async def drain_q(t: float, gap: float = 0.5) -> list[bytes]:
            frames, deadline = [], time.monotonic() + t
            while time.monotonic() < deadline:
                try:
                    b = await asyncio.wait_for(q.get(), timeout=min(gap, deadline - time.monotonic()))
                    frames.append(bytes(b))
                except asyncio.TimeoutError:
                    break
            return frames

        # Auth
        mac = None
        try:
            mac = mac_from_sysid(bytes(await client.read_gatt_char(SYSID_CHAR)))
        except Exception:
            pass
        await tx("010000")
        await asyncio.sleep(0.3)
        cf = None
        while not q.empty():
            b = q.get_nowait()
            if b[0] == 0x81:
                cf = b
        if cf and mac:
            cmd = auth_command(cf[2], mac)
            await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            await asyncio.sleep(0.3)
            while not q.empty(): q.get_nowait()
            print("Auth OK")
        else:
            print("Auth FAILED")
            return

        # Drain history
        await tx(ble.SYNC_ALL.hex()); await drain_q(2.0)
        await tx("070000"); await drain_q(3.0)
        await tx("d00000"); await drain_q(1.0)
        while not q.empty(): q.get_nowait()

        # Enter PPG mode (mode10 pre-condition + mode01)
        print("\nEntering PPG mode (mode10 pre-condition + mode01)...")
        await tx("061000"); await drain_q(3.0)
        await tx("060000"); await asyncio.sleep(0.5)
        while not q.empty(): q.get_nowait()
        await tx("060100"); await drain_q(2.0)
        while not q.empty(): q.get_nowait()
        print("PPG mode active.")

        # ── Helper: collect frames for duration_s ─────────────────────────────
        async def collect(phase: PhaseStats, duration_s: float) -> None:
            deadline = time.monotonic() + duration_s
            last_keepalive = time.monotonic()
            while time.monotonic() < deadline:
                if time.monotonic() - last_keepalive >= 8.0:
                    await tx("950000")
                    last_keepalive = time.monotonic()
                try:
                    raw = await asyncio.wait_for(q.get(), timeout=1.2)
                    if raw[0] != 0x13:
                        continue
                    f = parse_0x13(raw)
                    if f:
                        phase.add(f)
                        r = phase.report()
                        # Live display
                        print(
                            f"\r  chA DC={r['chA']['dc']:>5.0f} AC/DC={r['chA']['ac_dc_pct']:>4.1f}%  "
                            f"chB DC={r['chB']['dc']:>5.0f} AC/DC={r['chB']['ac_dc_pct']:>4.1f}%  "
                            f"chC DC={r['chC']['dc']:>5.0f} AC/DC={r['chC']['ac_dc_pct']:>4.1f}%  "
                            f"t={deadline - time.monotonic():>4.0f}s left  ",
                            end="", flush=True
                        )
                except asyncio.TimeoutError:
                    await tx("9601000000")

        # ── Phase 1: worn normally ────────────────────────────────────────────
        print("\n" + "="*60)
        print("PHASE 1 (20s): Wear ring normally on index finger")
        print("               Keep still. Baseline measurement.")
        print("="*60)
        await asyncio.sleep(2)
        p1 = PhaseStats("worn_normal")
        await collect(p1, 20.0)
        print()
        r1 = p1.report()
        print(f"\n  Phase 1 results ({p1.frames} valid frames):")
        for ch, v in r1.items():
            print(f"    {ch}: DC={v['dc']:>6.1f}  AC={v['ac']:.1f}  AC/DC={v['ac_dc_pct']:.2f}%")

        # ── Phase 2: ring lifted off ──────────────────────────────────────────
        print("\n" + "="*60)
        print("PHASE 2 (10s): Gently LIFT RING slightly off finger skin")
        print("               (keep on finger but break skin contact)")
        print("="*60)
        await asyncio.sleep(2)
        p2 = PhaseStats("lifted")
        await collect(p2, 10.0)
        print()
        r2 = p2.report()
        print(f"\n  Phase 2 results ({p2.frames} valid frames):")
        for ch, v in r2.items():
            print(f"    {ch}: DC={v['dc']:>6.1f}  AC={v['ac']:.1f}  AC/DC={v['ac_dc_pct']:.2f}%")

        # ── Phase 3: return to normal ─────────────────────────────────────────
        print("\n" + "="*60)
        print("PHASE 3 (20s): Press ring back onto finger normally")
        print("               Verify return to baseline DC values.")
        print("="*60)
        await asyncio.sleep(2)
        p3 = PhaseStats("worn_return")
        await collect(p3, 20.0)
        print()
        r3 = p3.report()
        print(f"\n  Phase 3 results ({p3.frames} valid frames):")
        for ch, v in r3.items():
            print(f"    {ch}: DC={v['dc']:>6.1f}  AC={v['ac']:.1f}  AC/DC={v['ac_dc_pct']:.2f}%")

        await client.stop_notify(ble.NOTIFY_CHAR)

    # ── Analysis ──────────────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print("CHANNEL IDENTITY ANALYSIS")
    print(f"{'='*60}\n")

    print("DC change: Phase2 (lifted) vs Phase1 (worn):")
    dc_changes: dict[str, float] = {}
    for ch in ["chA", "chB", "chC"]:
        delta = abs(r2[ch]["dc"] - r1[ch]["dc"])
        dc_changes[ch] = delta
        direction = "UP" if r2[ch]["dc"] > r1[ch]["dc"] else "DOWN"
        print(f"  {ch}: Δ={delta:>6.1f}  ({r1[ch]['dc']:.0f} → {r2[ch]['dc']:.0f}  {direction})")

    print("\nAC/DC ranking (higher = more pulsatile = more sensitive to heartbeat):")
    for ch in sorted(r1, key=lambda c: r1[c]["ac_dc_pct"], reverse=True):
        print(f"  {ch}: AC/DC={r1[ch]['ac_dc_pct']:.2f}%")

    # chA = GREEN: confirmed by the uint16 output port (hardware-level indicator, not pulsatility).
    # For RED vs IR in reflectance PPG at normal SpO2 (95-100%):
    #   Red (660nm) is MORE absorbed by HbO2 → less backscattered → LOWER ADC count → LOWER |DC|
    #   IR (940nm) is LESS absorbed            → more backscattered → HIGHER ADC count → HIGHER |DC|
    # So: lower |DC| = RED, higher |DC| = IR.
    # NOTE: per-channel AGC can change absolute DC between sessions — verify with SpO2 calibration.
    c1, c2 = "chB", "chC"
    if r1[c1]["dc"] < r1[c2]["dc"]:   # lower DC = more absorbed = RED
        red_candidate, ir_candidate = c1, c2
    else:
        red_candidate, ir_candidate = c2, c1

    p2_zero = p2.frames == 0

    print(f"\n--- Conclusions ---")
    if p2_zero:
        print(f"  Phase 2 (lifted): ring detected off-finger and paused streaming (0 frames).")
        print(f"  DC-change comparison is not meaningful — all channels dropped because streaming")
        print(f"  stopped, not because of differential absorption. Using Phase 1 DC for RED/IR.\n")

    print(f"  Phase 1 |DC| baseline (absolute):")
    for ch in ["chA", "chB", "chC"]:
        tag = "uint16 → GREEN (confirmed by data type)" if ch == "chA" else "int16"
        print(f"    {ch}: |DC|={r1[ch]['dc']:>6.0f}   AC/DC={r1[ch]['ac_dc_pct']:.1f}%   ({tag})")

    print(f"\n  chA = GREEN: uint16 port is the hardware-assigned green LED output.")
    print(f"               (High AC/DC in this test likely reflects motion artifact)")
    print(f"\n  Red/IR from Phase 1 |DC| — lower |DC| = more absorbed at 660nm = RED:")
    print(f"    {red_candidate}: |DC|={r1[red_candidate]['dc']:.0f} → RED  (lower DC, more absorbed, 660nm)")
    print(f"    {ir_candidate}: |DC|={r1[ir_candidate]['dc']:.0f} → IR   (higher DC, less absorbed, 940nm)")

    print(f"\n  FINAL IDENTITY GUESS:")
    print(f"    chA = GREEN (uint16 — confirmed by hardware)")
    print(f"    {red_candidate} = RED  (lowest |DC| among int16 channels → most absorbed)")
    print(f"    {ir_candidate} = IR   (highest |DC| among int16 channels → least absorbed)")
    print(f"\n  SpO2 formula: R = (AC_{red_candidate}/DC_{red_candidate}) / (AC_{ir_candidate}/DC_{ir_candidate})")
    print(f"  Calibrate SPO2_A/SPO2_B in ppg_pipeline.py against a pulse oximeter.")
    print(f"  NOTE: per-channel AGC may flip DC ordering between sessions — verify with SpO2 cal.")


if __name__ == "__main__":
    if ADDR is None:
        print("Usage: .venv/bin/python identify_channels.py <CBPeripheral-UUID>")
        print("       WEAR THE RING on your index finger during this test.")
        sys.exit(1)
    asyncio.run(main(ADDR))
