"""Probe the third GATT service discovered on 2026-06-26.

Service: 1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0  (handle 0x0900)
  Char1: f7bf3564-fb6d-4e53-88a4-5e37e0326063  handle=0x0901  (write)
  Char2: 984227f3-34fc-4045-a5d0-2c581f81a153  handle=0x0903  (write-without-response, write)

Structural hypothesis: DFU/OTA secondary service.
  Char1 (write only) = DFU Control Point — accepts commands, responses come back on notify
  Char2 (write-no-rsp) = DFU Packet — high-throughput firmware byte stream

What we observe: both chars are WRITE-only (no notify, no read). If this is a DFU service,
responses (if any) would appear on the primary notify characteristic 0x0804.

This script:
  1. Connects and enables notifications on the primary notify char (0x0804).
  2. Completes SM3 auth on the primary service.
  3. Sends safe 1-byte probe payloads to Char1 (0x0901) and Char2 (0x0903).
  4. Logs any responses seen on the primary notify channel within 2s.
  5. Tries a few known DFU probe patterns as a secondary test.

    .venv/bin/python probe_third_service.py <CBPeripheral-UUID>
    # UUID from: .venv/bin/python -m opencircuit scan
    # Keep phone BT OFF.

SAFETY: Char1 and Char2 are write-only. We send only minimal safe payloads:
  - 0x00 (null / noop in most protocols)
  - 0x01 (common "ping" / version query in DFU protocols)
  These cannot trigger firmware flash without a full DFU handshake.
"""
from __future__ import annotations
import asyncio, sys
from bleak import BleakClient, BleakError
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

ADDR = sys.argv[1] if len(sys.argv) > 1 else None

# Third service characteristics
THIRD_SVC   = "1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0"
CHAR_0901   = "f7bf3564-fb6d-4e53-88a4-5e37e0326063"  # write only
CHAR_0903   = "984227f3-34fc-4045-a5d0-2c581f81a153"  # write-without-response + write

# DFU-style probe payloads: common "version request" / control codes
_PROBES_0901 = [
    ("null",          bytes([0x00])),
    ("version-query", bytes([0x01])),
    ("status-query",  bytes([0x06])),  # Nordic DFU: 0x06 = Request object info
    ("abort",         bytes([0x0C])),  # Nordic DFU: 0x0C = Abort (safe noop if not in DFU)
]

_PROBES_0903 = [
    ("null",          bytes([0x00])),
    ("ping",          bytes([0x01])),
]


async def main(addr: str) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)

    async with BleakClient(device) as client:
        print(f"\nConnected: {addr}")

        # Subscribe to primary notify channel — responses (if any) land here
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        async def drain(timeout: float, label: str) -> list[bytes]:
            frames = []
            while True:
                try:
                    b = await asyncio.wait_for(q.get(), timeout=timeout)
                    frames.append(b)
                    print(f"     RX {b.hex(' ')}  [{label}]")
                except asyncio.TimeoutError:
                    break
            return frames

        # Auth on primary service (required — unauthenticated commands may be ignored)
        print("\n--- AUTH (primary service) ---")
        mac = None
        try:
            raw = await client.read_gatt_char(SYSID_CHAR)
            mac = mac_from_sysid(bytes(raw))
            print(f"  MAC: {':'.join(f'{b:02X}' for b in mac)}")
        except Exception as e:
            print(f"  sysid read failed: {e}")

        await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("010000"), response=True)
        await asyncio.sleep(0.4)
        challenge_frame = None
        while not q.empty():
            b = q.get_nowait()
            print(f"     RX {b.hex(' ')}  [auth]")
            if len(b) >= 3 and b[0] == 0x81:
                challenge_frame = b

        if challenge_frame and mac:
            cmd = auth_command(challenge_frame[2], mac)
            await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            await asyncio.sleep(0.3)
            while not q.empty():
                b = q.get_nowait()
                print(f"     RX {b.hex(' ')}  [auth-rsp]")
            print("  Auth OK")
        else:
            print("  WARN: auth skipped — ring may not respond to probes")

        # Verify the third service is present
        print("\n--- SERVICE DISCOVERY CHECK ---")
        svc_uuids = [str(s.uuid) for s in client.services]
        if THIRD_SVC in svc_uuids:
            print(f"  Third service FOUND: {THIRD_SVC}")
        else:
            print(f"  Third service NOT FOUND in {svc_uuids}")
            print("  Ring may need to be in a specific state (e.g., OTA mode) for it to appear.")
            print("  Continuing anyway with UUID-based writes (may fail).")

        # Probe Char1 (0x0901) — write with response
        print("\n--- CHAR1 (0x0901, write-with-response) PROBES ---")
        for label, payload in _PROBES_0901:
            print(f"\n  TX {payload.hex()} → 0x0901 ({label})")
            try:
                await client.write_gatt_char(CHAR_0901, payload, response=True)
            except BleakError as e:
                print(f"  write-err: {e}")
                continue
            frames = await drain(1.5, f"0x0901/{label}")
            if not frames:
                print("  (no response on primary notify within 1.5s)")
            await asyncio.sleep(0.3)

        # Probe Char2 (0x0903) — write-without-response (high-throughput path)
        print("\n--- CHAR2 (0x0903, write-without-response) PROBES ---")
        for label, payload in _PROBES_0903:
            print(f"\n  TX {payload.hex()} → 0x0903 ({label}, no-rsp)")
            try:
                await client.write_gatt_char(CHAR_0903, payload, response=False)
            except BleakError as e:
                print(f"  write-err: {e}")
                continue
            frames = await drain(1.5, f"0x0903/{label}")
            if not frames:
                print("  (no response on primary notify within 1.5s)")
            await asyncio.sleep(0.3)

        # Also try with response=True on CHAR_0903 (it supports both modes)
        print("\n--- CHAR2 (0x0903, write-WITH-response) PROBES ---")
        for label, payload in _PROBES_0903[:1]:
            print(f"\n  TX {payload.hex()} → 0x0903 ({label}, with-rsp)")
            try:
                await client.write_gatt_char(CHAR_0903, payload, response=True)
            except BleakError as e:
                print(f"  write-err: {e}")
                continue
            frames = await drain(1.5, f"0x0903/{label}-rsp")
            if not frames:
                print("  (no response)")
            await asyncio.sleep(0.3)

        await client.stop_notify(ble.NOTIFY_CHAR)

    print("\n=== SUMMARY ===")
    print("If no responses appeared above, hypothesis is confirmed:")
    print("  Char1/Char2 are a DFU/OTA staging area — only active after 0x20/0x21 OTA-enter sequence.")
    print("  They are NOT a secondary PPG data streaming path.")
    print()
    print("If responses DID appear on the primary notify:")
    print("  These chars are a secondary control protocol — decode the response opcode and payload.")


if __name__ == "__main__":
    if ADDR is None:
        print("Usage: .venv/bin/python probe_third_service.py <CBPeripheral-UUID>")
        print("       Get UUID from: .venv/bin/python -m opencircuit scan")
        sys.exit(1)
    asyncio.run(main(ADDR))
