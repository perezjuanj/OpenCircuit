"""Command-line entry point for the RingConn RE workbench.

    python -m openringconn scan
    python -m openringconn enumerate --addr AA:BB:CC:DD:EE:FF
    python -m openringconn listen --addr AA:BB:CC:DD:EE:FF [--keepalive]
    python -m openringconn replay --addr ... --hex 950095 --handle 0x0802
    python -m openringconn decode-log captures/btsnoop_hci.log
    python -m openringconn guess-checksum --hex "0e00....crc"
"""

from __future__ import annotations

import argparse
import asyncio
import sys

from . import ble, framing, sniff  # session is imported lazily (needs bleak)


def _parse_hex(s: str) -> bytes:
    return bytes.fromhex(s.replace(" ", "").replace("0x", ""))


def _parse_handle(s: str) -> int:
    return int(s, 16) if s.lower().startswith("0x") else int(s)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="openringconn", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("scan", help="discover devices and enumerate the ring")
    sp.add_argument("--timeout", type=float, default=10.0)

    se = sub.add_parser("enumerate", help="print the GATT tree of a known address")
    se.add_argument("--addr", required=True)

    sl = sub.add_parser("listen", help="log notifications from the ring")
    sl.add_argument("--addr", required=True)
    sl.add_argument("--char", default=ble.NOTIFY_CHAR)
    sl.add_argument("--keepalive", action="store_true",
                    help="periodically write the live-HR keepalive")
    sl.add_argument("--duration", type=float, default=None)

    sr = sub.add_parser("replay", help="write a command and log the response")
    sr.add_argument("--addr", required=True)
    sr.add_argument("--hex", required=True, help="payload bytes, e.g. 950095")
    sr.add_argument("--char", default=ble.WRITE_CHAR)
    sr.add_argument("--response", action="store_true", help="write-with-response")
    sr.add_argument("--wait", type=float, default=5.0)

    sd = sub.add_parser("decode-log", help="parse an Android btsnoop HCI capture")
    sd.add_argument("path")
    sd.add_argument("--addr", default=None)
    sd.add_argument("--handles", default=None,
                    help="comma-separated hex handles to filter, e.g. 0x0804,0x0802")

    sg = sub.add_parser("guess-checksum", help="brute-force a frame's trailer CRC")
    sg.add_argument("--hex", required=True)
    sg.add_argument("--trailer", type=int, default=None, help="trailer length in bytes")

    args = p.parse_args(argv)

    if args.cmd in ("scan", "enumerate", "listen", "replay"):
        from . import session  # lazy: only these need bleak
        if args.cmd == "scan":
            asyncio.run(session.scan(args.timeout))
        elif args.cmd == "enumerate":
            asyncio.run(session.enumerate_gatt(args.addr))
        elif args.cmd == "listen":
            asyncio.run(session.listen(args.addr, args.char, args.keepalive, args.duration))
        elif args.cmd == "replay":
            asyncio.run(session.replay(args.addr, _parse_hex(args.hex), args.char,
                                       args.response, args.wait))
    elif args.cmd == "decode-log":
        handles = None
        if args.handles:
            handles = {_parse_handle(h) for h in args.handles.split(",")}
        sniff.decode_log(args.path, args.addr, handles)
    elif args.cmd == "guess-checksum":
        framing.guess_checksum(_parse_hex(args.hex), args.trailer)
    else:  # pragma: no cover
        p.print_help()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
