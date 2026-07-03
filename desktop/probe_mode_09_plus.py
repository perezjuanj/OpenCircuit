"""Probe unexplored CMD 0x06 modes 09-FF and CMD 0x05 with params.

We have mapped modes 01-08 for CMD 0x06 (see BLE_INVESTIGATION_LOG.md §2c).
Modes 09-FF are completely untested and might trigger:
  - BleRealTimePPGRspMixin (RSP 0x16?) — raw PPG streaming
  - BlePPGTestRspMixin — factory PPG test mode
  - BleACCTestRspMixin — accelerometer test mode
  - BleOnlineOsaDataRspMixin — live OSA data
  - Some other undiscovered feature

Also probes:
  - CMD 0x05 with param bytes (0x05 00 00 triggered passive 0x4D; params may differ)
  - CMD 0x91 with mode bytes beyond 01
  - CMD 0x30 with params (RSP 0x0B is unexplained)

SAFETY: New mode entries may change ring state. We watchdog by draining for 3s
and sending 0x06 00 00 (stop mode) between each probe.

    .venv/bin/python probe_mode_09_plus.py <CBPeripheral-UUID>
"""
from __future__ import annotations
import asyncio, sys, time
from bleak import BleakClient, BleakError
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

ADDR = sys.argv[1] if len(sys.argv) > 1 else None

# All known response opcodes — anything OUTSIDE this set is NOVEL
KNOWN = {
    0x0B, 0x10, 0x11, 0x15, 0x47, 0x4A, 0x4C, 0x4D, 0x4E, 0x50,
    0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB,
}
PPG_CANDIDATES = {0x13, 0x14, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F}


