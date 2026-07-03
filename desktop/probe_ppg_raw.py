"""Probe for raw / high-frequency PPG opcodes on the RingConn Air 2.

What this does, in order:
  1. Read the ring's MAC from the Device Information System ID char (0x2A23).
  2. Run the full SM3 challenge-response auth so the ring actually responds.
  3. Drain any pending history (0x4C / 0x47 pages) to clear the sync state.
  4. Sweep `06 <mode> 00` for modes 01–10: maps which mode byte enters which state.
  5. Probe unknown/unconfirmed command opcodes: 0x03–0x0F, 0x11–0x14, 0x91–0x9F.
  6. For each response seen, print the full frame + a guess at what mixin it might be.

Opcodes we already know (skip unless re-validating):
  01 → auth/handshake   02 → sync open     06 → mode select   07 → fetch record
  95 → live poll        C7 → ack 0x47      CC → ack 0x4C      D0 → status query

New opcode candidates based on firmware mixin list:
  BleRealTimePPGRspMixin   → response probably in 0x14–0x1F range (cmd = rsp XOR 0x80)
  BleOnlineOsaDataRspMixin → realtime OSA; response could be 0x18 or 0x19
  BleGetOfflineOsaRspMixin → offline OSA trigger; might be 0x91 or 0x11
  BleLedRspMixin           → LED control; might respond to 0x0D or higher
  BleSetParamRspMixin      → param set; might be 0x03 or 0x04
  BleWorkModeRspMixin      → already mapped to 0x06 (modes 01 = HR, 02 = SpO2, ?)

Usage:
    .venv/bin/python probe_ppg_raw.py [CBPeripheral-UUID]
    # UUID from: python -m opencircuit scan
    # Keep phone BT OFF. Run immediately after removing ring from charger.
"""
from __future__ import annotations
import asyncio, sys, collections, time, struct
from bleak import BleakClient
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

ADDR = sys.argv[1] if len(sys.argv) > 1 else None

# ── Mixin hints for unknown response opcodes ─────────────────────────────────
_MIXIN_HINTS: dict[int, str] = {
    0x10: "BlePassiveStatusRspMixin (spontaneous status — already known)",
    0x11: "? (maybe BleGetOfflineOsaRspMixin — app sends 0x91 at sync end)",
    0x13: "? unexplored",
    0x14: "? (BleRealtimeCmdRspMixin?)",
    0x15: "BleRealtimeMeasureRspMixin (live HR/SpO2 — already known)",
    0x16: "? (BleRealTimePPGRspMixin? BleRealtimeSportRspMixin?)",
    0x17: "? (BleRealTimeACCRspMixin?)",
    0x18: "? (BleOnlineOsaDataRspMixin?)",
    0x19: "? (BleOfflineOsaDataRspMixin? BleAutoOsaDataRspMixin?)",
    0x1A: "? (BleOsaCompatibleModeMixin?)",
    0x1B: "? (BleLedRspMixin?)",
    0x1C: "? (BleTempRspMixin?)",
    0x1D: "? (BleSetParamRspMixin?)",
    0x1E: "? (BleAutoSportsRspMixin?)",
    0x1F: "? (BleAutoOfflineBpMixin — blood pressure!)",
    0x47: "BleHistorySpo2RspMixin (PPG trend batch — already known)",
    0x4A: "BleSleepDataRspMixin / BleTempRspMixin (sleep+temp batch — known)",
    0x4C: "BleHistoryActivityRspMixin (HR/HRV/SpO2/RR batch — already known)",
    0x50: "BleEventStatusRspMixin (sync cursor boundaries — already known)",
    0x81: "BleAuthRspMixin (handshake — already known)",
    0x82: "BleSyncStatusMixin (sync open ack — already known)",
    0x86: "BleWorkModeRspMixin (mode-select ack — already known)",
    0x87: "BlePassiveStatusRspMixin (fetch ack / device status — already known)",
}

