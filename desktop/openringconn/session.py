"""Live BLE session helpers built on bleak: scan, enumerate, listen, replay."""

from __future__ import annotations

import asyncio
import contextlib
from datetime import datetime

from bleak import BleakClient, BleakScanner

from . import ble


def _looks_like_ring(name: str | None) -> bool:
    if not name:
        return False
    return any(name.startswith(p) for p in ble.NAME_PREFIXES)


async def _resolve(target, timeout: float = 10.0):
    """Return a connectable target for BleakClient.

    On macOS, CoreBluetooth can't connect to a bare address *string* — it needs
    the discovered BLEDevice object. So if we're handed a string, do a quick scan
    to find the live device; if we already have a BLEDevice, use it as-is.
    """
    if not isinstance(target, str):
        return target
    device = await BleakScanner.find_device_by_address(target, timeout=timeout)
    if device is None:
        raise RuntimeError(
            f"Could not find {target} while scanning. Make sure the ring is awake "
            f"and not connected to the phone (turn off the phone's Bluetooth)."
        )
    return device


async def scan(timeout: float = 10.0) -> None:
    """List nearby devices, then enumerate the ring's GATT tree."""
    print(f"Scanning {timeout:.0f}s …")
    devices = await BleakScanner.discover(timeout=timeout)
    ring = None
    for d in sorted(devices, key=lambda x: x.address):
        mark = ""
        if _looks_like_ring(d.name):
            mark = "  <-- candidate ring"
            ring = ring or d
        print(f"  {d.address}  {d.name or '(no name)':<24}{mark}")

    if ring is None:
        print("\nNo RingConn candidate found. Pass --addr to inspect a known MAC.")
        return
    # Pass the discovered BLEDevice object (not its address) — required on macOS.
    await enumerate_gatt(ring)


async def enumerate_gatt(target) -> None:
    """Print every service/characteristic/descriptor with handles and properties.

    `target` may be a BLEDevice (from scan) or an address string (from --addr).
    """
    device = await _resolve(target)
    address = device.address if not isinstance(device, str) else device
    print(f"\nConnecting to {address} …")
    async with BleakClient(device) as client:
        print(f"Connected. Services for {address}:\n")
        for service in client.services:
            print(f"[service] {service.uuid}  (handle 0x{service.handle:04x})")
            for char in service.characteristics:
                props = ",".join(char.properties)
                print(
                    f"  [char] {char.uuid}  handle=0x{char.handle:04x}  ({props})"
                )
                for desc in char.descriptors:
                    print(f"    [desc] {desc.uuid}  handle=0x{desc.handle:04x}")
        print("\nFill these into docs/PROTOCOL.md §1.")


def _make_handler(label: str):
    def handler(sender, data: bytearray) -> None:
        ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        hx = data.hex(" ")
        print(f"{ts}  {label} <- [{len(data):>3}B]  {hx}")

    return handler


async def listen(address: str, notify_char: str = ble.NOTIFY_CHAR,
                 keepalive: bool = False, duration: float | None = None) -> None:
    """Subscribe to the notify characteristic and log every payload as hex.

    With --keepalive, periodically writes the observed live-HR keepalive so the
    ring keeps streaming (useful while decoding heart rate).
    """
    device = await _resolve(address)
    print(f"Connecting to {address} …")
    async with BleakClient(device) as client:
        print(f"Connected. Subscribing to {notify_char}. Ctrl-C to stop.\n")
        await client.start_notify(notify_char, _make_handler("notify"))

        async def keepalive_loop():
            while True:
                with contextlib.suppress(Exception):
                    await client.write_gatt_char(
                        ble.WRITE_CHAR, ble.KEEPALIVE_PAYLOAD, response=False
                    )
                await asyncio.sleep(2.0)

        tasks = []
        if keepalive:
            tasks.append(asyncio.create_task(keepalive_loop()))
        try:
            await asyncio.sleep(duration if duration else 3600)
        except asyncio.CancelledError:
            pass
        finally:
            for t in tasks:
                t.cancel()
            with contextlib.suppress(Exception):
                await client.stop_notify(notify_char)


async def replay(address: str, payload: bytes, write_char: str = ble.WRITE_CHAR,
                 response: bool = False, listen_after: float = 5.0) -> None:
    """Write one command and log notifications that follow it."""
    device = await _resolve(address)
    print(f"Connecting to {address} …")
    async with BleakClient(device) as client:
        await client.start_notify(ble.NOTIFY_CHAR, _make_handler("notify"))
        print(f"Writing {payload.hex(' ')} -> {write_char} (response={response})")
        await client.write_gatt_char(write_char, payload, response=response)
        await asyncio.sleep(listen_after)
        with contextlib.suppress(Exception):
            await client.stop_notify(ble.NOTIFY_CHAR)
