"""Frame-decoding helpers: checksum brute-forcer and metric decoders.

Use these on captured frames to discover the trailer checksum and to validate
metric byte layouts before committing them to docs/PROTOCOL.md.
"""

from __future__ import annotations


def _reflect(value: int, width: int) -> int:
    out = 0
    for i in range(width):
        if value & (1 << i):
            out |= 1 << (width - 1 - i)
    return out


def crc(data: bytes, width: int, poly: int, init: int,
        refin: bool, refout: bool, xorout: int) -> int:
    """Generic bitwise CRC for width in {8, 16, 32}."""
    topbit = 1 << (width - 1)
    mask = (1 << width) - 1
    reg = init
    for byte in data:
        if refin:
            byte = _reflect(byte, 8)
        reg ^= byte << (width - 8)
        for _ in range(8):
            reg = ((reg << 1) ^ poly) if (reg & topbit) else (reg << 1)
            reg &= mask
    if refout:
        reg = _reflect(reg, width)
    return reg ^ xorout


# A spread of common parameter sets, incl. openwhoop's Whoop CRC-32 poly.
_CANDIDATES = [
    ("CRC-8",            8,  0x07,       0x00,       False, False, 0x00),
    ("CRC-8/MAXIM",      8,  0x31,       0x00,       True,  True,  0x00),
    ("CRC-16/CCITT-F",   16, 0x1021,     0xFFFF,     False, False, 0x0000),
    ("CRC-16/XMODEM",    16, 0x1021,     0x0000,     False, False, 0x0000),
    ("CRC-16/MODBUS",    16, 0x8005,     0xFFFF,     True,  True,  0x0000),
    ("CRC-16/ARC",       16, 0x8005,     0x0000,     True,  True,  0x0000),
    ("CRC-32",           32, 0x04C11DB7, 0xFFFFFFFF, True,  True,  0xFFFFFFFF),
    ("CRC-32/MPEG-2",    32, 0x04C11DB7, 0xFFFFFFFF, False, False, 0x00000000),
    ("CRC-32/WHOOP",     32, 0x04C11DB7, 0x00000000, False, False, 0x00000000),
]


def guess_checksum(frame: bytes, trailer_len: int | None = None) -> None:
    """Try common CRCs over frame[:-N] and report which match the last N bytes.

    If trailer_len is None, tries 1, 2, and 4-byte trailers.
    """
    print(f"frame ({len(frame)}B): {frame.hex(' ')}\n")
    widths = {1: 8, 2: 16, 4: 32}
    tlens = [trailer_len] if trailer_len else [1, 2, 4]
    hits = 0
    for tlen in tlens:
        if len(frame) <= tlen:
            continue
        body, trailer = frame[:-tlen], frame[-tlen:]
        for name, width, poly, init, refin, refout, xorout in _CANDIDATES:
            if widths.get(tlen) != width:
                continue
            val = crc(body, width, poly, init, refin, refout, xorout)
            for order in ("little", "big"):
                if val.to_bytes(tlen, order) == trailer:
                    print(f"  MATCH  {name:<16} trailer={tlen}B {order}-endian "
                          f"= 0x{val:0{tlen*2}x}")
                    hits += 1
    if not hits:
        print("  no match — trailer may not be a standard CRC, or body range is "
              "wrong (try excluding a header byte, or include/exclude the opcode).")


def decode_live_hr(payload: bytes) -> int | None:
    """Best-known decode of the live-HR notification (handle 0x0804).

    Observation (🟡): a 7-bit field holds BPM (e.g. 0b1001100 = 76). The exact
    byte offset is unconfirmed — this assumes the HR is the low 7 bits of the
    last byte. Adjust once captures pin it down.
    """
    if not payload:
        return None
    return payload[-1] & 0x7F
