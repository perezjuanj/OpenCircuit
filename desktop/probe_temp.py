#!/usr/bin/env python3
"""Active probe (verbose): learn whether the Mac can drive DATA commands at all,
then sweep the 0x02 sync-open flag for a temperature/summary stream.

Findings so far: an unbonded CoreBluetooth central gets replies to the 0x01
handshake but (so far) nothing to 0x02/0x07/0x95. This script tests that
explicitly in ONE warm connection (the ring sleeps within seconds), trying a
known-good real cursor before the flag sweep.

Run it the instant the ring is awake (off charger, just tapped), phone BT off,
no other process holding the link:
  .venv/bin/python probe_temp.py
"""
import asyncio
import collections
import sys

from bleak import BleakClient
from openringconn import ble, session

ADDR = sys.argv[1] if len(sys.argv) > 1 else "63E2C4D4-7E06-CA73-568B-062FAA032213"
GOOD_CURSOR = "0c2298c3"   # known to return data on the phone (FR02.018 capture)


async def main():
    q: asyncio.Queue = asyncio.Queue()
    dev = await session._resolve(ADDR, timeout=15.0)
    async with BleakClient(dev) as client:
        print("connected:", client.is_connected)
        _ = client.services.get_characteristic(ble.NOTIFY_CHAR)   # force discovery
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.5)

        async def w(h):
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(h), response=True)
            print(f"  TX {h}")

        async def drain(timeout, auto_ack=True, tag=""):
            frames = []
            while True:
                try:
                    b = await asyncio.wait_for(q.get(), timeout=timeout)
                except asyncio.TimeoutError:
                    break
                frames.append(b)
                print(f"     RX {b.hex(' ')}")
                if auto_ack and b[0] == 0x47:
                    await w("c70000")
                elif auto_ack and b[0] == 0x4C:
                    await w("cc0000")
            if tag:
                print(f"  [{tag}] {len(frames)} frames")
            return frames

        print("# init handshake"); await w("010000"); await w("010131826700")
        await drain(2.0, False, "init")

        print("# 0x02 with KNOWN-GOOD real cursor + flag 00"); await w(f"0200{GOOD_CURSOR}000100")
        await drain(1.5, False, "02-realcursor"); await w("070000"); await drain(3.0, True, "fetch")

        print("# 0x02 with 0xFFFFFFFF (SYNC_ALL)"); await w("0200ffffffff000100")
        await drain(1.5, False, "02-syncall"); await w("070000"); await drain(3.0, True, "fetch")

        print("# poll 95 00 00"); await w("950000"); await drain(1.5, False, "poll")

        # Only sweep flags if data commands actually responded above.
        print("# flag sweep (real cursor)")
        for flag in range(0, 8):
            await w(f"0200{GOOD_CURSOR}{flag:02x}0100"); await drain(0.8, False)
            await w("070000"); frames = await drain(2.5, True)
            ops = collections.Counter(b[0] for b in frames)
            s4c = b"".join(b[3:-1] for b in frames if b[0] == 0x4C)
            recs = [s4c[i:i+23] for i in range(0, len(s4c), 23) if len(s4c[i:i+23]) == 23]
            nonact = [r for r in recs if not (r[8] in (0x12, 0x13) or 0x57 <= r[8] <= 0x63)]
            print(f"  flag={flag:#04x} ops={ {hex(k): v for k, v in ops.items()} } 4c={len(recs)} nonact={len(nonact)}")
            for r in nonact[:6]:
                print(f"      NONACT {r.hex()} [8]={r[8]:#04x}")

        await client.stop_notify(ble.NOTIFY_CHAR)
    print("\nDone.")


asyncio.run(main())
