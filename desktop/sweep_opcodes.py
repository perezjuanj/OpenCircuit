"""Full opcode space sweep — sends every byte 0x00–0xFF as a command and logs what responds.

Use this AFTER probe_ppg_raw.py has confirmed the ring is responding to auth+sync.

    .venv/bin/python sweep_opcodes.py <CBPeripheral-UUID> [--fast] [--range 0x00-0xFF]

--fast: 0.4s wait instead of 1.0s (riskier, ring may drop frames)
--range: only sweep this hex range, e.g. --range 0x90-0x9F
--keepalive N: send 95 00 00 keepalive every N commands (default: 3) to prevent
               ring BLE supervision timeout (~30-40s without keepalive)

Output: sweep_<UUID>_<timestamp>.txt  (also printed live)

KNOWN DANGEROUS COMMANDS (skip by default):
  0x08 → 0x88 ff  (system diagnostic, may corrupt state)
  0x09 → 0x89     (system command, purpose unknown)
  0x20 → 0xA0 ff  (BleEnterOtaRspMixin? rejected with ff but skip anyway)
  0x21 → 0xA1 00  (CONFIRMED DANGEROUS — bricked ring in 2026-06-26 session)
                   Likely BleEnterOtaRspMixin confirm — caused ring lockup requiring
                   charger restart + forget-device + re-pair.

KEEPALIVE BEHAVIOUR:
  The ring drops its BLE link after ~30-40s without traffic. During long sweeps
  (1.0s/cmd × many opcodes), this fires mid-sweep. The --keepalive option (default 3)
  inserts a 95 00 00 heartbeat every N commands so the supervision timer resets.
  The keepalive frame is not logged as a probe command.
"""
from __future__ import annotations
import asyncio, sys, time, argparse, datetime
from bleak import BleakClient, BleakError
from bleak.exc import BleakCharacteristicNotFoundError
from opencircuit import ble, session
from opencircuit.auth import SYSID_CHAR, mac_from_sysid, auth_command

# Opcodes that are part of the normal protocol flow — skip to avoid confusing the ring.
PROTOCOL_CMDS = {0x01, 0x02, 0x06, 0x07, 0x95, 0xC7, 0xCC, 0xD0}

# Commands confirmed working — already decoded; skip to save time (pass --all to include).
# 0x0D/0x12 → 0x4D: non-destructive peek of batch HR history (confirmed 2026-06-26 sweep)
# 0x22-0x2A: simple acks / device-id / polled HR+SpO2 (confirmed 2026-06-26 sweep)
KNOWN_RESPONDING = {
    0x03, 0x04, 0x05, 0x08, 0x09, 0x0D, 0x12, 0x20, 0x21,
    0x22, 0x23, 0x24, 0x28, 0x29, 0x2A,
}

# Dangerous commands — ALWAYS skip unless explicitly overridden with --danger.
# 0x21 caused a full ring lockup on 2026-06-26 (needed charger restart + re-pair).
# 0x27 → 0xA7 ff (rejected but skipped for safety — paired with 0x20/0x21 OTA group).
DANGEROUS = {0x20, 0x21, 0x08, 0x09}

KNOWN_OPCODES = {0x10, 0x11, 0x15, 0x47, 0x4A, 0x4C, 0x4D, 0x4E, 0x50, 0x81, 0x82,
                 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0xA0, 0xA1,
                 0xA2, 0xA3, 0xA4, 0xA7, 0xA8, 0xA9, 0xAA}

# Raw GATT handle for the write characteristic (0x0802) — use handle directly so
# writes succeed even if service discovery has been lost after a connection drop.
WRITE_HANDLE = 0x0802


async def _write(client: BleakClient, payload: bytes) -> None:
    """Write using UUID so bleak can look it up from the discovered service cache.
    Falls back to raw handle if the UUID lookup fails (post-reconnect edge case).
    Raises BleakError (including BleakCharacteristicNotFoundError) on failure — callers
    should treat that as a disconnect signal."""
    try:
        await client.write_gatt_char(ble.WRITE_CHAR, payload, response=True)
    except BleakCharacteristicNotFoundError:
        # Service cache is empty (ring disconnected) — try raw handle as last resort
        await client.write_gatt_char(WRITE_HANDLE, payload, response=True)


