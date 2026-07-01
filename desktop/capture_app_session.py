"""Passive BLE session logger — captures all frames while you trigger actions in the RingConn app.

WHY: The RingConn app's manual "Real-Time Heart Rate" Measure action causes the ring's green
LEDs to flash for 30-60s. This is the most likely trigger for a live optical acquisition mode.
If raw or near-raw PPG data is ever sent over BLE, it will appear during this action.

This script connects, authenticates, and then LISTENS passively. Meanwhile you trigger
actions in the RingConn app on your phone... WAIT — the ring can only be connected to one
device. Use the iPhone HCI packet logger instead for true app-triggered captures.

CORRECT USE CASE (Mac-connected session):
  This is useful for capturing frames when you connect via Mac and manually trigger the
  ring's measurement via CMD 0x06 mode sequences, while watching for any novel dense streams.

  Trigger sequence to test (sends these commands):
    1. auth + drain history (standard init)
    2. CMD 06 01 00  (enter HR mode)  → observe frames
    3. CMD 06 02 00  (enter SpO2 mode) → observe frames
    4. CMD 91 01 00  × N   (on-demand snapshot) → observe 0x4E vs nothing
    5. CMD 29 00 00  × N   (polled HR+SpO2) → observe 0xA9 HR/SpO2 values

ALTERNATIVE (better for manual-measure capture):
  Use iPhone HCI Bluetooth packet logging:
    1. Connect iPhone to Mac with cable
    2. On Mac: open /Library/Application Support/Apple/PacketLogger (or install Xcode)
    3. In PacketLogger: File → New iOS Trace
    4. On iPhone: open RingConn app, connect ring
    5. Navigate to Real-Time Heart Rate → tap Measure (green LEDs flash)
    6. Stop capture → export .btsnoop → run decode_bulk.py or grep for novel opcodes

    .venv/bin/python capture_app_session.py <CBPeripheral-UUID> [--duration 120]

Output: capture_<UUID>_<timestamp>.txt
"""
from __future__ import annotations
import asyncio, sys, time, argparse, datetime, collections
from bleak import BleakClient, BleakError
from bleak.exc import BleakCharacteristicNotFoundError
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

ADDR = sys.argv[1] if len(sys.argv) > 1 else None

# Known sparse opcodes (history/sync) — interesting but not PPG waveform
KNOWN_SPARSE = {0x10, 0x11, 0x15, 0x47, 0x4A, 0x4C, 0x4D, 0x4E, 0x50, 0x81, 0x82,
                0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0xA0, 0xA1,
                0xA2, 0xA3, 0xA4, 0xA7, 0xA8, 0xA9, 0xAA}

# Opcodes that indicate high-frequency / raw data (not yet confirmed — watch for these)
PPG_CANDIDATES = {0x13, 0x14, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C}


