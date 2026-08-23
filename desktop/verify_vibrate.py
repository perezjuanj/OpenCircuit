#!/usr/bin/env python3
"""Replay a DECODED command at the ring and let the wearer's finger confirm it.

    python3 verify_vibrate.py --hex "<the frame we send you>"
    python3 verify_vibrate.py --hex "<frame>" --addr <CoreBluetooth-UUID>
    python3 verify_vibrate.py --hex "<frame>" --dry-run   # safety-check only, sends nothing

Note there is deliberately no example frame here. Any plausible-looking constant would
get copy-pasted at a real ring, and the `0x05` family in particular arms PERSISTENT
recording modes (`05 22 01` starts an all-night OSA capture) whose off-switch we may not
know. Use the frame we hand you and nothing else.

WHAT THIS IS FOR
  Stage 2 of the vibrate hunt. Stage 1 is a capture: snoop the official app tapping
  its own "tap to feel the vibration pattern" control, and read the write off the
  wire. This tool then replays that frame from a Mac to prove it reproduces
  independently — one buzz you caused yourself is worth more than any amount of
  inference from bytes.

WHAT THIS IS **NOT** FOR
  Blind opcode hunting. An earlier draft of this tool shipped a table of guessed
  candidates; that was wrong and the table is gone. Nothing in the decompiled app
  reveals the vibrate opcode — it is built at runtime from integer literals inside
  compiled ARM code, not from any constant a strings dump can reach. So a "candidate"
  would be a pure guess, and guesses get written to somebody's real ring. One opcode
  (0x21) BRICKED a ring here on 2026-06-26; recovery took a charger restart,
  forget-device and re-pair. Capture first. It costs twenty minutes and risks nothing.

  This tool therefore requires you to type the frame in explicitly. There is no
  built-in list to sweep.

WHY NOT `python -m opencircuit replay`
  `replay` does not authenticate (session.py:141) and neither does `listen --send`.
  The ring ignores data commands until the per-connection SM3 challenge is answered,
  so a frame sent through those looks dead whether or not it is real — every negative
  is a false negative. This tool authenticates first, then checks battery, because
  the official app refuses to vibrate under 20% and a flat ring would also read as
  a false negative.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime
import sys
from pathlib import Path

from opencircuit import ble
from opencircuit.auth import SYSID_CHAR, auth_command, mac_from_sysid

# bleak is imported LAZILY, inside the connect path only. Everything that does not
# touch the radio — --dry-run, --help, and the safety block — must work on a stock
# `/usr/bin/python3` with nothing installed, so the frame can be sanity-checked
# before anyone sets up an environment.
_BLEAK_HELP = (
    "error: bleak is not installed, so this script cannot reach the radio.\n\n"
    "  cd desktop\n"
    "  python3 -m venv .venv-probe\n"
    "  .venv-probe/bin/pip install --upgrade pip\n"
    "  .venv-probe/bin/pip install bleak\n"
    "  .venv-probe/bin/python verify_vibrate.py --hex \"<frame>\"\n\n"
    "The `--upgrade pip` line is NOT optional: macOS seeds a new venv with pip 21.2.4,\n"
    "which refuses the prebuilt pyobjc wheel, tries to compile it from source, and dies\n"
    "with a wall of clang errors. Upgrading pip first makes the install just work.\n\n"
    "`--dry-run` needs none of this and works right now."
)


def _import_bleak():
    try:
        from bleak import BleakClient, BleakScanner
        from bleak.exc import BleakError
    except ImportError:
        print(_BLEAK_HELP, file=sys.stderr)
        raise SystemExit(1)
    return BleakClient, BleakScanner, BleakError

# ── hard safety block — deliberately no override flag ────────────────────────
# 0x21 bricked a ring (OTA/DFU confirm); 0x20/0x27 are its rejected siblings;
# 0x08/0x09 are system/diagnostic control. `08 04 00` is airplane mode, which drops
# the BLE link until the charging case. A --force would eventually get used, so
# there isn't one; edit the frame instead.
# Source: desktop/sweep_opcodes.py:14-21,46-49 + docs/BLE_INVESTIGATION_LOG.md:59-81.
DANGEROUS_PRIMARY = {0x08, 0x09, 0x20, 0x21, 0x27}
AIRPLANE = bytes.fromhex("080400")

SETTLE = 2.5  # seconds to wait for a buzz + reply after each write


def check_safe(frame: bytes) -> None:
    """Refuse a frame whose PRIMARY opcode is on the block list."""
    if not frame:
        raise SystemExit("error: empty frame")
    if frame[0] in DANGEROUS_PRIMARY:
        raise SystemExit(
            f"REFUSING to send {frame.hex(' ')}.\n"
            f"Primary opcode 0x{frame[0]:02x} is on the hard block list (OTA / system\n"
            f"control). 0x21 bricked a ring in June 2026 and needed a charger restart,\n"
            f"forget-device and re-pair to recover. There is no override flag."
        )
    if frame[:3] == AIRPLANE:
        raise SystemExit(
            "REFUSING: `08 04 00` is airplane mode. It drops the BLE link until you put\n"
            "the ring in its charging case."
        )


def _self_test() -> None:
    """The block list must actually block. Cheap, and runs on every invocation."""
    for bad in (b"\x21\x00\x00", b"\x20\x01\x00", AIRPLANE):
        try:
            check_safe(bad)
        except SystemExit:
            continue
        raise AssertionError(f"safety check failed to block {bad.hex()}")


class Log:
    def __init__(self, path: Path):
        self.path, self.lines, self.replies = path, [], []

    def note(self, s: str = "") -> None:
        print(s)
        self.lines.append(s)

    def flush(self) -> None:
        """Write the session file and say where it is.

        Called from a `finally`, so it must run on EVERY exit path — an early
        return, a Ctrl-C, or an unexpected exception. A helper who spent an evening
        on this should never be left without the file, least of all when something
        went wrong and the file is most useful.
        """
        self.path.write_text("\n".join(self.lines) + "\n")
        print(f"\nWrote {self.path}")
        print("Send that file back — including if nothing buzzed.")

    def on_notify(self, _sender, data: bytearray) -> None:
        self.replies.append(bytes(data))


async def _write(client, payload: bytes) -> None:
    await client.write_gatt_char(ble.WRITE_CHAR, payload, response=True)


async def run(frame: bytes, address: str | None, repeats: int, dry_run: bool) -> int:
    _self_test()
    check_safe(frame)
    if not dry_run:
        # Fail on a missing dependency BEFORE opening a session file, so we never
        # leave a stub that looks like a real (empty) result.
        _import_bleak()

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log = Log(Path(__file__).with_name(f"vibrate_verify_{ts}.txt"))
    log.note("OpenCircuit — vibrate frame verification")
    log.note(f"Started: {datetime.datetime.now().isoformat(timespec='seconds')}")
    log.note(f"Frame:   {frame.hex(' ')}   ({repeats} attempt(s))")
    log.note("")
    try:
        return await _session(frame, address, repeats, dry_run, log)
    finally:
        log.flush()


async def _session(frame: bytes, address: str | None, repeats: int, dry_run: bool,
                   log: "Log") -> int:
    if dry_run:
        log.note("DRY RUN — passed the safety check, nothing sent.")
        return 0

    BleakClient, BleakScanner, BleakError = _import_bleak()

    if address:
        dev = await BleakScanner.find_device_by_address(address, timeout=30.0) or address
    else:
        log.note("Scanning up to 30 s for a RingConn …")
        dev = await BleakScanner.find_device_by_filter(
            lambda d, ad: bool(d.name and d.name.startswith(ble.NAME_PREFIXES)), timeout=30.0)
        if dev is None:
            log.note("No RingConn found. Check all three:")
            log.note("  1. Bluetooth is OFF on your iPhone (or the RingConn app is force-quit)")
            log.note("     — the ring accepts one connection at a time 🟡, and the phone wins.")
            log.note("  2. macOS has allowed Terminal to use Bluetooth: System Settings ▸")
            log.note("     Privacy & Security ▸ Bluetooth. Without it the Mac sees nothing at all.")
            log.note("  3. The ring is awake — move it, and keep it off the charger.")
            return 1
        log.note(f"Found: {dev.name}")

    dropped = asyncio.Event()
    try:
        client = BleakClient(dev, disconnected_callback=lambda _c: dropped.set())
        async with client:
            log.note("Connected.")
            await client.start_notify(ble.NOTIFY_CHAR, log.on_notify)
            await asyncio.sleep(0.3)

            # ── auth ─────────────────────────────────────────────────────────
            try:
                mac = mac_from_sysid(bytes(await client.read_gatt_char(SYSID_CHAR)))
            except Exception as exc:
                log.note(f"WARN: could not read System ID ({exc})")
                mac = None

            log.replies.clear()
            await _write(client, bytes.fromhex("010000"))
            await asyncio.sleep(0.5)
            challenge = next((r[2] for r in log.replies if len(r) >= 3 and r[0] == 0x81), None)
            if challenge is None or mac is None:
                log.note("")
                log.note("AUTH FAILED — no challenge from the ring, or its MAC is unreadable.")
                log.note("Unauthenticated, the ring ignores commands, so a 'no buzz' here would")
                log.note("mean nothing. Stopping rather than recording a false negative.")
                log.flush()
                return 1
            mac_str = ":".join(f"{b:02X}" for b in mac)
            await _write(client, auth_command(challenge, mac))
            await asyncio.sleep(0.5)
            log.note(f"Auth answered (challenge 0x{challenge:02x}, MAC {mac_str}).")

            # A SOFT witness only. `95 00 00` reliably returns `15 00 <hr>` in live-HR
            # mode; outside it the ring may legitimately stay silent even when properly
            # authenticated (PROTOCOL.md §5 — the app sends `d0 00 00` → `06 01 00` →
            # fetch BEFORE polling). So a 0x15 proves auth worked; its absence proves
            # nothing, and must not abort the run. Treating silence as failure here
            # would be the same false-negative trap this tool exists to avoid.
            log.replies.clear()
            await _write(client, ble.KEEPALIVE_PAYLOAD)
            await asyncio.sleep(1.0)
            if any(r and r[0] == 0x15 for r in log.replies):
                log.note("Auth CONFIRMED — the ring answered a data command. 🟢")
            else:
                log.note("Auth not independently confirmed (no 0x15 outside live-HR mode —")
                log.note("expected, and not a failure). If nothing buzzes AND nothing replies")
                log.note("below, suspect the bond rather than the frame.")

            # ── battery gate ────────────────────────────────────────────────
            # The app refuses below 20% ("Vibration can't start. Battery must be above
            # 20%."), so a flat ring yields a whole run of false NOs.
            # `d0 00 00` is the status query (Opcodes.swift:41 → 0x10/0x50). The ring
            # also broadcasts an unsolicited 0x10 descriptor every ~30-60 s, so if the
            # query doesn't answer we wait for that rather than guess.
            # Parsing matches the certified decoder (DeviceStatus.battery): a descriptor
            # is 19+ bytes and the percentage must land in 1...100.
            def _battery_from(frames) -> int | None:
                for r in frames:
                    if len(r) >= 19 and r[0] in (0x10, 0x87) and 1 <= r[1] <= 100:
                        return r[1]
                return None

            log.replies.clear()
            await _write(client, bytes.fromhex("d00000"))
            await asyncio.sleep(3.0)
            battery = _battery_from(log.replies)
            if battery is None:
                log.note("Waiting up to 65 s for the ring's own status broadcast (battery)…")
                for _ in range(65):
                    await asyncio.sleep(1.0)
                    battery = _battery_from(log.replies)
                    if battery is not None:
                        break

            if battery is None:
                log.note("WARN: battery unreadable. If the ring is nearly flat this whole run")
                log.note("      is meaningless — check the level in the app before believing a 'no'.")
            else:
                log.note(f"Ring battery: {battery}%")
                if battery <= 20:
                    log.note("")
                    log.note("STOP — below 20% the ring will not vibrate at all, so this test")
                    log.note("cannot produce a meaningful result. Charge it and re-run.")
                    return 1

            log.note("")
            log.note("Put the ring ON YOUR FINGER now.")
            log.note("-" * 62)

            buzzes = 0
            for i in range(1, repeats + 1):
                if dropped.is_set():
                    log.note("Ring disconnected — stopping.")
                    break
                log.replies.clear()
                try:
                    await _write(client, frame)
                except BleakError as exc:
                    log.note(f"attempt {i}: WRITE FAILED ({exc})")
                    break
                await asyncio.sleep(SETTLE)
                reply = " | ".join(r.hex(" ") for r in log.replies) or "(no reply)"

                # The ring drops the link after ~30-40 s of silence, and the prompt
                # below is a BLOCKING builtin `input()` — it freezes the event loop
                # until the human answers, so nothing can be sent while we wait. Send
                # the keepalive BEFORE asking, and run a heartbeat on a worker thread
                # so a slow answer can't cost us the connection mid-run.
                try:
                    await _write(client, ble.KEEPALIVE_PAYLOAD)
                except BleakError:
                    pass

                alive = asyncio.Event()

                async def _heartbeat() -> None:
                    while not alive.is_set():
                        await asyncio.sleep(12.0)
                        if alive.is_set():
                            return
                        try:
                            await _write(client, ble.KEEPALIVE_PAYLOAD)
                        except BleakError:
                            return

                beat = asyncio.create_task(_heartbeat())
                try:
                    ans = (await asyncio.to_thread(
                        input, f"  attempt {i}/{repeats}: DID IT BUZZ? [y/N/q] ")).strip().lower()
                except (EOFError, KeyboardInterrupt):
                    ans = "q"
                finally:
                    alive.set()
                    beat.cancel()

                if ans.startswith("q"):
                    log.note(f"attempt {i}: -> {reply}   [aborted]")
                    break
                felt = ans.startswith("y")
                buzzes += felt
                log.note(f"attempt {i}: -> {reply}   BUZZ={'YES' if felt else 'no'}")

            log.note("-" * 62)
            log.note(f"Buzzed on {buzzes} of {repeats} attempts.")
            if buzzes == repeats and repeats > 1:
                log.note("REPRODUCIBLE — this frame drives the motor. 🟢")
            elif buzzes:
                log.note("INTERMITTENT — buzzed sometimes. Note anything else happening on the")
                log.note("ring or phone; a partial result usually means a precondition varies.")
            else:
                log.note("No buzz. That is still a real result — it rules this frame out.")
    except BleakError as exc:
        log.note(f"BLE error: {exc}")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Replay one decoded command and confirm it by feel.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--hex", required=True,
                    help="the frame to send, exactly as we sent it to you — read off a "
                         "capture, never guessed")
    ap.add_argument("--addr", default=None, help="ring address / UUID (default: scan by name)")
    ap.add_argument("--repeats", type=int, default=3,
                    help="times to send it (default 3; one buzz could be coincidence)")
    ap.add_argument("--dry-run", action="store_true", help="safety-check only, send nothing")
    args = ap.parse_args(argv)

    try:
        frame = bytes.fromhex(args.hex.replace(" ", "").replace("0x", ""))
    except ValueError:
        print(f'error: --hex "{args.hex}" is not valid hex', file=sys.stderr)
        return 1

    try:
        return asyncio.run(run(frame, args.addr, max(1, args.repeats), args.dry_run))
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