# ── Commands to sweep ────────────────────────────────────────────────────────
# Format: (label, hex_bytes, wait_s, poll_after)
_TARGETS = [
    # --- 0x06 mode sweep (known: 01=HR, 02=SpO2; what are 03-10?) ---
    ("06_mode01_HR",      "060100", 1.5, True),
    ("06_mode02_SpO2",    "060200", 1.5, True),
    ("06_mode03",         "060300", 1.5, True),
    ("06_mode04",         "060400", 1.5, True),
    ("06_mode05",         "060500", 1.5, True),
    ("06_mode06",         "060600", 1.5, True),
    ("06_mode07",         "060700", 1.5, True),
    ("06_mode08",         "060800", 1.5, True),
    # --- Unexplored low opcodes ---
    ("cmd_03",            "030000", 1.0, False),
    ("cmd_04",            "040000", 1.0, False),
    ("cmd_05",            "050000", 1.0, False),
    ("cmd_08",            "080000", 1.0, False),
    ("cmd_09",            "090000", 1.0, False),
    ("cmd_0A",            "0a0000", 1.0, False),
    ("cmd_0B",            "0b0000", 1.0, False),
    ("cmd_0C",            "0c0000", 1.0, False),
    ("cmd_0D",            "0d0000", 1.0, False),   # "Realtime HR start" rumour
    ("cmd_0E",            "0e0000", 1.0, False),
    ("cmd_0F",            "0f0000", 1.0, False),
    ("cmd_10",            "100000", 1.0, False),
    ("cmd_11",            "110000", 2.0, False),   # if 0x91 is rsp, cmd is 0x11
    ("cmd_12",            "120000", 1.0, False),
    ("cmd_13",            "130000", 1.0, False),
    ("cmd_14",            "140000", 1.0, False),
    # --- 0x9X range (0x95 is keepalive; 0x91 sent by official app) ---
    ("cmd_91",            "910000", 2.0, False),   # app sends at sync-end; BleGetOfflineOsa?
    ("cmd_92",            "920000", 1.0, False),
    ("cmd_93",            "930000", 1.0, False),
    ("cmd_94",            "940000", 1.0, False),
    ("cmd_96",            "960000", 1.0, False),
    ("cmd_97",            "970000", 1.0, False),
    ("cmd_98",            "980000", 1.0, False),
    ("cmd_99",            "990000", 1.0, False),
    ("cmd_9A",            "9a0000", 1.0, False),
    ("cmd_9B",            "9b0000", 1.0, False),
    # --- OSA specific probes: try with param byte 01 ---
    ("cmd_91_01",         "910100", 2.0, False),
    ("cmd_11_01",         "110100", 2.0, False),
    ("cmd_0D_01",         "0d0100", 1.5, False),   # PPG test mode param?
    # --- LED control guess ---
    ("cmd_1B",            "1b0000", 1.0, False),
    ("cmd_1B_01",         "1b0100", 1.0, False),
    ("cmd_1C",            "1c0000", 1.0, False),
    ("cmd_1D",            "1d0000", 1.0, False),
    ("cmd_1E",            "1e0000", 1.0, False),
    ("cmd_1F",            "1f0000", 1.0, False),
]


async def _read_mac(client: BleakClient) -> list[int] | None:
    try:
        raw = await client.read_gatt_char(SYSID_CHAR)
        mac = mac_from_sysid(bytes(raw))
        if mac:
            print(f"  MAC from 0x2A23 sysid: {raw.hex(' ')} -> {':'.join(f'{b:02X}' for b in mac)}")
        return mac
    except Exception as e:
        print(f"  WARNING: could not read 0x2A23 sysid: {e}")
        return None


async def _do_auth(client: BleakClient, q: asyncio.Queue,
                   mac: list[int] | None) -> bool:
    """Send 01 00 00, parse challenge from 81 response, reply with SM3 auth."""
    await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("010000"), response=True)
    await asyncio.sleep(0.3)
    challenge_frame = None
    while not q.empty():
        b = q.get_nowait()
        if len(b) >= 3 and b[0] == 0x81:
            challenge_frame = b
    if challenge_frame is None:
        print("  WARNING: no 0x81 response — ring may be asleep or already connected to phone")
        return False
    challenge = challenge_frame[2]
    print(f"  Challenge byte: 0x{challenge:02x}")
    if mac:
        cmd = auth_command(challenge, mac)
        print(f"  Auth cmd: {cmd.hex(' ')}")
        await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
        await asyncio.sleep(0.4)
        # Drain any auth response
        while not q.empty():
            b = q.get_nowait()
            print(f"     auth-rsp: {b.hex(' ')}")
        return True
    else:
        print("  No MAC — skipping SM3 auth (ring will not send history/realtime data)")
        return False