async def main(addr: str, wait: float, lo: int, hi: int,
               include_known: bool, allow_danger: bool, keepalive_n: int = 3) -> None:
    q: asyncio.Queue = asyncio.Queue()
    device = await session._resolve(addr, timeout=15.0)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    outfile = f"sweep_{addr.replace(':', '-').replace('-', '')[:8]}_{ts}.txt"

    disconnected = asyncio.Event()

    def _on_disconnect(_client):
        disconnected.set()
        print("\n  *** RING DISCONNECTED — stopping sweep ***")

    async with BleakClient(device, disconnected_callback=_on_disconnect) as client:
        print(f"Connected: {addr}")
        # Use UUID-based notify for initial subscription (services are known at connect time)
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: q.put_nowait(bytes(d)))
        await asyncio.sleep(0.3)

        # Read MAC + auth
        mac = None
        try:
            raw = await client.read_gatt_char(SYSID_CHAR)
            mac = mac_from_sysid(bytes(raw))
            print(f"MAC: {':'.join(f'{b:02X}' for b in mac) if mac else 'unknown'}")
        except Exception as e:
            print(f"sysid read failed: {e}")

        # Guard every init write — ring may disconnect immediately after connect
        # (stale BLE link / iOS re-pairing changed LTK; toggle Mac BT off/on to fix)
        if disconnected.is_set():
            print("Ring disconnected before auth — aborting. Try: toggle Mac Bluetooth off/on")
            return

        try:
            await _write(client, bytes.fromhex("010000"))
            await asyncio.sleep(0.4)
            challenge_frame = None
            while not q.empty():
                b = q.get_nowait()
                if len(b) >= 3 and b[0] == 0x81:
                    challenge_frame = b
            if challenge_frame and mac:
                cmd = auth_command(challenge_frame[2], mac)
                await _write(client, cmd)
                await asyncio.sleep(0.4)
                while not q.empty():
                    q.get_nowait()
                print(f"Authed OK (challenge=0x{challenge_frame[2]:02x})")
            else:
                print("WARNING: auth skipped — ring will not respond to data commands")

            if disconnected.is_set():
                return

            # Drain history so the ring is in a clean state
            await _write(client, ble.SYNC_ALL)
            await asyncio.sleep(0.5)
            while not q.empty():
                q.get_nowait()
            await _write(client, bytes.fromhex("070000"))
            for _ in range(40):
                try:
                    b = await asyncio.wait_for(q.get(), timeout=1.5)
                    if b[0] == 0x47:
                        await _write(client, bytes.fromhex("c70000"))
                    elif b[0] == 0x4C:
                        await _write(client, bytes.fromhex("cc0000"))
                except asyncio.TimeoutError:
                    break
            await _write(client, bytes.fromhex("d00000"))
            await asyncio.sleep(0.5)
            while not q.empty():
                q.get_nowait()
        except (BleakError, BleakCharacteristicNotFoundError) as e:
            print(f"  Init failed (ring disconnected during setup): {e}")
            return

        # Sweep
        results: dict[int, list[bytes]] = {}
        skipped: dict[int, str] = {}
        print(f"\nSweeping opcodes 0x{lo:02X}–0x{hi:02X} ({hi-lo+1} total, {wait}s each)\n")
        probed_count = 0  # commands actually sent (not skipped) — used for keepalive cadence
        with open(outfile, "w") as f:
            f.write(f"# RingConn opcode sweep {ts} addr={addr} range=0x{lo:02X}-0x{hi:02X}\n\n")

            for cmd_byte in range(lo, hi + 1):
                if disconnected.is_set():
                    print("  Ring disconnected — aborting sweep.")
                    break

                reason = None
                if cmd_byte in PROTOCOL_CMDS:
                    reason = "SKIP (protocol command)"
                elif not allow_danger and cmd_byte in DANGEROUS:
                    reason = "SKIP (DANGEROUS — caused ring lockup 2026-06-26)"
                elif not include_known and cmd_byte in KNOWN_RESPONDING:
                    reason = "SKIP (already mapped — pass --all to re-run)"
                if reason:
                    print(f"  0x{cmd_byte:02X}  {reason}")
                    f.write(f"0x{cmd_byte:02X}  {reason}\n")
                    skipped[cmd_byte] = reason
                    continue

                # Keepalive: send 95 00 00 every `keepalive_n` probed commands to prevent
                # ring BLE supervision timeout (~30-40s). Drain the keepalive response quietly.
                if keepalive_n > 0 and probed_count > 0 and probed_count % keepalive_n == 0:
                    try:
                        await _write(client, bytes.fromhex("950000"))
                        try:
                            await asyncio.wait_for(q.get(), timeout=0.3)
                        except asyncio.TimeoutError:
                            pass
                    except BleakError:
                        pass  # disconnected — will be caught on next probe attempt
                probed_count += 1

                probe = bytes([cmd_byte, 0x00, 0x00])
                try:
                    await _write(client, probe)
                except BleakError as e:
                    if "Service Discovery" in str(e) or "not connected" in str(e).lower():
                        print(f"  0x{cmd_byte:02X}  CONNECTION LOST after previous command — stopping")
                        f.write(f"0x{cmd_byte:02X}  CONNECTION_LOST\n")
                        break
                    print(f"  0x{cmd_byte:02X}  write-err: {e}")
                    f.write(f"0x{cmd_byte:02X}  WRITE_ERROR: {e}\n")
                    continue
                except Exception as e:
                    print(f"  0x{cmd_byte:02X}  write-err: {e}")
                    f.write(f"0x{cmd_byte:02X}  WRITE_ERROR: {e}\n")
                    continue

                frames = []
                try:
                    deadline = time.monotonic() + wait
                    while time.monotonic() < deadline:
                        remaining = deadline - time.monotonic()
                        b = await asyncio.wait_for(q.get(), timeout=max(remaining, 0.05))
                        frames.append(bytes(b))
                        if b[0] == 0x47:
                            await _write(client, bytes.fromhex("c70000"))
                        elif b[0] == 0x4C:
                            await _write(client, bytes.fromhex("cc0000"))
                except asyncio.TimeoutError:
                    pass
                results[cmd_byte] = frames

                if frames:
                    opcodes = [fr[0] for fr in frames]
                    new = [o for o in opcodes if o not in KNOWN_OPCODES]
                    flag = "  *** NEW ***" if new else ""
                    summary = " | ".join(fr.hex(" ")[:60] for fr in frames[:3])
                    print(f"  0x{cmd_byte:02X}  {[f'0x{o:02x}' for o in opcodes]}{flag}")
                    if summary:
                        print(f"        {summary}")
                    f.write(f"0x{cmd_byte:02X}  {[f'0x{o:02x}' for o in opcodes]}\n")
                    for fr in frames:
                        f.write(f"     {fr.hex(' ')}\n")
                else:
                    print(f"  0x{cmd_byte:02X}  (no response)")
                    f.write(f"0x{cmd_byte:02X}  NO_RESPONSE\n")

    # Final tally
    print(f"\n{'='*60}")
    print(f"Results written to: {outfile}")
    responding = {c: rs for c, rs in results.items() if rs}
    print(f"{len(responding)}/{hi-lo+1} commands got responses:")
    for cmd_byte, frames in sorted(responding.items()):
        opcodes = [f"0x{fr[0]:02x}" for fr in frames]
        new = [fr[0] for fr in frames if fr[0] not in KNOWN_OPCODES]
        flag = "  <-- NEW" if new else ""
        print(f"  0x{cmd_byte:02X} -> {opcodes}{flag}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("addr", help="CBPeripheral UUID from `opencircuit scan`")
    p.add_argument("--fast", action="store_true", help="0.4s wait per opcode instead of 1.0s")
    p.add_argument("--range", default="0x00-0xFF",
                   help="hex range to sweep, e.g. 0x22-0x7F (default: 0x00-0xFF)")
    p.add_argument("--all", dest="include_known", action="store_true",
                   help="re-run already-mapped opcodes (0x03-0x09, 0x20-0x21)")
    p.add_argument("--danger", action="store_true",
                   help="UNSAFE: include 0x20/0x21 which bricked ring on 2026-06-26")
    p.add_argument("--keepalive", type=int, default=3, metavar="N",
                   help="send 95 00 00 keepalive every N probed commands (0=disable, default=3)")
    args = p.parse_args()
    lo_s, hi_s = args.range.split("-")
    lo, hi = int(lo_s, 16), int(hi_s, 16)
    wait = 0.4 if args.fast else 1.0
    asyncio.run(main(args.addr, wait, lo, hi, args.include_known, args.danger, args.keepalive))
