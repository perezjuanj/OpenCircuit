"""Command-line entry point for the RingConn RE workbench.

    python -m opencircuit scan
    python -m opencircuit enumerate --addr AA:BB:CC:DD:EE:FF
    python -m opencircuit listen --addr AA:BB:CC:DD:EE:FF [--keepalive]
    python -m opencircuit replay --addr ... --hex 950095 --handle 0x0802
    python -m opencircuit probe-channels [--addr ...] [--channels 0x02,0x04]
    python -m opencircuit decode-log captures/btsnoop_hci.log
    python -m opencircuit guess-checksum --hex "0e00....crc"
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
    p = argparse.ArgumentParser(prog="opencircuit", description=__doc__,
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
                    help="periodically poll (95 00 00) for live samples")
    sl.add_argument("--start-hr", action="store_true",
                    help="send the live-HR start sequence (06 01 00, 07 00 00) on connect")
    sl.add_argument("--send", action="append", metavar="HEX", default=None,
                    help="write a raw command frame on connect (verbatim, repeatable)")
    sl.add_argument("--duration", type=float, default=None)

    sr = sub.add_parser("replay", help="write a command and log the response")
    sr.add_argument("--addr", required=True)
    sr.add_argument("--hex", required=True, help="payload bytes, e.g. 950095")
    sr.add_argument("--char", default=ble.WRITE_CHAR)
    sr.add_argument("--response", action="store_true", help="write-with-response")
    sr.add_argument("--wait", type=float, default=5.0)

    spc = sub.add_parser("probe-channels",
                         help="sweep the 0x02 byte[6] history-channel selector to "
                              "discover undecoded streams (activity/stress/temp)")
    spc.add_argument("--addr", default=None,
                     help="ring address/UUID; omit to scan by name")
    spc.add_argument("--channels", default=None,
                     help="comma-separated hex channels, e.g. 0x02,0x04; "
                          "default sweeps 0x00-0x1f (0x00/0x03 are controls)")
    spc.add_argument("--timeout", type=float, default=8.0,
                     help="max seconds to drain per channel (default 8)")
    spc.add_argument("--max-frames", type=int, default=120,
                     help="stop a channel after this many record/page frames")
    spc.add_argument("--no-ack", action="store_true",
                     help="don't auto-ACK pages (a channel with data may under-report)")
    spc.add_argument("--no-warmup", action="store_true",
                     help="skip the pre-sweep residual drain, so the FIRST channel receives the "
                          "full pending queue — use for a selector test on a loaded ring")
    spc.add_argument("--out", default=None,
                     help="raw log path (default desktop/captures/probe_<ts>.log)")

    sd = sub.add_parser("decode-log", help="parse an Android btsnoop HCI capture")
    sd.add_argument("path")
    sd.add_argument("--addr", default=None)
    sd.add_argument("--handles", default=None,
                    help="comma-separated hex handles to filter, e.g. 0x0804,0x0802")

    sg = sub.add_parser("guess-checksum", help="brute-force a frame's trailer CRC")
    sg.add_argument("--hex", required=True)
    sg.add_argument("--trailer", type=int, default=None, help="trailer length in bytes")

    args = p.parse_args(argv)

    if args.cmd in ("scan", "enumerate", "listen", "replay", "probe-channels"):
        from . import session  # lazy: only these need bleak
        if args.cmd == "scan":
            asyncio.run(session.scan(args.timeout))
        elif args.cmd == "enumerate":
            asyncio.run(session.enumerate_gatt(args.addr))
        elif args.cmd == "listen":
            asyncio.run(session.listen(args.addr, args.char, args.keepalive,
                                       args.duration, args.start_hr, args.send))
        elif args.cmd == "replay":
            asyncio.run(session.replay(args.addr, _parse_hex(args.hex), args.char,
                                       args.response, args.wait))
        elif args.cmd == "probe-channels":
            channels = None
            if args.channels:
                channels = [_parse_handle(c) for c in args.channels.split(",")]
            asyncio.run(session.probe_channels(
                args.addr, channels, args.timeout,
                max_frames=args.max_frames, ack=not args.no_ack,
                warmup=not args.no_warmup, out_path=args.out))
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
