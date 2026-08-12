#!/usr/bin/env python3
"""Capture the ring's AUTO-DETECTED workout (`AutoSports`) frame — the #179 gate.

Background (2026-07-20 RE): the official RingConn app decodes auto-detected workouts
through a DISTINCT `BleAutoSportsRsp` handler, NOT the `0x4d` history-sport page our
iOS app currently (mis)reads. `0x4d` is the store-and-forward history of workouts you
STARTED (every capture's `0x4d` follows a manual `06 03`). So the auto-detection path
lives on a different opcode/selector we have never captured — because in every existing
snoop the official app only ever toggled recognition on for ~2 s and never left it
running. This tool captures that missing frame under our own control (SM3 auth works
from the Mac), so we can build a real decoder against real bytes instead of guessing.

Recognition is enabled with `05 23 01 00` (🟢 ring acks `85 00`; = the official app's
`autoSportRecognitionEnable`). find-ring is a *different* opcode (`24 01 00`).

Two-phase, because ring-side recognition is store-and-forward: it needs a sustained
bout while enabled and only dumps on a later reconnect.

  # 1. ARM: enable recognition, then walk 15+ min WEARING the ring (phone can be away).
  python capture_autosport.py --phase arm --addr <ADDR>

  # 2. DRAIN: reconnect and pull everything, flagging any opcode we don't already decode.
  python capture_autosport.py --phase drain --out autosport.log --addr <ADDR>

If our iOS app already armed recognition earlier today, the auto-detected data from a
walk may STILL be on the ring undrained (our app only drains `0x4d`). So try `drain`
FIRST with no new walk — it may already be sitting there.

  python capture_autosport.py --phase drain --out autosport.log

The ring holds ONE central connection: disconnect it from every phone first
(force-quit OpenCircuit / the RingConn app, or turn the phone's Bluetooth off).
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import time

from bleak import BleakClient, BleakScanner

from opencircuit import auth, ble
from opencircuit.session import _looks_like_ring, _resolve

# Push opcodes the ring is already known to send AND that we already decode (from the
# full capture corpus 2026-07: 48 10 4c 87 4e 47 81 15 82 86 50 11 4d 88 85 a4 a0, plus
# the ack/status bytes). Anything OUTSIDE this set on a recognition-armed drain is an
# AutoSports candidate — the whole point of this run.
KNOWN_OPCODES = {
    0x48, 0x10, 0x4C, 0x87, 0x4E, 0x47, 0x81, 0x15, 0x82, 0x86,
    0x50, 0x11, 0x4D, 0x88, 0x85, 0xA4, 0xA0, 0x8F, 0x91, 0x95,
}

ARM_RECOGNITION = bytes([0x05, 0x23, 0x01, 0x00])   # autoSportRecognitionEnable = on
DISARM_RECOGNITION = bytes([0x05, 0x23, 0x00, 0x00])
FETCH = bytes([0x07, 0x00, 0x00])


def _ack_for(opcode: int) -> bytes | None:
    """The byte that pulls the NEXT page of a store-and-forward stream.

    For the 0x4X page family the continue-ack is `opcode | 0x80` (0x4c→0xcc, 0x47→0xc7,
    0x4d→0xcd, …); a 0x87 record header is continued with 0x07. Generalising this — vs.
    the workbench's fixed {0x4c,0x47,0x87} map — is what lets a NEVER-BEFORE-SEEN
    AutoSports opcode keep draining instead of stalling after its first page.
    """
    if 0x40 <= opcode <= 0x4F:
        return bytes([opcode | 0x80, 0x00, 0x00])
    # NB: do NOT ack a 0x87 — when the ring is idle it repeats a status SENTINEL
    # verbatim, and a 0x07 "fetch" reply just makes it resend, spinning the drain.
    # Only the 0x4X page family is a real store-and-forward stream worth continuing.
    return None


async def _connect(address: str | None):
    if address:
        return await _resolve(address, timeout=30.0)
    print("No --addr; scanning up to 30 s for a RingConn by name …")
    device = await BleakScanner.find_device_by_filter(
        lambda d, ad: _looks_like_ring(d.name), timeout=30.0)
    if device is None:
        raise RuntimeError(
            "No RingConn found. Wake the ring and make sure it is NOT connected to a "
            "phone (force-quit OpenCircuit / RingConn), or pass --addr.")
    return device


async def _authenticate(client: BleakClient, frames: list[tuple[float, bytes]]) -> None:
    """Per-connection SM3 auth (same handshake as probe-channels)."""
    mac = None
    with contextlib.suppress(Exception):
        sysid = bytes(await client.read_gatt_char(auth.SYSID_CHAR))
        mac = auth.mac_from_sysid(sysid)
        print(f"# system-id {sysid.hex(' ')} -> mac "
              f"{':'.join(f'{b:02x}' for b in mac) if mac else '??'}")

    base = len(frames)
    await client.write_gatt_char(ble.WRITE_CHAR, bytes([0x01, 0x00, 0x00]), response=True)
    challenge = None
    t0 = time.time()
    while time.time() - t0 < 2.0:
        for _, d in frames[base:]:
            if d and d[0] == 0x81 and len(d) >= 3:
                challenge = d[2]
                break
        if challenge is not None:
            break
        await asyncio.sleep(0.05)

    if challenge is not None and mac is not None:
        auth_cmd = auth.auth_command(challenge, mac)
        print(f"# auth challenge=0x{challenge:02x} -> resp {auth_cmd.hex(' ')}")
    else:
        auth_cmd = bytes([0x01, 0x01, 0x31, 0x82, 0x67, 0x00])  # fixed f(0xb0) fallback
        print(f"# auth fallback (challenge="
              f"{f'0x{challenge:02x}' if challenge is not None else 'none'}, "
              f"mac={'yes' if mac else 'no'})")
    await client.write_gatt_char(ble.WRITE_CHAR, auth_cmd, response=True)
    await asyncio.sleep(0.4)


async def phase_arm(address: str | None) -> None:
    """Enable ring-side recognition and confirm the ack, then leave it running."""
    device = await _connect(address)
    frames: list[tuple[float, bytes]] = []
    async with BleakClient(device) as client:
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: frames.append((time.time(), bytes(d))))
        await _authenticate(client, frames)

        base = len(frames)
        await client.write_gatt_char(ble.WRITE_CHAR, ARM_RECOGNITION, response=True)
        print(f"→ sent ARM {ARM_RECOGNITION.hex(' ')} (autoSportRecognitionEnable = on)")
        acked = False
        t0 = time.time()
        while time.time() - t0 < 2.0:
            for _, d in frames[base:]:
                if d and d[0] == 0x85:
                    print(f"← ack {d.hex(' ')}  ✅ recognition ENABLED")
                    acked = True
                    break
            if acked:
                break
            await asyncio.sleep(0.05)
        if not acked:
            print("⚠️  no 0x85 ack seen — recognition may NOT be enabled. Re-run --phase arm.")
        await asyncio.sleep(0.3)
    print("\nRecognition is armed on the ring (survives disconnect). Now WALK 15+ minutes "
          "wearing the ring, then run:  --phase drain --out autosport.log")


async def phase_listen(address: str | None, seconds: float, out_path: str | None) -> None:
    """Stay CONNECTED with recognition armed and log every frame — the correct capture
    if AutoSports is a realtime push (the official app caught its 63 bouts by being
    connected DURING them; a later drain finds nothing because the ring doesn't buffer
    the recognizer's HR-feature stream for backfill). Keep the Mac near you and walk
    15+ min; anything the ring pushes lands here and unknown opcodes are flagged.
    """
    device = await _connect(address)
    frames: list[tuple[float, bytes]] = []
    log: list[str] = []

    def note(line: str = "") -> None:
        print(line)
        log.append(line)

    async with BleakClient(device) as client:
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: frames.append((time.time(), bytes(d))))
        await _authenticate(client, frames)
        await client.write_gatt_char(ble.WRITE_CHAR, ARM_RECOGNITION, response=True)
        note(f"# armed recognition {ARM_RECOGNITION.hex(' ')}; LISTENING {int(seconds)}s — walk now")

        seen = len(frames)
        deadline = time.time() + seconds
        last_beat = time.time()
        while time.time() < deadline:
            if len(frames) > seen:
                for ts, d in frames[seen:]:
                    op = d[0] if d else -1
                    if op not in (0x87, 0x10, 0x82):  # skip idle keepalive/status chatter
                        flag = "" if op in KNOWN_OPCODES else "  <<< UNKNOWN OPCODE (AutoSports candidate)"
                        note(f"  RX 0x{op:02x}  {d.hex(' ')}{flag}")
                    ack = _ack_for(op)
                    if ack:
                        with contextlib.suppress(Exception):
                            await client.write_gatt_char(ble.WRITE_CHAR, ack, response=True)
                seen = len(frames)
            # light keepalive so the ring doesn't drop us mid-walk
            if time.time() - last_beat > 20:
                with contextlib.suppress(Exception):
                    await client.write_gatt_char(ble.WRITE_CHAR, ble.KEEPALIVE_PAYLOAD, response=True)
                last_beat = time.time()
            await asyncio.sleep(0.1)

    counts: dict[int, int] = {}
    for _, d in frames:
        if d:
            counts[d[0]] = counts.get(d[0], 0) + 1
    note("\n# ===== opcode summary =====")
    for op in sorted(counts):
        tag = "known" if op in KNOWN_OPCODES else "★ UNKNOWN — AutoSports candidate"
        note(f"#   0x{op:02x}  x{counts[op]:<4}  {tag}")
    unknown = [op for op in counts if op not in KNOWN_OPCODES]
    note(f"\n# {'FOUND unknown opcode(s): ' + ', '.join(f'0x{o:02x}' for o in unknown) if unknown else 'No unknown opcodes seen while connected.'}")
    if out_path:
        with open(out_path, "w") as f:
            f.write("\n".join(log))
        print(f"\n# wrote {out_path}")


async def phase_drain(address: str | None, channels: list[int], out_path: str | None,
                      rearm: bool) -> None:
    """Sweep every sync selector, drain each (generalised ack), flag unknown opcodes."""
    device = await _connect(address)
    frames: list[tuple[float, bytes]] = []
    log: list[str] = []

    def note(line: str = "") -> None:
        print(line)
        log.append(line)

    async with BleakClient(device) as client:
        await client.start_notify(ble.NOTIFY_CHAR, lambda _s, d: frames.append((time.time(), bytes(d))))
        await _authenticate(client, frames)

        # Re-arm in the SAME session too, so a drain-only attempt at least guarantees the
        # feature is on for anything the ring buffers from here on.
        if rearm:
            await client.write_gatt_char(ble.WRITE_CHAR, ARM_RECOGNITION, response=True)
            note(f"# re-armed recognition {ARM_RECOGNITION.hex(' ')}")
            await asyncio.sleep(0.3)

        note(f"# capture-autosport  channels={', '.join(f'0x{c:02x}' for c in channels)}")
        for ch in channels:
            marker = len(frames)
            note(f"\n# --- selector 0x{ch:02x} ---")
            await client.write_gatt_char(
                ble.WRITE_CHAR, ble.sync_cursor_cmd(time.time(), channel=ch), response=True)
            await asyncio.sleep(0.15)
            await client.write_gatt_char(ble.WRITE_CHAR, FETCH, response=True)

            seen = marker
            quiet_t0 = time.time()
            deadline = time.time() + 10.0
            while time.time() < deadline:
                if len(frames) > seen:
                    for _, d in frames[seen:]:
                        if d:
                            ack = _ack_for(d[0])
                            if ack:
                                with contextlib.suppress(Exception):
                                    await client.write_gatt_char(ble.WRITE_CHAR, ack, response=True)
                    seen = len(frames)
                    quiet_t0 = time.time()
                elif time.time() - quiet_t0 > 1.5:
                    break
                await asyncio.sleep(0.05)

            for ts, d in frames[marker:]:
                op = d[0] if d else -1
                flag = "" if op in KNOWN_OPCODES else "  <<< UNKNOWN OPCODE (AutoSports candidate)"
                note(f"  RX 0x{op:02x}  {d.hex(' ')}{flag}")

    # Summary: which opcodes appeared, and which are candidates.
    counts: dict[int, int] = {}
    for _, d in frames:
        if d:
            counts[d[0]] = counts.get(d[0], 0) + 1
    note("\n# ===== opcode summary =====")
    for op in sorted(counts):
        tag = "known" if op in KNOWN_OPCODES else "★ UNKNOWN — AutoSports candidate"
        note(f"#   0x{op:02x}  x{counts[op]:<4}  {tag}")
    unknown = [op for op in counts if op not in KNOWN_OPCODES]
    note(f"\n# {'FOUND ' + str(len(unknown)) + ' unknown opcode(s): ' + ', '.join(f'0x{o:02x}' for o in unknown) if unknown else 'No unknown opcodes — ring produced no AutoSports data (not armed, or none recognised).'}")

    if out_path:
        with open(out_path, "w") as f:
            f.write("\n".join(log))
        print(f"\n# wrote {out_path}")


def main() -> int:
    p = argparse.ArgumentParser(description="Capture the ring's AutoSports frame (#179 gate).")
    p.add_argument("--phase", choices=["arm", "drain", "listen"], default="drain")
    p.add_argument("--addr", default=None, help="ring BLE address/UUID (skips scan)")
    p.add_argument("--seconds", type=float, default=1200.0,
                   help="listen phase: how long to stay connected (default 20 min)")
    p.add_argument("--channels", default=None,
                   help="comma-separated selectors to sweep, e.g. 0x00,0x02,0x03 "
                        "(default: 0x00–0x1f)")
    p.add_argument("--out", default=None, help="write the full frame log here")
    p.add_argument("--no-rearm", action="store_true",
                   help="drain phase: do NOT re-send 05 23 01 00 before draining")
    args = p.parse_args()

    if args.phase == "arm":
        asyncio.run(phase_arm(args.addr))
        return 0

    if args.phase == "listen":
        asyncio.run(phase_listen(args.addr, args.seconds, args.out))
        return 0

    if args.channels:
        channels = [int(c, 16) if c.lower().startswith("0x") else int(c)
                    for c in args.channels.split(",")]
    else:
        channels = list(range(0x00, 0x20))
    asyncio.run(phase_drain(args.addr, channels, args.out, rearm=not args.no_rearm))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
