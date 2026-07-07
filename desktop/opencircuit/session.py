"""Live BLE session helpers built on bleak: scan, enumerate, listen, replay, probe."""

from __future__ import annotations

import asyncio
import contextlib
import os
import time
from datetime import datetime

from bleak import BleakClient, BleakScanner

from . import auth, ble


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
                 keepalive: bool = False, duration: float | None = None,
                 start_hr: bool = False, sends: list[str] | None = None) -> None:
    """Subscribe to the notify characteristic and log every payload as hex.

    --send HEX (repeatable) writes arbitrary command frames verbatim after
    subscribing (commands are NOT checksummed — bytes are sent as-is).
    --start-hr is a shortcut for the live-HR start sequence (06 01 00, 07 00 00).
    --keepalive then polls (95 00 00) every second so the ring keeps emitting
    0x15 live samples (byte[2] = HR).
    """
    # Build the on-connect write sequence.
    frames: list[bytes] = [bytes.fromhex(h.replace(" ", "")) for h in (sends or [])]
    if start_hr:
        frames += ble.LIVE_HR_START_SEQ

    device = await _resolve(address)
    print(f"Connecting to {address} …")
    async with BleakClient(device) as client:
        print(f"Connected. Subscribing to {notify_char}. Ctrl-C to stop.\n")
        await client.start_notify(notify_char, _make_handler("notify"))

        for cmd in frames:
            print(f"  -> send {cmd.hex(' ')}")
            with contextlib.suppress(Exception):
                await client.write_gatt_char(ble.WRITE_CHAR, cmd, response=True)
            await asyncio.sleep(0.4)

        async def keepalive_loop():
            while True:
                with contextlib.suppress(Exception):
                    # Write char advertises `write` (not write-no-response) -> response=True.
                    await client.write_gatt_char(
                        ble.WRITE_CHAR, ble.KEEPALIVE_PAYLOAD, response=True
                    )
                await asyncio.sleep(1.0)

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


# How to continue a drain: a 0x4c/0x47 page is ACKed to pull the next; a 0x87 header
# is advanced with a fresh 0x07 fetch. Real history = 0x4c/0x47 PAGES only — a bare
# 0x87 the ring repeats verbatim is an idle status sentinel, not data.
_ACK_FOR = {0x4C: 0xCC, 0x47: 0xC7, 0x87: 0x07}  # keep the drain flowing
_END_OPCODE = 0x50                        # end-of-history marker
_LIVE_OPCODES = {0x10, 0x11, 0x15}        # unsolicited telemetry/heartbeat/live-HR


