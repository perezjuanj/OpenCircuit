"""Parameterized probe for BleRealTimePPGRspMixin (opcode 0x16).

The full XX 00 00 sweep found NO response for any PPG candidate (0x94/0x96/0x14/0x16/
0x13/0x17/0x18/0x19). This means raw PPG requires a NON-ZERO parameter payload, a
preceding mode entry, or both.

Target: RSP opcode 0x16 = BleRealTimePPGRspMixin
  CMD = RSP XOR 0x80 = 0x96
  But 0x96 00 00 → no response. Try with parameter bytes.

Strategy: enter mode01 (HR+SpO2 cycle, green→red LED visible) FIRST, then send 0x96
with various param bytes. Also try 0x94 (another PPG candidate) with params.

Wear the ring during this probe — the ring refused mode04 ("not worn"), and PPG
streaming almost certainly requires proximity/contact detection to be satisfied.

    .venv/bin/python probe_ppg_params.py <CBPeripheral-UUID>
"""
from __future__ import annotations
import asyncio, sys, time
from bleak import BleakClient
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

ADDR = sys.argv[1] if len(sys.argv) > 1 else None

# Probes: (label, hex_command, wait_s)
# Grouped by approach. Each is tried after the mode01 sequence is active.
PROBES = [
    # ── CMD 0x96 variants (RSP 0x16 = BleRealTimePPGRspMixin) ───────────────
    ("96_00_00",   "960000", 2.0),   # baseline (already known → no response)
    ("96_01_00",   "960100", 2.0),   # enable=1, param=0
    ("96_01_01",   "960101", 2.0),   # enable=1, sample_rate=1?
    ("96_01_02",   "960102", 2.0),   # enable=1, sample_rate=2?
    ("96_01_04",   "960104", 2.0),   # enable=1, rate=4?
    ("96_01_19",   "960119", 2.0),   # enable=1, rate=25Hz (0x19)?
    ("96_01_32",   "960132", 2.0),   # enable=1, rate=50Hz (0x32)?
    ("96_FF_FF",   "96FFFF", 2.0),   # broadcast request / debug mode
    ("96_00_01",   "960001", 2.0),   # alt layout: param1=0, enable=1
    # ── CMD 0x94 variants (another PPG candidate) ────────────────────────────
    ("94_00_00",   "940000", 2.0),
    ("94_01_00",   "940100", 2.0),
    ("94_01_01",   "940101", 2.0),
    ("94_FF_FF",   "94FFFF", 2.0),
    # ── CMD 0x16 directly (maybe the pattern is cmd=rsp, not cmd=rsp^80) ────
    ("16_00_00",   "160000", 2.0),
    ("16_01_00",   "160100", 2.0),
    ("16_01_01",   "160101", 2.0),
    # ── CMD 0x93 / 0x13 (realtime start variants?) ──────────────────────────
    ("93_01_00",   "930100", 2.0),
    ("93_01_01",   "930101", 2.0),
    ("13_01_00",   "130100", 2.0),
    # ── CMD 0x0D with params (0x0D triggered 0x4D batch; what about 0x0D 01?) ──
    ("0D_01_00",   "0D0100", 2.0),
    ("0D_01_01",   "0D0101", 2.0),
    # ── CMD 0x30 with params (new — RSP 0x0B) ────────────────────────────────
    ("30_01_00",   "300100", 2.0),
    ("30_01_01",   "300101", 2.0),
    # ── After mode07 entry (batch mode) — does 0x96 work then? ───────────────
    # These are tried after re-entering mode07
]

# Which opcodes would indicate PPG / novel data
PPG_OPCODES = {0x13, 0x14, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F}
KNOWN_SPARSE = {0x10, 0x11, 0x15, 0x47, 0x4A, 0x4C, 0x4D, 0x4E, 0x50,
                0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0xA9, 0xAB, 0x0B}


