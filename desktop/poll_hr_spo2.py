"""Poll CMD 0x29 for live HR+SpO2 — works without wearing the ring.

Returns last measured values from the ring's internal cache. When ring is being
worn and actively measuring, values update every ~10s. When idle (not worn),
returns the last cached reading from the most recent measurement session.

    .venv/bin/python poll_hr_spo2.py <CBPeripheral-UUID> [--interval 2] [--count 30]
"""
from __future__ import annotations
import asyncio, sys, argparse, time
from bleak import BleakClient
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

ADDR = sys.argv[1] if len(sys.argv) > 1 else None


async def main(addr: str, interval: float, count: int) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)

    async with BleakClient(device) as client:
        print(f"Connected: {addr}\n")
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        # Auth
        mac = None
        try:
            raw = await client.read_gatt_char(SYSID_CHAR)
            mac = mac_from_sysid(bytes(raw))
        except Exception:
            pass

        await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("010000"), response=True)
        await asyncio.sleep(0.3)
        challenge_frame = None
        while not q.empty():
            b = q.get_nowait()
            if len(b) >= 3 and b[0] == 0x81:
                challenge_frame = b
        if challenge_frame and mac:
            cmd = auth_command(challenge_frame[2], mac)
            await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            await asyncio.sleep(0.3)
            while not q.empty():
                q.get_nowait()

        # Quick history drain (minimal — just enough to clear state)
        await client.write_gatt_char(ble.WRITE_CHAR, ble.SYNC_ALL, response=True)
        await asyncio.sleep(0.5)
        while not q.empty():
            q.get_nowait()

        print(f"{'Time':<10}  {'HR':>6}  {'SpO2':>6}  Raw")
        print("-" * 40)

        for i in range(count):
            await client.write_gatt_char(
                ble.WRITE_CHAR, bytes.fromhex("290000"), response=True)
            try:
                rsp = await asyncio.wait_for(q.get(), timeout=2.0)
                # Drain any extra frames
                while not q.empty():
                    q.get_nowait()

                if rsp[0] == 0xA9 and len(rsp) >= 5:
                    hr   = rsp[2]
                    spo2 = rsp[4]
                    flag_hr   = "✓" if rsp[1] == 0x01 else "?"
                    flag_spo2 = "✓" if rsp[3] == 0x01 else "?"
                    print(f"{time.strftime('%H:%M:%S')}  {hr:>4}bpm{flag_hr}  {spo2:>4}%{flag_spo2}  "
                          f"{rsp.hex(' ')}")
                else:
                    print(f"{time.strftime('%H:%M:%S')}  unexpected: {rsp.hex(' ')}")
            except asyncio.TimeoutError:
                print(f"{time.strftime('%H:%M:%S')}  (no response — ring may be asleep)")

            # Keepalive piggybacks on the 0x29 poll — no extra packet needed
            if i < count - 1:
                await asyncio.sleep(interval)

        await client.stop_notify(ble.NOTIFY_CHAR)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("addr", help="CBPeripheral UUID from `opencircuit scan`")
    p.add_argument("--interval", type=float, default=2.0,
                   help="seconds between polls (default 2)")
    p.add_argument("--count", type=int, default=30,
                   help="number of polls (default 30)")
    args = p.parse_args()
    asyncio.run(main(args.addr, args.interval, args.count))