async def probe_channels(
    address: str | None = None,
    channels: list[int] | None = None,
    per_channel_timeout: float = 8.0,
    quiet_after: float = 1.5,
    max_frames: int = 120,
    ack: bool = True,
    warmup: bool = True,
    out_path: str | None = None,
) -> None:
    """Sweep the `0x02` sync-open `byte[6]` selector to discover undecoded history
    channels (activity/steps/stress/temp — #9/#93/#94).

    For each candidate channel we authenticate once, send the sync-open + a `0x07`
    fetch, then drain (auto-ACKing pages) until quiet. `0x00` (sleep) and `0x03`
    (all-day) are known-good positive controls; any OTHER channel that returns
    record frames is a discovery. If nothing beyond 0x00/0x03 answers, that is the
    definitive "the ring doesn't stream it → it's cloud-computed" verdict.

    The ring holds ONE central connection — disconnect it from the phone(s) first.
    """
    if channels is None:
        # Unknown candidates first (0x02 = the predicted activity/ringData selector),
        # the two known controls LAST so their backlog drain can't spill into and
        # mask the channels we actually care about.
        controls = [0x00, 0x03]
        channels = [c for c in range(0x00, 0x20) if c not in controls] + controls

    # The ring advertises INTERMITTENTLY when idle — a short scan window misses it,
    # so give resolution a generous 30 s.
    if address:
        device = await _resolve(address, timeout=30.0)
    else:
        print("No --addr given; scanning up to 30 s for a RingConn by name …")
        device = await BleakScanner.find_device_by_filter(
            lambda d, ad: _looks_like_ring(d.name), timeout=30.0)
        if device is None:
            raise RuntimeError(
                "No RingConn found while scanning. Wake the ring and make sure it is "
                "NOT connected to a phone, or pass --addr.")
    addr = device.address if not isinstance(device, str) else device

    log: list[str] = []
    frames: list[tuple[float, bytes]] = []

    def note(line: str = "") -> None:
        print(line)
        log.append(line)

    def handler(_sender, data: bytearray) -> None:
        frames.append((time.time(), bytes(data)))

    note(f"# probe-channels  addr={addr}  "
         f"channels={', '.join(f'0x{c:02x}' for c in channels)}")
    print(f"Connecting to {addr} …")
    async with BleakClient(device) as client:
        await client.start_notify(ble.NOTIFY_CHAR, handler)

        # ── MAC via GATT System ID (CoreBluetooth hides the raw address on macOS) ──
        mac = None
        try:
            sysid = bytes(await client.read_gatt_char(auth.SYSID_CHAR))
            mac = auth.mac_from_sysid(sysid)
            note(f"# system-id {sysid.hex(' ')} -> mac "
                 f"{':'.join(f'{b:02x}' for b in mac) if mac else '??'}")
        except Exception as exc:  # noqa: BLE001
            note(f"# WARN could not read System ID ({exc}); using fixed-auth fallback")

        # ── per-connection auth: request challenge, answer with SM3(f(challenge)) ──
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
            note(f"# auth challenge=0x{challenge:02x} -> resp {auth_cmd.hex(' ')}")
        else:
            auth_cmd = bytes([0x01, 0x01, 0x31, 0x82, 0x67, 0x00])  # fixed f(0xb0) fallback
            note(f"# auth fallback (challenge="
                 f"{f'0x{challenge:02x}' if challenge is not None else 'none'}, "
                 f"mac={'yes' if mac else 'no'}) -> {auth_cmd.hex(' ')}")
        await client.write_gatt_char(ble.WRITE_CHAR, auth_cmd, response=True)
        await asyncio.sleep(0.4)

        # ── warm-up: consume any residual backlog left over from the connect/auth
        #    drain, so it isn't misattributed to the FIRST channel in the sweep.
        #    DISABLE (--no-warmup) for a selector test on a loaded ring: there the
        #    "residual" IS the pending queue, and we WANT the first channel to
        #    receive it so we can see whether byte[6] changes what's delivered. ──
        if warmup:
            await client.write_gatt_char(ble.WRITE_CHAR, bytes([0x07, 0x00, 0x00]), response=True)
            warm = len(frames)
            wt0 = time.time()
            while time.time() - wt0 < 2.0:
                if len(frames) > warm:
                    for _, d in frames[warm:]:
                        if d and ack and d[0] in _ACK_FOR:
                            with contextlib.suppress(Exception):
                                await client.write_gatt_char(
                                    ble.WRITE_CHAR, bytes([_ACK_FOR[d[0]], 0x00, 0x00]), response=True)
                    warm = len(frames)
                await asyncio.sleep(0.05)
            note(f"# warm-up: {len(frames)} residual frame(s) drained before sweep")
        else:
            note("# warm-up SKIPPED (--no-warmup): first channel receives the full pending queue")

        # ── sweep ──────────────────────────────────────────────────────────────
        # A channel "has data" ONLY if it streams real 0x4c/0x47 pages. The 0x87 we
        # get back from a fetch is a record header OR — when the ring is idle — a
        # status SENTINEL it repeats verbatim; counting those was the false-positive
        # that made every selector look live. So: page frames = the signal; an 0x87
        # identical to the last one means "idle, stop fetching".
        results: list[dict] = []
        for ch in channels:
            marker = len(frames)
            note(f"\n# --- channel 0x{ch:02x} ---")
            await client.write_gatt_char(
                ble.WRITE_CHAR, ble.sync_cursor_cmd(time.time(), channel=ch), response=True)
            await asyncio.sleep(0.15)
            await client.write_gatt_char(ble.WRITE_CHAR, bytes([0x07, 0x00, 0x00]), response=True)

            seen = marker
            pages = 0                       # real data pages (0x4c/0x47) — the only reliable signal
            headers: set[bytes] = set()     # distinct 0x87 record headers seen
            opcodes: dict[int, int] = {}
            last_header: bytes | None = None
            sentinel_repeat = 0
            saw_end = False
            start = last = time.time()
            while True:
                if len(frames) > seen:
                    for ts, d in frames[seen:]:
                        if not d:
                            continue
                        op = d[0]
                        opcodes[op] = opcodes.get(op, 0) + 1
                        log.append(f"  {ts:.3f}  0x{ch:02x} <- [{len(d):>3}]  {d.hex(' ')}")
                        if op == _END_OPCODE:
                            saw_end = True
                        elif op in (0x4C, 0x47):        # real data page → ACK to pull the next
                            pages += 1
                            if ack:
                                with contextlib.suppress(Exception):
                                    await client.write_gatt_char(
                                        ble.WRITE_CHAR, bytes([_ACK_FOR[op], 0x00, 0x00]), response=True)
                        elif op == 0x87:               # record header, or idle status sentinel
                            body = bytes(d)
                            if body == last_header:
                                sentinel_repeat += 1   # same header again → ring is idle
                            else:
                                sentinel_repeat = 0
                                headers.add(body)
                                last_header = body
                                if ack:                # a NEW header → advance to the next record
                                    with contextlib.suppress(Exception):
                                        await client.write_gatt_char(
                                            ble.WRITE_CHAR, bytes([0x07, 0x00, 0x00]), response=True)
                        elif op == 0x11 and ack:       # answer heartbeats so the ring keeps talking
                            with contextlib.suppress(Exception):
                                await client.write_gatt_char(
                                    ble.WRITE_CHAR, bytes([0x91, 0x00, 0x00]), response=True)
                    seen = len(frames)
                    last = time.time()
                now = time.time()
                if saw_end or pages >= max_frames:
                    break
                if sentinel_repeat >= 2 and pages == 0:   # idle status loop, no data → done fast
                    break
                if now - start >= per_channel_timeout:
                    break
                if now - last >= quiet_after and now - start > 0.5:
                    break
                await asyncio.sleep(0.05)

            live = sum(n for o, n in opcodes.items() if o in _LIVE_OPCODES)
            verdict = "DATA" if pages > 0 else "empty"
            note(f"# channel 0x{ch:02x}: {len(frames) - marker} frames "
                 f"({pages} data page, {len(headers)} distinct header, {live} live/hb) -> {verdict}")
            results.append({"ch": ch, "total": len(frames) - marker, "pages": pages,
                            "headers": len(headers), "opcodes": dict(opcodes), "verdict": verdict})
            await asyncio.sleep(0.3)  # let stragglers settle before the next channel's marker

        with contextlib.suppress(Exception):
            await client.stop_notify(ble.NOTIFY_CHAR)

    # ── summary ────────────────────────────────────────────────────────────────
    known = {0x00: "sleep (control)", 0x03: "all-day (control)"}
    note("\n===== SUMMARY =====")
    note(f"  {'chan':<6}{'frames':>7}{'pages':>7}  {'verdict':<7} opcodes / note")
    for r in sorted(results, key=lambda x: x["ch"]):
        ops = ", ".join(f"0x{o:02x}:{n}" for o, n in sorted(r["opcodes"].items())) or "—"
        tag = known.get(r["ch"], "")
        note(f"  0x{r['ch']:02x}  {r['total']:>7}{r['pages']:>7}  "
             f"{r['verdict']:<7} {ops}{('   ' + tag) if tag else ''}")

    hits = [r for r in results if r["pages"] > 0 and r["ch"] not in (0x00, 0x03)]
    controls_ok = [r for r in results if r["pages"] > 0 and r["ch"] in (0x00, 0x03)]
    note("")
    if not controls_ok:
        note(">>> INCONCLUSIVE: neither control channel (0x00/0x03) streamed data pages — the ring "
             "had no un-synced history to drain (already handed off to the phone), so no selector "
             "could differentiate. Re-run while the ring is HOLDING data: keep it OFF the phone for "
             "a while (ideally after a walk / overnight) so its backlog isn't drained, then probe.")
    if hits:
        hit_list = ", ".join(f"0x{r['ch']:02x}" for r in hits)
        note(f">>> {len(hits)} NON-CONTROL channel(s) returned data: {hit_list}. "
             "Decode these — activity/steps (#9/#93/#95), stress (#94), or temp/RR (#87).")
    elif controls_ok:
        note(">>> Only 0x00/0x03 returned data. Strong signal that activity/steps/stress/temp "
             "are NOT streamed by the ring (cloud-computed) — closes the #94 question and means "
             "#93/#95 must be derived from the 0x4c records we already have, not a new channel.")

    if out_path is None:
        # captures/ lives next to the package (desktop/captures/), regardless of CWD.
        cap_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "captures")
        out_path = os.path.join(cap_dir, f"probe_{int(time.time())}.log")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as fh:
        fh.write("\n".join(log) + "\n")
    print(f"\nRaw frame log written to {out_path}  "
          f"(decode records offline with desktop/decode_activity.py)")
