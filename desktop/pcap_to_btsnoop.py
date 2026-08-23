#!/usr/bin/env python3
"""Convert an iPhone/Mac Bluetooth capture into the btsnoop file `decode-log` wants.

WHY THIS EXISTS
    `opencircuit/sniff.py` hard-requires the literal `btsnoop\\0` magic (sniff.py:60).
    Android's `btsnoop_hci.log` already is that. An iPhone capture is NOT: both
    `idevicebtlogger` and Apple's PacketLogger emit either a `.pcap` or Apple's own
    `.pklg`. Without this converter an iPhone capture has no decode path at all.

USAGE
    python3 pcap_to_btsnoop.py <input.pcap|input.pcapng|input.pklg> [output.log]

    Default output is the input path with `_btsnoop.log` appended. Then:

    python3 -m opencircuit decode-log captures/<output.log>

STDLIB ONLY — runs on stock macOS `/usr/bin/python3` (3.9) with no venv and no pip,
same as the rest of the offline decode chain.

FORMAT SUPPORT
    🟢 pcap, DLT 201 (LINKTYPE_BLUETOOTH_H4_WITH_PHDR) — what `idevicebtlogger -f pcap`
       writes, and the only path this runbook actually asks for. Round-trip verified
       byte-identical against a real 29,569-packet capture. Both byte orders, both µs
       and ns timestamp variants.
    🟡 pcap, DLT 187 (LINKTYPE_BLUETOOTH_HCI_H4) — bare H4, carrying NO direction. See
       DIRECTION below: for ACL we infer it from the ACL packet-boundary flag, which is
       measured-perfect on this project's captures but is not guaranteed by the spec.
    🟢 pcapng with those same link types — what Wireshark writes if the helper re-saves.
    🟡 pklg (Apple PacketLogger native) — layout is reconstructed from the public format
       description, NOT validated against a real Apple file, because no `.pklg` sample
       exists in this repo. It self-checks and refuses rather than emitting garbage.
       Prefer `idevicebtlogger -f pcap`, which avoids this path entirely.

DIRECTION MATTERS
    `sniff.py:83` reads btsnoop flag bit0 to decide TX (phone->ring) vs RX. Getting it
    backwards silently relabels every command as a response — for a capture whose whole
    purpose is isolating one phone->ring write, that is the worst available failure.

    DLT 201 carries the direction explicitly, so it is exact. DLT 187 does not, and
    naively defaulting ACL to "sent" mislabels EVERY notification: measured on a real
    capture, that turns a true 681-sent/8956-received ACL split into 9637/0, and the
    decoder then reports 1860 TX / 0 RX instead of 651/1209. So for ACL we read the
    packet-boundary flag instead (pb=0b00 -> sent, 0b10 -> received), which holds on
    173,055 ACL packets across all 16 checked-in captures with zero violations 🟡. It is
    spec-legal for a host to send 0b10, hence 🟡 not 🟢 — and the one-sided guard below
    is scoped to ACL so a mislabelled file is caught rather than passed.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# ── btsnoop container ────────────────────────────────────────────────────────
_BTSNOOP_MAGIC = b"btsnoop\x00"
_BTSNOOP_VERSION = 1
_BTSNOOP_DATALINK_H4 = 1002  # HCI UART (H4) — what Android writes, what sniff.py parses
# Microseconds between 0000-01-01 and 1970-01-01. Must match sniff.py:18 exactly,
# or every decoded timestamp lands centuries away and the log looks empty.
_BTSNOOP_EPOCH_DELTA_US = 0x00DCDDB30F2F8000

# btsnoop record flags
_FLAG_RECEIVED = 0x01  # bit0: 0 = sent (host->controller), 1 = received
_FLAG_CMD_EVT = 0x02   # bit1: 1 = HCI command or event, 0 = ACL/SCO data

# H4 packet indicators
_H4_CMD, _H4_ACL, _H4_SCO, _H4_EVT = 0x01, 0x02, 0x03, 0x04

# pcap link types
_DLT_H4_WITH_PHDR = 201
_DLT_H4 = 187


class ConvertError(Exception):
    """A refusal to guess. Raised instead of writing a file we can't stand behind."""


def _flags_for(h4_type: int, received: bool) -> int:
    flags = _FLAG_RECEIVED if received else 0
    if h4_type in (_H4_CMD, _H4_EVT):
        flags |= _FLAG_CMD_EVT
    return flags


def _btsnoop_record(h4: bytes, ts_unix_us: int, received: bool) -> bytes:
    """One btsnoop record: 24-byte BE header + the raw H4 packet."""
    flags = _flags_for(h4[0] if h4 else 0, received)
    ts = ts_unix_us + _BTSNOOP_EPOCH_DELTA_US
    return struct.pack(">IIIIq", len(h4), len(h4), flags, 0, ts) + h4


