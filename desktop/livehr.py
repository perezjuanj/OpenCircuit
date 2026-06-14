"""Drive the ring to live heart rate, VERBOSE — logs every TX and RX frame so we
can see exactly where the flow stalls. Full sequence:
  init -> 02 sync(all) -> drain history (ack 47->c7, 4c->cc) -> d0 -> 06 01 00
  -> 07 -> poll 95 00 00, decode 0x15 (byte[2] = HR).

    .venv/bin/python livehr.py [address]
"""
import asyncio, sys, collections
from bleak import BleakClient
from openringconn import ble, session

ADDR = sys.argv[1] if len(sys.argv) > 1 else "63E2C4D4-7E06-CA73-568B-062FAA032213"


async def main():
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
                    hrs.append(b[2]); print(f"        >>> HR = {b[2]} bpm")

        print("# init")
        await w("010000"); await w("010131826700"); await drain(1.5, False)
        print("# open sync (cursor = all)")
        await w("0200ffffffff000100"); await drain(1.5, False)
        print("# fetch + drain history")
        await w("070000"); await drain(3.0, True)
        print("# d0 status + enter live-HR mode")
        await w("d00000"); await drain(1.0, False)
        await w("060100"); await drain(1.0, False)
        await w("070000"); await drain(1.0, True)
        print("# poll live HR")
        all_hr = []
        for _ in range(30):
            await w("950000")
            all_hr += await drain(0.5, True)
        await client.stop_notify(ble.NOTIFY_CHAR)
        print(f"\nframe opcodes seen: {dict(ops)}")
        print(f"live HR samples: {all_hr}")


asyncio.run(main())
