"""Drive the ring to live heart rate, VERBOSE — logs every TX and RX frame so we
can see exactly where the flow stalls. Full sequence:
  read MAC (0x2A23) -> SM3 auth -> 02 sync(all) -> drain history -> d0
  -> 06 01 00 -> 07 -> poll 95 00 00, decode 0x15 (byte[2] = HR).

    .venv/bin/python livehr.py [address]
    # address = CBPeripheral UUID from: .venv/bin/python -m opencircuit scan
"""
import asyncio, sys, collections, struct
from bleak import BleakClient
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command
from decode_4d_4e import decode_4e, decode_4d

ADDR = sys.argv[1] if len(sys.argv) > 1 else None


async def main():
    if ADDR is None:
        print("Usage: .venv/bin/python livehr.py <CBPeripheral-UUID>")
        print("       Get UUID from: .venv/bin/python -m opencircuit scan")
        sys.exit(1)

    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(ADDR, timeout=12.0)
    async with BleakClient(device) as client:
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        ops = collections.Counter()

        async def w(hexstr, label=""):
            print(f"  TX {hexstr:<20} {label}")
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(hexstr), response=True)

        async def drain(timeout, auto_ack):
            """Print frames until `timeout`s of silence; optionally ack 47/4c pages."""
            hrs = []
            while True:
                try:
                    b = await asyncio.wait_for(q.get(), timeout=timeout)
                except asyncio.TimeoutError:
                    return hrs
                ops[b[0]] += 1
                print(f"     RX {b.hex(' ')}")
                if auto_ack and b[0] == 0x47:
                    await w("c70000", "(ack 47)")
                elif auto_ack and b[0] == 0x4c:
                    await w("cc0000", "(ack 4c)")
                elif b[0] == 0x15 and len(b) > 2:
                    hrs.append(b[2]); print(f"        >>> HR(0x15) = {b[2]} bpm")
                elif b[0] == 0x4E and len(b) >= 13:
                    r = decode_4e(b)
                    if r:
                        hrs.append(r["hr"])
                        print(f"        >>> HR(0x4E) = {r['hr']} bpm  motion={r['motion']}  conf={r['conf']}  ts={r['timestamp']}")
                elif b[0] == 0x4D:
                    rs = decode_4d(b) or []
                    for r in rs:
                        hrs.append(r["hr"])
                        print(f"        >>> HR(0x4D) = {r['hr']} bpm  motion={r['motion']}  conf={r['conf']}  ts={r['timestamp']}")

        print("# read MAC from 0x2A23 System ID")
        mac = None
        try:
            raw = await client.read_gatt_char(SYSID_CHAR)
            mac = mac_from_sysid(bytes(raw))
            print(f"     MAC: {':'.join(f'{b:02X}' for b in mac) if mac else 'unknown'}")
        except Exception as e:
            print(f"     sysid read failed: {e} (will try without auth)")

        print("# init + SM3 auth")
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
            print(f"  TX {cmd.hex():<20} (SM3 auth, challenge=0x{challenge_frame[2]:02x})")
            await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
        else:
            print("  WARN: no challenge or no MAC — falling back to unauthenticated")
        await drain(1.5, False)
        print("# open sync (cursor = all / 0xFFFFFFFF = everything pending)")
        # For a targeted history-since-T sync instead, use ble.sync_cursor_cmd(unix).
        await w(ble.SYNC_ALL.hex()); await drain(1.5, False)
        print("# fetch + drain history")
        await w("070000"); await drain(3.0, True)
        print("# d0 status")
        await w("d00000"); await drain(1.0, False)

        print("# 91 01 00 — on-demand snapshot (works regardless of active mode)")
        # The ring only generates 0x4E when its HR sensor is actively cycling.
        # 06 04 00 is REJECTED (86 ff) if no measurement is running.
        # 91 01 00 is an on-demand request — try this first.
        await w("910100", "on-demand snapshot")
        snap = await drain(2.0, True)
        all_hr: list[int] = list(snap)

        if not all_hr:
            print("  # 91 01 00 returned nothing — trying mode04 entry (requires active ring wear)")
            await w("060400"); await drain(1.0, True)
            # only issue 07 00 00 after mode entry, not before (draining kills active session)
            await w("070000"); await drain(1.0, True)

        print("# poll 30× for 0x4E (one per 10s when ring is measuring)")
        for i in range(30):
            await w("910100")   # on-demand snapshot — better than 95 00 00 poll
            all_hr += await drain(0.8, True)
            if i % 5 == 4:
                print(f"  ... {i+1}/30 polls, {len(all_hr)} HR samples so far")

        print("\n# mode07 batch — pull any recent 10s history")
        await w("060700"); await drain(2.0, True)

        await client.stop_notify(ble.NOTIFY_CHAR)
        print(f"\nframe opcodes seen: {dict(ops)}")
        if all_hr:
            print(f"HR samples ({len(all_hr)}): min={min(all_hr)} max={max(all_hr)} "
                  f"avg={sum(all_hr)/len(all_hr):.1f} bpm")
        else:
            print("No HR decoded — check opcode 0x4E/0x4D in raw RX lines above")


asyncio.run(main())