async def _drain(client: BleakClient, q: asyncio.Queue,
                 timeout: float, auto_ack: bool) -> list[bytes]:
    frames = []
    while True:
        try:
            b = await asyncio.wait_for(q.get(), timeout=timeout)
        except asyncio.TimeoutError:
            break
        frames.append(b)
        hint = _MIXIN_HINTS.get(b[0], "UNKNOWN")
        marker = "  *** NEW OPCODE ***" if "UNKNOWN" in hint else ""
        print(f"     RX [{b[0]:#04x}] {b.hex(' ')}   # {hint}{marker}")
        if auto_ack:
            if b[0] == 0x47:
                await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("c70000"), response=True)
            elif b[0] == 0x4C:
                await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("cc0000"), response=True)
    return frames


async def main(addr: str) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)
    async with BleakClient(device) as client:
        print(f"\nConnected: {addr}\n")
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        # 1. Get MAC
        mac = await _read_mac(client)

        # 2. Auth
        print("\n--- AUTH ---")
        authed = await _do_auth(client, q, mac)

        # 3. Open sync + drain history (required before entering any realtime mode)
        print("\n--- SYNC DRAIN (clears ring buffer so realtime modes work) ---")
        await client.write_gatt_char(ble.WRITE_CHAR, ble.SYNC_ALL, response=True)
        await asyncio.sleep(0.5)
        await _drain(client, q, 1.0, False)
        await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("070000"), response=True)
        await _drain(client, q, 4.0, True)

        # d0 status (required before entering live mode per OpenCircuit PROTOCOL.md §5.1)
        await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("d00000"), response=True)
        await _drain(client, q, 1.0, False)

        # 4+5. Probe each target
        opcode_summary: dict[str, list[int]] = {}
        for label, hexcmd, wait, do_poll in _TARGETS:
            cmd = bytes.fromhex(hexcmd)
            print(f"\n--- {label}: TX {cmd.hex(' ')} ---")
            try:
                await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            except Exception as e:
                print(f"  write error: {e}")
                continue
            if do_poll:
                # For mode-select commands, send 07 00 00 and then poll
                await asyncio.sleep(0.3)
                await client.write_gatt_char(ble.WRITE_CHAR, bytes.fromhex("070000"), response=True)
                await asyncio.sleep(0.3)
                for _ in range(5):
                    await client.write_gatt_char(ble.WRITE_CHAR, ble.KEEPALIVE_PAYLOAD, response=True)
                    await asyncio.sleep(0.5)
            frames = await _drain(client, q, wait, auto_ack=True)
            opcodes = [f[0] for f in frames]
            opcode_summary[label] = opcodes
            if frames:
                print(f"  -> saw opcodes: {[f'0x{o:02x}' for o in opcodes]}")
            else:
                print(f"  -> NO RESPONSE")
            await asyncio.sleep(0.5)

        await client.stop_notify(ble.NOTIFY_CHAR)

    # Summary
    print("\n" + "="*60)
    print("SUMMARY — opcodes seen per probe:")
    print("="*60)
    interesting = {}
    for label, ops in opcode_summary.items():
        known = {0x10, 0x15, 0x47, 0x4A, 0x4C, 0x50, 0x81, 0x82, 0x86, 0x87}
        new_ops = [o for o in ops if o not in known]
        flag = "  <-- NEW" if new_ops else ""
        if ops:
            print(f"  {label:<20} {[f'0x{o:02x}' for o in ops]}{flag}")
            if new_ops:
                interesting[label] = new_ops
        else:
            print(f"  {label:<20} (no response)")
    if interesting:
        print("\n*** INTERESTING NEW OPCODES ***")
        for label, ops in interesting.items():
            for op in ops:
                hint = _MIXIN_HINTS.get(op, "completely unknown")
                print(f"  {label}: 0x{op:02x} — {hint}")
    else:
        print("\nNo new opcodes found in this run.")


if __name__ == "__main__":
    if ADDR is None:
        print("Usage: .venv/bin/python probe_ppg_raw.py <CBPeripheral-UUID>")
        print("       Get UUID from: .venv/bin/python -m opencircuit scan")
        sys.exit(1)
    asyncio.run(main(ADDR))
