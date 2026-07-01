"""Quick smoke-test for RSP 0x13 with mode10 pre-conditioning.

Runs the minimal sequence needed to get RSP 0x13 — without the full 60s stream.
Useful to verify the pre-conditioning fix before a long capture run.

Expected output (ring worn):
  mode10 pre-condition: ACK 86 00 86
  mode01 entry: ACK 86 00 86 + 0x10 status
  attempt 1: RX 0x13 ... *** RSP 0x13 CONFIRMED ***

If still 0 frames: the pre-condition hypothesis is wrong. Try:
  1. Poll 96 01 00 00 00 while still in mode10 (before exiting)
  2. Check if mode11/12/13 alone also work (bisect which mode is required)

Usage:
    .venv/bin/python debug_ppg_mode10.py <CBPeripheral-UUID>
"""
from __future__ import annotations
import asyncio, sys, struct, time
from bleak import BleakClient, BleakError
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

ADDR = sys.argv[1] if len(sys.argv) > 1 else None


async def main(addr: str) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)

    async with BleakClient(device) as client:
        print(f"\nConnected: {addr}")
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        async def tx(h: str, lbl: str = "") -> None:
            if lbl:
                print(f"  TX {h}  [{lbl}]")
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(h), response=True)

        async def drain(t: float) -> list[bytes]:
            frames = []
            deadline = time.monotonic() + t
            while time.monotonic() < deadline:
                try:
                    b = await asyncio.wait_for(q.get(), timeout=min(deadline - time.monotonic(), 0.5))
                    frames.append(bytes(b))
                    flag = "  *** RSP 0x13 ***" if b[0] == 0x13 else ""
                    print(f"     RX [{b[0]:#04x}] {b.hex(' ')}{flag}")
                    if b[0] == 0x47: await tx("c70000")
                    elif b[0] == 0x4C: await tx("cc0000")
                except asyncio.TimeoutError:
                    break
            return frames

        async def keepalive() -> None:
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("950000"), response=True)
            await asyncio.sleep(0.1)
            while not q.empty(): q.get_nowait()

        # Auth
        print("\n--- AUTH ---")
        mac = None
        try:
            mac = mac_from_sysid(bytes(await client.read_gatt_char(SYSID_CHAR)))
            print(f"  MAC: {':'.join(f'{b:02X}' for b in mac)}")
        except Exception as e:
            print(f"  sysid error: {e}")
        await tx("010000")
        await asyncio.sleep(0.3)
        challenge = None
        while not q.empty():
            b = q.get_nowait()
            if b[0] == 0x81: challenge = b
        if challenge and mac:
            cmd = auth_command(challenge[2], mac)
            await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            await asyncio.sleep(0.3)
            while not q.empty(): q.get_nowait()
            print("  Auth OK")
        else:
            print("  Auth FAILED — check MAC/challenge")
            return

        # Drain pending history
        print("\n--- DRAIN ---")
        await tx(ble.SYNC_ALL.hex()); await drain(2.0)
        await tx("070000"); await drain(3.0)
        await tx("d00000"); await drain(1.0)
        while not q.empty(): q.get_nowait()

        # Mode10 pre-condition
        print("\n--- MODE 0x10 PRE-CONDITION ---")
        await tx("061000", "enter mode10")
        frames = await drain(3.0)
        ack = [f for f in frames if f[0] == 0x86]
        if ack and ack[0][2] == 0x00:
            print("  mode10 ACCEPTED (86 00 86) ✓")
        elif ack:
            print(f"  mode10 response: {ack[0].hex(' ')} — may be rejected")
        else:
            print("  mode10: no ACK received")
        await tx("060000", "exit mode10")
        await asyncio.sleep(0.5)
        while not q.empty(): q.get_nowait()

        # Enter mode01
        print("\n--- ENTER MODE01 ---")
        await tx("060100", "enter mode01")
        await drain(2.0)
        await asyncio.sleep(1.5)
        while not q.empty(): q.get_nowait()
        print("  mode01 active — 3s warmup done")

        # Try 5 fetches
        print("\n--- PPG FETCH ATTEMPTS ---")
        success = False
        for attempt in range(5):
            print(f"\n  attempt {attempt + 1}:")
            await keepalive()
            await tx("9601000000", "96 01 fetch")
            frames = await drain(2.0)
            ppg = [f for f in frames if f[0] == 0x13]
            if ppg:
                f = ppg[0]
                seq = f[2]
                n_records = (len(f) - 10) // 6
                print(f"  *** RSP 0x13 CONFIRMED — seq={seq}, {n_records} records, len={len(f)} ***")
                if len(f) >= 10:
                    ch_a = struct.unpack('>H', f[6:8])[0]
                    ch_b = struct.unpack('>h', f[8:10])[0]
                    ch_c = struct.unpack('>h', f[10:12])[0]
                    print(f"     first record: chA={ch_a} chB={ch_b} chC={ch_c}")
                success = True
                break
            elif not frames:
                print("     (no response at all)")

        print("\n" + "=" * 50)
        if success:
            print("SUCCESS: mode10 pre-condition FIX WORKS.")
            print("Run stream_ppg_13.py --csv --duration 60 for full capture.")
        else:
            print("FAILED: still 0 RSP 0x13 frames after mode10 pre-condition.")
            print("Next diagnostics to try:")
            print("  1. Poll 96 01 00 00 00 while STILL in mode10 (don't exit first)")
            print("  2. Try each of modes 11, 12, 13 alone (bisect which one primes)")
            print("  3. Try mode10 → mode01 without any exit (06 01 00 directly)")
            print("  4. Add longer delay after mode10 exit (try 2s instead of 0.5s)")


if __name__ == "__main__":
    if ADDR is None:
        print("Usage: .venv/bin/python debug_ppg_mode10.py <CBPeripheral-UUID>")
        print("       WEAR THE RING on your finger during this test.")
        sys.exit(1)
    asyncio.run(main(ADDR))