async def main(addr: str) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)

    async with BleakClient(device) as client:
        print(f"\nConnected: {addr}")
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        async def w(hexstr: str, label: str = "") -> None:
            print(f"  TX {hexstr:<20} {label}")
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(hexstr), response=True)

        async def drain(timeout: float, label: str = "") -> list[bytes]:
            frames = []
            while True:
                try:
                    b = await asyncio.wait_for(q.get(), timeout=timeout)
                except asyncio.TimeoutError:
                    break
                frames.append(bytes(b))
                flag = ""
                if b[0] in PPG_OPCODES:
                    flag = "  !!! PPG CANDIDATE !!!"
                elif b[0] not in KNOWN_SPARSE:
                    flag = "  *** NOVEL ***"
                print(f"     RX [{b[0]:#04x}] {b.hex(' ')}{flag}")
                if b[0] == 0x47:
                    await w("c70000", "(ack 47)")
                elif b[0] == 0x4C:
                    await w("cc0000", "(ack 4c)")
            return frames

        # Auth
        print("\n--- AUTH ---")
        mac = None
        try:
            raw = await client.read_gatt_char(SYSID_CHAR)
            mac = mac_from_sysid(bytes(raw))
            print(f"  MAC: {':'.join(f'{b:02X}' for b in mac)}")
        except Exception as e:
            print(f"  sysid failed: {e}")

        await w("010000")
        await asyncio.sleep(0.3)
        challenge_frame = None
        while not q.empty():
            b = q.get_nowait()
            print(f"     RX {b.hex(' ')}")
            if len(b) >= 3 and b[0] == 0x81:
                challenge_frame = b
        if challenge_frame and mac:
            cmd = auth_command(challenge_frame[2], mac)
            await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            await asyncio.sleep(0.3)
            while not q.empty():
                q.get_nowait()
            print("  Auth OK")

        # History drain
        print("\n--- DRAIN ---")
        await w(ble.SYNC_ALL.hex()); await drain(2.0)
        await w("070000"); await drain(3.0)
        await w("d00000"); await drain(1.0)

        # Enter mode01 — starts the HR/SpO2 measurement cycle (green → red LED)
        # From capture_app_session.py we know this triggers 0x15 streaming + background SpO2
        print("\n--- ENTER MODE01 (HR+SpO2 cycle — WEAR RING NOW) ---")
        await w("060100", "HR+SpO2 mode"); await drain(2.0)
        await w("070000"); await drain(1.0)
        print("  Waiting 3s for ring to start measuring (watch for red/green LED)...")
        await asyncio.sleep(3.0)
        await drain(0.5)  # flush any spontaneous 0x15 frames

        # Now probe all parameterized variants
        print("\n--- PARAMETERIZED PPG PROBES ---")
        ppg_hits: list[tuple[str, bytes]] = []

        for label, hexcmd, wait in PROBES:
            # Keepalive before each probe
            try:
                await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("950000"), response=True)
                await asyncio.sleep(0.1)
                while not q.empty():
                    q.get_nowait()
            except Exception:
                pass

            print(f"\n  probe {label}: TX {hexcmd}")
            await w(hexcmd, label)
            frames = await drain(wait, label)

            for fr in frames:
                if fr[0] in PPG_OPCODES:
                    ppg_hits.append((label, fr))
                    print(f"  !!!!! PPG OPCODE 0x{fr[0]:02X} FOUND after {label} !!!!!")

        # Re-probe after mode07 (batch mode) — different state might unlock PPG
        print("\n--- RE-ENTER MODE07 THEN RETRY TOP PPG CANDIDATES ---")
        await w("060700", "mode07"); await drain(2.0)
        await asyncio.sleep(2.0)

        for label, hexcmd, wait in [("96_01_00_after_m7", "960100", 2.0),
                                    ("96_01_01_after_m7", "960101", 2.0),
                                    ("94_01_00_after_m7", "940100", 2.0)]:
            print(f"\n  retry {label}: TX {hexcmd}")
            await w(hexcmd, label)
            frames = await drain(wait, label)
            for fr in frames:
                if fr[0] in PPG_OPCODES:
                    ppg_hits.append((label, fr))

        await client.stop_notify(ble.NOTIFY_CHAR)

    print(f"\n{'='*60}")
    if ppg_hits:
        print("*** PPG OPCODE FOUND! ***")
        for label, fr in ppg_hits:
            print(f"  {label}: [{fr[0]:#04x}] {fr.hex(' ')}")
        print("\nNext: decode the frame structure (length, sample rate, channel count)")
    else:
        print("No PPG opcode triggered by any parameterized probe.")
        print()
        print("Remaining paths:")
        print("  1. iPhone HCI capture during app manual HR Measure (different trigger)")
        print("  2. Android APK decompile — find BleRealTimePPGRspMixin command bytes")
        print("  3. 0x96 with longer payloads (4+ bytes, structured params)")


if __name__ == "__main__":
    if ADDR is None:
        print("Usage: .venv/bin/python probe_ppg_params.py <CBPeripheral-UUID>")
        print("       WEAR THE RING during this probe — proximity may be required.")
        sys.exit(1)
    asyncio.run(main(ADDR))
