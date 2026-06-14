"""Parse Android `btsnoop_hci.log` captures and extract ATT traffic.

Decodes the btsnoop container -> HCI H4 -> ACL -> L2CAP -> ATT, reassembling
fragmented ACL packets, and prints the Write/Notification/Indication PDUs that
carry RingConn payloads. Cross-reference the timestamps with the action you
performed in the official app (see docs/REVERSE_ENGINEERING.md).

btsnoop format: https://datatracker.ietf.org/doc/html/draft-gordon-bluetooth-snoop
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from datetime import datetime, timezone

# Microseconds between 0000-01-01 and 1970-01-01 (btsnoop epoch -> Unix epoch).
_BTSNOOP_EPOCH_DELTA_US = 0x00DCDDB30F2F8000

# H4 packet indicators
_H4_ACL = 0x02

# L2CAP channel id for the Attribute Protocol
_CID_ATT = 0x0004

# ATT opcodes we care about
_ATT_OPCODES = {
    0x0A: "ReadRsp",
    0x0B: "ReadBlobRsp",
    0x12: "WriteReq",
    0x13: "WriteRsp",
    0x52: "WriteCmd",
    0x1B: "Notification",
    0x1D: "Indication",
    0x1E: "Confirmation",
    0xD2: "SignedWriteCmd",
}


@dataclass
class AttEvent:
    ts_unix: float
    sent: bool          # True = host -> controller (phone -> ring)
    conn_handle: int
    opcode: int
    att_handle: int | None
    value: bytes

    @property
    def op_name(self) -> str:
        return _ATT_OPCODES.get(self.opcode, f"0x{self.opcode:02x}")

    @property
    def direction(self) -> str:
        return "TX" if self.sent else "RX"


def _read_records(blob: bytes):
    """Yield (ts_unix, flags, payload) for each btsnoop record."""
    if blob[:8] != b"btsnoop\x00":
        raise ValueError("not a btsnoop file (bad magic)")
    # 8 magic + 4 version + 4 datalink
    version, datalink = struct.unpack_from(">II", blob, 8)
    off = 16
    n = len(blob)
    while off + 24 <= n:
        orig_len, incl_len, flags, drops, ts = struct.unpack_from(">IIIIq", blob, off)
        off += 24
        payload = blob[off:off + incl_len]
        off += incl_len
        ts_unix = (ts - _BTSNOOP_EPOCH_DELTA_US) / 1_000_000
        yield ts_unix, flags, payload


def _iter_att(blob: bytes):
    """Reassemble ACL fragments and yield AttEvent objects."""
    # Per connection-handle reassembly buffer: handle -> (sent, bytearray, expected)
    buffers: dict[int, list] = {}

    for ts_unix, flags, payload in _read_records(blob):
        if not payload:
            continue
        sent = (flags & 0x01) == 0  # btsnoop flag bit0: 0 = sent (host->controller)
        h4_type = payload[0]
        if h4_type != _H4_ACL or len(payload) < 5:
            continue
        acl = payload[1:]
        handle_flags, acl_len = struct.unpack_from("<HH", acl, 0)
        conn_handle = handle_flags & 0x0FFF
        pb = (handle_flags >> 12) & 0x3  # packet boundary flag
        data = acl[4:4 + acl_len]

        if pb in (0x0, 0x2):  # first fragment of a host->ctrl / ctrl->host PDU
            if len(data) < 4:
                continue
            l2_len, cid = struct.unpack_from("<HH", data, 0)
            buf = bytearray(data)
            buffers[conn_handle] = [sent, buf, l2_len + 4, ts_unix]
        elif pb == 0x1:  # continuation
            entry = buffers.get(conn_handle)
            if entry is None:
                continue
            entry[1].extend(data)
        else:
            continue

        entry = buffers.get(conn_handle)
        if entry is None:
            continue
        _sent, buf, expected, first_ts = entry
        if len(buf) < expected:
            continue  # not complete yet
        buffers.pop(conn_handle, None)

        l2_len, cid = struct.unpack_from("<HH", buf, 0)
        if cid != _CID_ATT:
            continue
        att = bytes(buf[4:4 + l2_len])
        if not att:
            continue
        opcode = att[0]
        att_handle = None
        value = att[1:]
        if opcode in (0x12, 0x52, 0x1B, 0x1D, 0xD2) and len(att) >= 3:
            att_handle = struct.unpack_from("<H", att, 1)[0]
            value = att[3:]
        yield AttEvent(first_ts, _sent, conn_handle, opcode, att_handle, value)


def decode_log(path: str, addr: str | None = None, only_handles: set[int] | None = None) -> None:
    """Print ATT writes/notifications from a btsnoop capture.

    `addr` is accepted for symmetry/filtering by connection but btsnoop records
    don't carry the BD_ADDR per packet; connection-handle grouping is shown so you
    can identify the ring's connection if multiple devices are present.
    """
    with open(path, "rb") as f:
        blob = f.read()

    count = 0
    print(f"{'time':<12} {'dir':<3} {'conn':<6} {'op':<13} {'h':<6} payload")
    print("-" * 72)
    for ev in _iter_att(blob):
        if only_handles and ev.att_handle not in only_handles:
            continue
        if ev.opcode not in _ATT_OPCODES:
            continue
        t = datetime.fromtimestamp(ev.ts_unix, tz=timezone.utc).strftime("%H:%M:%S.%f")[:-3]
        h = f"0x{ev.att_handle:04x}" if ev.att_handle is not None else "—"
        print(f"{t:<12} {ev.direction:<3} 0x{ev.conn_handle:03x}  "
              f"{ev.op_name:<13} {h:<6} {ev.value.hex(' ')}")
        count += 1
    print("-" * 72)
    print(f"{count} ATT events. Correlate timestamps with your app actions, then "
          f"record findings in docs/PROTOCOL.md.")
