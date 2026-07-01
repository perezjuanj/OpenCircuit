"""Decode 0x4D (batch) and 0x4E (live snapshot) frames — discovered 2026-06-26.

Both opcodes carry 10-second-cadence epochs: HR + motion + a third field (likely IBI
or steps, pending ground-truth validation). They are the `BleHistoryMeasureInfoRspMixin`
or `BleRealtimeSportRspMixin` response family.

Format:
  0x4E  (13 bytes, single live snapshot)
    [4E] [cursor:4 BE] [hr:1] [motion_lo:1] [motion_hi:1] [field3_lo:1] [field3_hi:1] [conf:1] [pad:1] [xor:1]

  0x4D  (variable, N × 11-byte records)
    [4D] [00] [count_or_seq:1] [records: N×11] [xor:1]
    Each 11-byte record:  [cursor:4 BE] [hr:1] [motion_lo:1] [motion_hi:1] [field3_lo:1] [field3_hi:1] [conf:1] [pad:1]

Confirmed:
  cursor       — ring epoch (seconds since 2019-12-31 12:00:00 UTC), +10s between records
  hr           — heart rate in bpm (validated against 0x87 status frame same timestamp) 🟢
  motion[1:3]  — step count or motion metric (0 at rest, 7 when moving) 🟡
  field3[3:5]  — unknown; large values (10000-12000 range), does NOT match IBI 🔴
  conf         — confidence or motion intensity (0-9 in captures) 🟡

To run on a decoded-log txt (output of `decode-log`):
  python decode_4d_4e.py captures/decoded.txt

Or import and call decode_frame(bytes) directly.
"""
from __future__ import annotations
import sys, struct
from datetime import datetime, timezone

RING_EPOCH = 1_577_793_600


def _ts(cursor_be4: bytes) -> str:
    c = struct.unpack(">I", cursor_be4)[0]
    dt = datetime.fromtimestamp(c + RING_EPOCH, tz=timezone.utc)
    return dt.strftime("%Y-%m-%d %H:%M:%S UTC")


def _xor_ok(frame: bytes) -> bool:
    acc = 0
    for b in frame[:-1]:
        acc ^= b
    return acc == frame[-1]


def decode_record(rec7: bytes) -> dict:
    """Decode the 7-byte payload (after cursor) common to both 0x4D and 0x4E."""
    hr = rec7[0]
    motion = struct.unpack("<H", rec7[1:3])[0]   # 🟡 step count or motion count
    field3 = struct.unpack("<H", rec7[3:5])[0]   # 🔴 unknown (not IBI — doesn't match HR)
    conf   = rec7[5]                             # 🟡 confidence / intensity
    pad    = rec7[6]
    return {"hr": hr, "motion": motion, "field3": field3, "conf": conf, "pad": pad}


def decode_4e(frame: bytes) -> dict | None:
    """Decode a 0x4E single-record frame (13 bytes)."""
    if len(frame) < 13 or frame[0] != 0x4E:
        return None
    if not _xor_ok(frame):
        return None
    ts = _ts(frame[1:5])
    rec = decode_record(frame[5:12])
    rec["timestamp"] = ts
    rec["opcode"] = "0x4E"
    return rec


def decode_4d(frame: bytes) -> list[dict] | None:
    """Decode a 0x4D batch frame. Returns list of record dicts."""
    if len(frame) < 4 or frame[0] != 0x4D:
        return None
    if not _xor_ok(frame):
        return None
    payload = frame[3:-1]          # skip [4D][00][count] header and XOR trailer
    records = []
    for off in range(0, len(payload) - 10, 11):
        rec_bytes = payload[off:off + 11]
        if len(rec_bytes) < 11:
            break
        ts = _ts(rec_bytes[0:4])
        rec = decode_record(rec_bytes[4:11])
        rec["timestamp"] = ts
        rec["opcode"] = "0x4D"
        records.append(rec)
    return records


def print_record(r: dict) -> None:
    print(f"  {r['timestamp']}  HR={r['hr']:>3} bpm  "
          f"motion={r['motion']:>5}  field3={r['field3']:>6} (🔴)  "
          f"conf={r['conf']:>2}  {'['+r['opcode']+']'}")


def decode_from_log(path: str) -> None:
    """Parse a `decode-log` txt and print 0x4D/0x4E records."""
    with open(path) as f:
        lines = f.readlines()
    count = 0
    for line in lines:
        if "0x0804 4d " in line or "0x0804 4e " in line:
            hexpart = line.split("0x0804", 1)[1].strip()
            toks = [t for t in hexpart.split() if len(t) == 2]
            try:
                frame = bytes(int(t, 16) for t in toks)
            except ValueError:
                continue
            if frame[0] == 0x4E:
                r = decode_4e(frame)
                if r:
                    print_record(r)
                    count += 1
            elif frame[0] == 0x4D:
                rs = decode_4d(frame)
                if rs:
                    for r in rs:
                        print_record(r)
                    count += len(rs)
    print(f"\n{count} records decoded.")


# ── Inline test against known frames ──────────────────────────────────────────
# Verified frames from 2026-06-26 probe run (XOR confirmed OK in all cases).
# 0x4E "4e 0c 33 49 8e 52 07 00 cc 27 03 00 0b"
#       opcode  [cursor:4BE]  [hr] [mot:2LE] [f3:2LE] [conf][pad][xor]
#       4e      0c33498e      52   0700      cc27      03    00   0b
_KNOWN_4E = [
    bytes([0x4e, 0x0c, 0x33, 0x49, 0x8e,  0x52, 0x07, 0x00, 0xcc, 0x27, 0x03, 0x00, 0x0b]),
    bytes([0x4e, 0x0c, 0x33, 0x4a, 0x42,  0x51, 0x00, 0x01, 0x2c, 0x2b, 0x09, 0x00, 0x27]),
]
# 0x4D batch — 3 clean records extracted from livehr.py capture
# header: 4d 00 N  then N×11-byte records  then XOR
def _4d_frame(*records: list[int]) -> bytes:
    body = b"".join(bytes(r) for r in records)
    hdr = bytes([0x4D, 0x00, len(records)])
    payload = hdr + body
    xor = 0
    for b in payload: xor ^= b
    return payload + bytes([xor])

_KNOWN_4D = _4d_frame(
    [0x0c, 0x33, 0x49, 0x8e,  0x52, 0x07, 0x00, 0xcc, 0x27, 0x03, 0x00],
    [0x0c, 0x33, 0x49, 0x98,  0x56, 0x00, 0x00, 0x59, 0x2c, 0x04, 0x00],
    [0x0c, 0x33, 0x49, 0xa2,  0x56, 0x00, 0x00, 0x20, 0x2b, 0x08, 0x00],
)


if __name__ == "__main__":
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        decode_from_log(sys.argv[1])
    else:
        print("=== 0x4E live snapshots (from 2026-06-26 probe) ===")
        for raw in _KNOWN_4E:
            r = decode_4e(raw)
            if r:
                print_record(r)
            else:
                print(f"  [decode failed] {raw.hex(' ')}")

        print("\n=== 0x4D batch (from 2026-06-26 livehr.py) ===")
        rs = decode_4d(_KNOWN_4D)
        if rs:
            for r in rs:
                print_record(r)
        else:
            print("  [decode failed]")

        print("\nfield3 note: values ~10000-12000, unit unknown. NOT IBI (doesn't match HR).")
        print("  Candidates: cumulative daily steps, skin-temp raw ADC, SpO2 raw IR, or HRV SDNN×N.")
        print("  Next step: ground-truth by comparing to ring app's displayed values after a real session.")