async def main(addr: str, duration: int) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    outfile = f"capture_{addr.replace(':', '-').replace('-', '')[:8]}_{ts}.txt"
    ops: collections.Counter = collections.Counter()

    async with BleakClient(device) as client:
        print(f"\nConnected: {addr}")
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        async def w(hexstr: str, label: str = "") -> None:
            print(f"  TX {hexstr:<20} {label}")
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(hexstr), response=True)

        async def drain(timeout: float, auto_ack: bool = True) -> list[bytes]:
            frames = []
            while True:
                try:
                    b = await asyncio.wait_for(q.get(), timeout=timeout)
                except asyncio.TimeoutError:
                    break
                frames.append(b)
                ops[b[0]] += 1
                flag = "  *** NOVEL ***" if b[0] not in KNOWN_SPARSE else ""
                ppg_flag = "  !!! PPG CANDIDATE !!!" if b[0] in PPG_CANDIDATES else ""
                print(f"     RX [{b[0]:#04x}] {b.hex(' ')}{flag}{ppg_flag}")
                if auto_ack:
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

        # Drain history
        print("\n--- DRAIN HISTORY ---")
        await w(ble.SYNC_ALL.hex()); await drain(2.0)
        await w("070000"); await drain(4.0)
        await w("d00000"); await drain(1.0)

        # Probe sequence — most likely to reveal live optical mode
        print("\n--- LIVE MODE PROBES ---")

        print("\n# CMD 0x29 — polled HR+SpO2 (works when ring is worn+measuring)")
        await w("290000", "polled HR+SpO2")
        frames = await drain(1.5)
        if frames:
            rsp = frames[0]
            if rsp[0] == 0xA9 and len(rsp) >= 5:
                print(f"    HR={rsp[2]}bpm  SpO2={rsp[4]}%  (flags {rsp[1]}/{rsp[3]})")

        print("\n# CMD 06 01 00 — enter HR realtime mode")
        await w("060100", "HR mode"); await drain(1.0)
        await w("070000"); await drain(2.0)

        print("\n# CMD 91 01 00 × 3 — on-demand 10s snapshot")
        for _ in range(3):
            await w("910100", "on-demand snapshot")
            await drain(1.5)
            await asyncio.sleep(0.3)

        print("\n# CMD 06 04 00 — sport/realtime mode (requires active wear)")
        await w("060400", "sport mode"); await drain(2.0)

        print("\n# CMD 06 06 00 — mode 06 (live snapshot without drain)")
        await w("060600", "mode 06"); await drain(2.0)

        # Passive listen phase — watch for any dense streams
        print(f"\n--- PASSIVE LISTEN ({duration}s) ---")
        print("  Watching for novel or PPG-candidate opcodes...")
        print("  WEAR THE RING during this window for best results.")
        print()

        with open(outfile, "w") as f:
            f.write(f"# RingConn capture {ts} addr={addr}\n\n")
            deadline = time.monotonic() + duration
            keepalive_at = time.monotonic() + 8.0  # keepalive every 8s

            while time.monotonic() < deadline:
                remaining = deadline - time.monotonic()

                # Keepalive
                if time.monotonic() >= keepalive_at:
                    try:
                        await client.write_gatt_char(
                            ble.WRITE_CHAR, bytes.fromhex("950000"), response=True)
                    except BleakError:
                        print("  keepalive failed — ring may have disconnected")
                        break
                    keepalive_at = time.monotonic() + 8.0

                # Poll for frame
                try:
                    b = await asyncio.wait_for(q.get(), timeout=min(remaining, 1.0))
                    ops[b[0]] += 1
                    flag = "  *** NOVEL ***" if b[0] not in KNOWN_SPARSE else ""
                    ppg_flag = "  !!! PPG CANDIDATE !!!" if b[0] in PPG_CANDIDATES else ""
                    line = f"RX [{b[0]:#04x}] {b.hex(' ')}{flag}{ppg_flag}"
                    print(f"  {line}")
                    f.write(line + "\n")
                    if b[0] == 0x47:
                        await client.write_gatt_char(
                            ble.WRITE_CHAR, bytes.fromhex("c70000"), response=True)
                    elif b[0] == 0x4C:
                        await client.write_gatt_char(
                            ble.WRITE_CHAR, bytes.fromhex("cc0000"), response=True)
                except asyncio.TimeoutError:
                    secs_left = int(deadline - time.monotonic())
                    print(f"  ... {secs_left}s remaining, {sum(ops.values())} frames seen", end="\r")

        await client.stop_notify(ble.NOTIFY_CHAR)

    print(f"\n\n{'='*60}")
    print(f"Capture saved: {outfile}")
    print(f"Frame opcode counts: {dict(ops.most_common())}")
    novel = {k: v for k, v in ops.items() if k not in KNOWN_SPARSE}
    if novel:
        print(f"\n*** NOVEL OPCODES SEEN: {novel} ***")
        print("These are candidates for PPG or other undocumented data streams.")
    else:
        print("\nNo novel opcodes seen — all traffic matched known protocol frames.")
    print()
    print("Next: if no novel opcodes and ring was worn — PPG is likely not exposed in current mode.")
    print("Next step: capture iPhone HCI trace during app manual HR Measure action.")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("addr", help="CBPeripheral UUID")
    p.add_argument("--duration", type=int, default=60,
                   help="passive listen window in seconds (default: 60)")
    args = p.parse_args()
    asyncio.run(main(args.addr, args.duration))