# ── pcap ─────────────────────────────────────────────────────────────────────
def _parse_pcap(blob: bytes):
    """Yield (h4_bytes, ts_unix_us, received) from a classic pcap file."""
    if len(blob) < 24:
        raise ConvertError("file is too short to be a pcap")
    magic = blob[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian, nanos = "<", False
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian, nanos = ">", False
    elif magic == b"\x4d\x3c\xb2\xa1":
        endian, nanos = "<", True
    elif magic == b"\xa1\xb2\x3c\x4d":
        endian, nanos = ">", True
    else:
        raise ConvertError(f"not a pcap file (magic {magic.hex()})")

    _vmaj, _vmin, _tz, _sig, _snap, dlt = struct.unpack_from(endian + "HHiIII", blob, 4)
    if dlt not in (_DLT_H4_WITH_PHDR, _DLT_H4):
        raise ConvertError(
            f"pcap link type {dlt} is not Bluetooth HCI H4 (expected {_DLT_H4_WITH_PHDR} "
            f"or {_DLT_H4}). This capture is not Bluetooth — check you captured the right "
            f"interface."
        )

    off, n = 24, len(blob)
    while off + 16 <= n:
        ts_a, ts_b, incl, _orig = struct.unpack_from(endian + "IIII", blob, off)
        off += 16
        data = blob[off:off + incl]
        off += incl
        if len(data) < incl:
            # A corrupt length here silently swallows the rest of the file: measured,
            # one bad record dropped 83% of a 29,569-packet capture while still
            # reporting success. Refuse instead — a short capture that looks complete
            # is worse than no capture.
            raise ConvertError(
                f"pcap record at byte {off - 16 - incl} claims {incl} bytes but only "
                f"{len(data)} remain. The file is truncated or corrupt; {n - off + incl} "
                f"bytes were not read. Re-capture rather than trust a partial decode."
            )
        ts_us = ts_a * 1_000_000 + (ts_b // 1000 if nanos else ts_b)
        rec = _h4_from_link(data, dlt)
        if rec is not None:
            yield rec[0], ts_us, rec[1]
    if off != n:
        raise ConvertError(
            f"pcap has {n - off} trailing byte(s) after the last complete record at "
            f"byte {off} — the file is truncated or corrupt. Re-capture."
        )


def _h4_from_link(data: bytes, dlt: int):
    """Return (h4_bytes, received) for one link-layer frame, or None to skip it."""
    if dlt == _DLT_H4_WITH_PHDR:
        # 4-byte BIG-endian direction pseudo-header: 0 = sent, 1 = received.
        if len(data) < 5:
            return None
        direction = struct.unpack_from(">I", data, 0)[0]
        return data[4:], bool(direction & 0x01)

    # Bare H4 carries no direction at all, so it has to be inferred per packet type.
    if not data:
        return None
    t = data[0]
    if t == _H4_CMD:
        return data, False          # commands only ever go host -> controller
    if t == _H4_EVT:
        return data, True           # events only ever come back
    if t == _H4_ACL and len(data) >= 3:
        # ACL is the payload we actually care about, and defaulting it to "sent" would
        # mislabel every notification (measured: 9637/0 instead of 681/8956). The ACL
        # handle field's packet-boundary bits discriminate it: 0b00 = first fragment of
        # a host->controller PDU, 0b10 = first fragment of a controller->host one.
        pb = (struct.unpack_from("<H", data, 1)[0] >> 12) & 0x3
        if pb == 0b10:
            return data, True
        if pb == 0b00:
            return data, False
        return data, None           # 0b01 continuation — genuinely unknowable here
    return data, False


# ── pcapng ───────────────────────────────────────────────────────────────────
def _parse_pcapng(blob: bytes):
    """Yield (h4_bytes, ts_unix_us, received) from a pcapng file."""
    if blob[:4] != b"\x0a\x0d\x0d\x0a":
        raise ConvertError("not a pcapng file")
    if len(blob) < 28:
        raise ConvertError(
            f"pcapng file is only {len(blob)} bytes — too short to hold even a section "
            f"header. The capture did not record anything; re-capture."
        )
    # Byte order comes from the Section Header Block's magic.
    bom = struct.unpack_from(">I", blob, 8)[0]
    endian = ">" if bom == 0x1A2B3C4D else "<"

    interfaces: list[tuple[int, int]] = []  # (link_type, ts_resolution_divisor)
    saw_any = False
    off, n = 0, len(blob)
    while off + 12 <= n:
        try:
            btype, blen = struct.unpack_from(endian + "II", blob, off)
            if blen < 12 or off + blen > n:
                raise ConvertError(
                    f"pcapng block at byte {off} declares length {blen}, which does not "
                    f"fit the file. Truncated or corrupt — re-capture."
                )
            body = blob[off + 8:off + blen - 4]

            if btype == 0x0A0D0D0A:  # a new Section Header — interface ids restart
                interfaces = []
                bom = struct.unpack_from(">I", blob, off + 8)[0]
                endian = ">" if bom == 0x1A2B3C4D else "<"
            elif btype == 0x00000001:  # Interface Description Block
                if len(body) < 8:
                    raise ConvertError(f"pcapng IDB at byte {off} is too short")
                link_type = struct.unpack_from(endian + "H", body, 0)[0]
                interfaces.append((link_type, _pcapng_tsres(body[8:], endian)))
                saw_any = True
            elif btype == 0x00000006:  # Enhanced Packet Block
                if len(body) < 20:
                    raise ConvertError(f"pcapng EPB at byte {off} is too short")
                iface, ts_hi, ts_lo, incl, _orig = struct.unpack_from(endian + "IIIII", body, 0)
                if incl > len(body) - 20:
                    # A caplen larger than its own block yields a truncated fragment
                    # that sniff.py can complete with an unrelated later one — which
                    # fabricates a WriteReq that never happened. Refuse.
                    raise ConvertError(
                        f"pcapng packet at byte {off} claims {incl} captured bytes but "
                        f"its block holds only {len(body) - 20}. Corrupt — re-capture."
                    )
                if iface < len(interfaces):
                    link_type, divisor = interfaces[iface]
                    if link_type in (_DLT_H4_WITH_PHDR, _DLT_H4):
                        ts = (ts_hi << 32) | ts_lo
                        rec = _h4_from_link(body[20:20 + incl], link_type)
                        if rec is not None:
                            yield rec[0], (ts * 1_000_000) // divisor, rec[1]
        except struct.error as exc:
            raise ConvertError(f"pcapng block at byte {off} is malformed ({exc})") from exc
        off += blen

    if not saw_any:
        raise ConvertError("pcapng contained no interface description block")


def _pcapng_tsres(opts: bytes, endian: str) -> int:
    """Read if_tsresol (option code 9). Default 10^6 (microseconds)."""
    off = 0
    while off + 4 <= len(opts):
        code, olen = struct.unpack_from(endian + "HH", opts, off)
        off += 4
        if code == 0:  # opt_endofopt
            break
        if code == 9 and olen >= 1 and off < len(opts):
            raw = opts[off]
            return (1 << (raw & 0x7F)) if raw & 0x80 else (10 ** raw)
        off += (olen + 3) & ~3
    return 10 ** 6


# ── pklg (Apple PacketLogger) 🟡 unvalidated ─────────────────────────────────
# Record: uint32 BE length, uint32 BE ts_secs, uint32 BE ts_usecs, uint8 type, data.
# `length` counts the 8 timestamp bytes plus the type byte and data, so the payload
# that follows the 12-byte header is (length - 8) bytes.
_PKLG_HCI_CMD, _PKLG_HCI_EVT = 0x00, 0x01
_PKLG_ACL_SENT, _PKLG_ACL_RECV = 0x02, 0x03

_PKLG_TO_H4 = {
    _PKLG_HCI_CMD: (_H4_CMD, False),
    _PKLG_HCI_EVT: (_H4_EVT, True),
    _PKLG_ACL_SENT: (_H4_ACL, False),
    _PKLG_ACL_RECV: (_H4_ACL, True),
}


def _parse_pklg(blob: bytes):
    """Yield (h4_bytes, ts_unix_us, received) from an Apple PacketLogger file.

    🟡 Reconstructed from the published format, never checked against a real Apple
    capture. Validates aggressively and raises rather than emitting plausible garbage.
    """
    off, n, emitted, skipped = 0, len(blob), 0, 0
    while off + 13 <= n:
        length, ts_s, ts_us = struct.unpack_from(">III", blob, off)
        payload_len = length - 8
        # A sane record: positive payload, fits in the file, timestamp this century.
        if payload_len < 1 or off + 12 + payload_len > n or not (946_684_800 < ts_s < 2_524_608_000):
            raise ConvertError(
                f"pklg record at byte {off} failed the sanity check "
                f"(length={length}, ts={ts_s}). This parser is unvalidated 🟡 — please "
                f"send us the .pklg and re-capture with `idevicebtlogger -f pcap`, which "
                f"uses the fully-supported pcap path instead."
            )
        pkt_type = blob[off + 12]
        data = blob[off + 13:off + 12 + payload_len]
        off += 12 + payload_len

        mapped = _PKLG_TO_H4.get(pkt_type)
        if mapped is None:
            skipped += 1
            continue
        h4_type, received = mapped
        emitted += 1
        yield bytes([h4_type]) + data, ts_s * 1_000_000 + ts_us, received

    if emitted == 0:
        raise ConvertError(
            f"no Bluetooth packets recognised in this .pklg ({skipped} records skipped). "
            f"Re-capture with `idevicebtlogger -f pcap`."
        )


# ── driver ───────────────────────────────────────────────────────────────────
def _sniff(blob: bytes):
    if blob[:8] == _BTSNOOP_MAGIC:
        raise ConvertError("this file is ALREADY btsnoop — feed it straight to decode-log")
    if blob[:4] == b"\x0a\x0d\x0d\x0a":
        return _parse_pcapng, "pcapng"
    if blob[:4] in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4", b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d"):
        return _parse_pcap, "pcap"
    return _parse_pklg, "pklg"


class Stats:
    __slots__ = ("total", "tx", "rx", "acl_tx", "acl_rx")

    def __init__(self) -> None:
        self.total = self.tx = self.rx = self.acl_tx = self.acl_rx = 0


def convert(src: Path, dst: Path) -> Stats:
    """Write `dst` as btsnoop, atomically. Returns a Stats.

    Writes to a sibling temp file and renames only on success. An earlier version
    opened `dst` directly, which truncated it before the parser had read a single
    record — pointing that at an existing capture destroyed it (measured: a real
    4.8 MB log replaced by a 113-byte stub) and left partial output that `decode-log`
    would happily read as if it were complete.
    """
    blob = src.read_bytes()
    if not blob:
        raise ConvertError(f"{src} is empty")
    parser, kind = _sniff(blob)
    print(f"Input looks like: {kind}")

    st = Stats()
    tmp = dst.with_name(dst.name + ".partial")
    try:
        with tmp.open("wb") as out:
            out.write(_BTSNOOP_MAGIC
                      + struct.pack(">II", _BTSNOOP_VERSION, _BTSNOOP_DATALINK_H4))
            # A continuation fragment carries no direction of its own; it belongs to
            # whichever PDU is mid-reassembly on that connection.
            last_dir: dict[int, bool] = {}
            for h4, ts_us, received in parser(blob):
                if not h4:
                    continue
                is_acl = h4[0] == _H4_ACL
                if received is None:
                    handle = (struct.unpack_from("<H", h4, 1)[0] & 0x0FFF) if len(h4) >= 3 else 0
                    received = last_dir.get(handle, False)
                elif is_acl and len(h4) >= 3:
                    last_dir[struct.unpack_from("<H", h4, 1)[0] & 0x0FFF] = received
                out.write(_btsnoop_record(h4, ts_us, received))
                st.total += 1
                st.rx += received
                st.tx += not received
                if is_acl:
                    st.acl_rx += received
                    st.acl_tx += not received
        tmp.replace(dst)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return st


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Convert an iPhone/Mac Bluetooth capture to btsnoop for `decode-log`.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("input", type=Path, help="the .pcap / .pcapng / .pklg you captured")
    p.add_argument("output", type=Path, nargs="?", default=None,
                   help="output path (default: <input>_btsnoop.log)")
    args = p.parse_args(argv)

    if not args.input.exists():
        print(f"error: {args.input} does not exist", file=sys.stderr)
        return 1
    dst = args.output or args.input.with_name(args.input.stem + "_btsnoop.log")

    try:
        st = convert(args.input, dst)
    except ConvertError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if st.total == 0:
        print(f"error: no Bluetooth packets found in {args.input}. Nothing was written.",
              file=sys.stderr)
        dst.unlink(missing_ok=True)
        return 1

    print(f"Wrote {dst}  ({st.total} packets: {st.tx} sent, {st.rx} received)")
    print(f"  of which ACL (the data we decode): {st.acl_tx} sent, {st.acl_rx} received")

    # A one-sided split means the direction bit is wrong, which silently relabels every
    # command as a response downstream. This MUST be scoped to ACL: HCI commands and
    # events are correctly inferred even on DLT 187, so they supply a plausible-looking
    # mix that hid a 9637/0 ACL split behind an overall "17141 sent, 12428 received".
    if st.acl_tx + st.acl_rx > 0 and (st.acl_tx == 0 or st.acl_rx == 0):
        print("\nWARNING: every ACL packet went one direction. A real session is always a\n"
              "         mix, so the direction flag is wrong and anything decoded from this\n"
              "         file would have commands and responses swapped. Tell us — do not\n"
              "         trust a decode of this file.", file=sys.stderr)
        return 1
    print(f"\nNext: python3 -m opencircuit decode-log {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