async def main(addr: str) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)

    async with BleakClient(device) as client:
        print(f"\nConnected: {addr}")
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        novel_hits: list[tuple[str, bytes]] = []

        async def tx(hexstr: str, label: str = "") -> None:
            await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex(hexstr), response=True)

        async def drain(timeout: float, label: str = "") -> list[bytes]:
            frames = []
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                remaining = deadline - time.monotonic()
                try:
                    b = await asyncio.wait_for(q.get(), timeout=min(remaining, 0.5))
                    frames.append(bytes(b))
                    novel = b[0] not in KNOWN
                    ppg = b[0] in PPG_CANDIDATES
                    flag = "  !!! PPG CANDIDATE !!!" if ppg else ("  *** NOVEL ***" if novel else "")
                    print(f"     RX [{b[0]:#04x}] {b.hex(' ')}{flag}")
                    if b[0] == 0x47: await tx("c70000", "(ack 47)")
                    elif b[0] == 0x4C: await tx("cc0000", "(ack 4c)")
                    if novel:
                        novel_hits.append((label, bytes(b)))
                except asyncio.TimeoutError:
                    break
            return frames

        async def keepalive() -> None:
            try:
                await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("950000"), response=True)
                await asyncio.sleep(0.1)
                while not q.empty():
                    q.get_nowait()
            except BleakError:
                pass

        # ── Auth ─────────────────────────────────────────────────────────────────
        print("\n--- AUTH ---")
        mac = None
        try:
            raw = await client.read_gatt_char(SYSID_CHAR)
            mac = mac_from_sysid(bytes(raw))
            print(f"  MAC: {':'.join(f'{b:02X}' for b in mac)}")
        except Exception as e:
            print(f"  sysid failed: {e}")

        await tx("010000")
        await asyncio.sleep(0.3)
        challenge_frame = None
        while not q.empty():
            b = q.get_nowait()
            if b[0] == 0x81:
                challenge_frame = b
        if challenge_frame and mac:
            cmd = auth_command(challenge_frame[2], mac)
            await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            await asyncio.sleep(0.3)
            while not q.empty(): q.get_nowait()
            print("  Auth OK")

        # ── Drain history ─────────────────────────────────────────────────────────
        print("\n--- DRAIN ---")
        await tx(ble.SYNC_ALL.hex()); await drain(2.0)
        await tx("070000"); await drain(3.0)
        await tx("d00000"); await drain(1.0)

        # ── CMD 0x06 modes 09–1F ─────────────────────────────────────────────────
        print("\n--- CMD 0x06 MODE SWEEP (09 → 1F) ---")
        print("WEAR THE RING — some modes may require contact detection.")

        for mode in range(0x09, 0x20):
            label = f"06_{mode:02x}_00"
            print(f"\n  {label}: TX 06 {mode:02x} 00")
            await keepalive()
            try:
                await tx(f"06{mode:02x}00", label)
            except BleakError as e:
                print(f"  write failed: {e}")
                continue
            frames = await drain(3.0, label)

            # Follow-up poll after mode entry
            await tx("910100")  # on-demand snapshot — does it work in new mode?
            await drain(1.5, f"{label}_91poll")

            # Reset mode before next probe
            await tx("060000")  # exit mode (mode 00 = idle)
            await asyncio.sleep(0.3)
            while not q.empty(): q.get_nowait()

        # ── CMD 0x05 with param bytes ─────────────────────────────────────────────
        print("\n--- CMD 0x05 WITH PARAMS ---")
        for param in [0x00, 0x01, 0x02, 0x04]:
            label = f"05_{param:02x}_00"
            print(f"\n  {label}: TX 05 {param:02x} 00")
            await keepalive()
            await tx(f"05{param:02x}00", label)
            await drain(2.0, label)

        # ── CMD 0x91 with mode bytes beyond 01 ───────────────────────────────────
        print("\n--- CMD 0x91 PARAMS SWEEP ---")
        for param in [0x00, 0x02, 0x03, 0x04, 0x05]:
            label = f"91_{param:02x}_00"
            print(f"\n  {label}: TX 91 {param:02x} 00")
            await keepalive()
            await tx(f"91{param:02x}00", label)
            await drain(2.0, label)

        # ── CMD 0x30 with params (RSP 0x0B — unexplained opcode) ─────────────────
        print("\n--- CMD 0x30 WITH PARAMS (RSP 0x0B) ---")
        for p1, p2 in [(0x01, 0x00), (0x02, 0x00), (0x01, 0x01), (0xFF, 0xFF)]:
            label = f"30_{p1:02x}_{p2:02x}"
            print(f"\n  {label}: TX 30 {p1:02x} {p2:02x}")
            await keepalive()
            await tx(f"30{p1:02x}{p2:02x}", label)
            await drain(2.0, label)

        # ── 4-byte payloads for CMD 0x96 ─────────────────────────────────────────
        # (2-byte params didn't work; maybe it needs 4 structured bytes)
        print("\n--- CMD 0x96 WITH 4-BYTE PAYLOADS ---")
        probes_96_4byte = [
            ("96_01_00_00_00", "9601000000"),  # enable=1, 3 param bytes
            ("96_01_01_00_00", "9601010000"),
            ("96_01_00_19_00", "9601001900"),  # rate=25 Hz in byte[3]
            ("96_01_00_32_00", "9601003200"),  # rate=50 Hz
            ("96_01_00_00_01", "9601000001"),
            ("96_01_19_00_00", "9601190000"),  # rate in byte[2]
            ("96_04_01_00_00", "9604010000"),  # different first param
            ("96_FF_01_00_00", "96FF010000"),
        ]
        await tx("060100", "enter mode01 for 96 probes")
        await drain(2.0)
        await asyncio.sleep(1.0)
        while not q.empty(): q.get_nowait()

        for label, hexcmd in probes_96_4byte:
            print(f"\n  {label}: TX {hexcmd}")
            await keepalive()
            await tx(hexcmd, label)
            frames = await drain(2.0, label)
            for fr in frames:
                if fr[0] in PPG_CANDIDATES:
                    novel_hits.append((label, fr))

        await client.stop_notify(ble.NOTIFY_CHAR)

    print(f"\n{'='*60}")
    if novel_hits:
        print("*** NOVEL OPCODES FOUND ***")
        for label, fr in novel_hits:
            ppg = fr[0] in PPG_CANDIDATES
            print(f"  {label}: [{fr[0]:#04x}] {fr.hex(' ')}{'  !!! PPG !!!' if ppg else ''}")
        print("\nUpdate BLE_INVESTIGATION_LOG.md with these findings!")
    else:
        print("No novel opcodes found in any probe.")
        print()
        print("Next steps:")
        print("  1. iPhone HCI capture during manual HR Measure (definitive test)")
        print("  2. Try blutter on libapp.so for full Dart decompilation")
        print("  3. Android HCI snoop log (adb + developer mode)")


if __name__ == "__main__":
    if ADDR is None:
        print("Usage: .venv/bin/python probe_mode_09_plus.py <CBPeripheral-UUID>")
        print("       WEAR THE RING during this probe.")
        sys.exit(1)
    asyncio.run(main(ADDR))
