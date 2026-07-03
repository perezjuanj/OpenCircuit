"""RingConn per-connection auth — Python port of OpenCircuit's RingAuth.swift + SM3.

MAC is read from the Device Information System ID characteristic (0x2A23), the only
reliable way to get the 6-byte BLE MAC on macOS/iOS (CoreBluetooth hides the raw addr).

Auth sequence every connection:
  host  01 00 00          ->  ring  81 00 <challenge_byte> <xor>
  host  01 01 r0 r1 r2 00       where [r0,r1,r2] = SM3([V, challenge])[-3:]
                                 and  V = mac[3] ^ mac[4] ^ mac[5]

Verified against 24 captured challenge/response pairs (from OpenCircuit project).
SM3 verified against the official GB/T 32905-2016 KAT: SM3(b"abc") test vector.
"""
from __future__ import annotations
from typing import Optional


# ── SM3 (GB/T 32905-2016) ────────────────────────────────────────────────────

_IV = [
    0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
    0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
]
_MASK32 = 0xFFFFFFFF


def _rotl32(x: int, n: int) -> int:
    n &= 31
    return ((x << n) | (x >> (32 - n))) & _MASK32 if n else x


def _T(j: int) -> int:
    return 0x79cc4519 if j < 16 else 0x7a879d8a


def _FF(x: int, y: int, z: int, j: int) -> int:
    return (x ^ y ^ z) if j < 16 else ((x & y) | (x & z) | (y & z))


def _GG(x: int, y: int, z: int, j: int) -> int:
    return (x ^ y ^ z) if j < 16 else ((x & y) | ((~x & _MASK32) & z))


def _P0(x: int) -> int:
    return (x ^ _rotl32(x, 9) ^ _rotl32(x, 17)) & _MASK32


def _P1(x: int) -> int:
    return (x ^ _rotl32(x, 15) ^ _rotl32(x, 23)) & _MASK32


def sm3(data: bytes | list[int]) -> bytes:
    """Return the 32-byte SM3 digest of `data`."""
    msg = bytearray(data)
    bit_len = len(msg) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    for shift in range(56, -1, -8):
        msg.append((bit_len >> shift) & 0xFF)

    V = list(_IV)
    for blk in range(0, len(msg), 64):
        chunk = msg[blk:blk + 64]
        W = [int.from_bytes(chunk[j*4:j*4+4], "big") for j in range(16)] + [0] * 52
        for j in range(16, 68):
            W[j] = (_P1(W[j-16] ^ W[j-9] ^ _rotl32(W[j-3], 15))
                    ^ _rotl32(W[j-13], 7) ^ W[j-6]) & _MASK32
        W1 = [(W[j] ^ W[j+4]) & _MASK32 for j in range(64)]

        a, b, c, d, e, f, g, h = V
        for j in range(64):
            ss1 = _rotl32((_rotl32(a, 12) + e + _rotl32(_T(j), j % 32)) & _MASK32, 7)
            ss2 = (ss1 ^ _rotl32(a, 12)) & _MASK32
            tt1 = (_FF(a, b, c, j) + d + ss2 + W1[j]) & _MASK32
            tt2 = (_GG(e, f, g, j) + h + ss1 + W[j]) & _MASK32
            d, c, b, a = c, _rotl32(b, 9), a, tt1
            h, g, f, e = g, _rotl32(f, 19), e, _P0(tt2)
        V = [(V[i] ^ x) & _MASK32 for i, x in enumerate([a, b, c, d, e, f, g, h])]

    return b"".join(w.to_bytes(4, "big") for w in V)


# ── MAC extraction ────────────────────────────────────────────────────────────

# GATT Device Information characteristic: System ID (EUI-64, 8 bytes).
SYSID_CHAR = "00002a23-0000-1000-8000-00805f9b34fb"


def mac_from_sysid(sysid: bytes) -> Optional[list[int]]:
    """Decode a 6-byte MAC from an 8-byte System ID EUI-64 (or raw 6-byte blob).

    Returns None if the format isn't recognisable.
    """
    b = list(sysid)
    if len(b) == 8:
        # Forward EUI-64: OUI(3) FF FE NIC(3)
        if b[3] == 0xFF and b[4] == 0xFE:
            return [b[0], b[1], b[2], b[5], b[6], b[7]]
        # Reversed EUI-64
        r = list(reversed(b))
        if r[3] == 0xFF and r[4] == 0xFE:
            return [r[0], r[1], r[2], r[5], r[6], r[7]]
        # Unrecognised 8-byte: take trailing 6 as fallback
        return b[2:]
    if len(b) == 6:
        return b
    if len(b) > 6:
        return b[-6:]
    return None


# ── RingAuth ──────────────────────────────────────────────────────────────────

def mac_tail_xor(mac: list[int]) -> int:
    """V = mac[3] ^ mac[4] ^ mac[5]."""
    return mac[3] ^ mac[4] ^ mac[5]


def auth_response(challenge: int, mac: list[int]) -> bytes:
    """Return the 3-byte auth response = SM3([V, challenge])[-3:]."""
    v = mac_tail_xor(mac)
    digest = sm3(bytes([v, challenge]))
    return digest[-3:]


def auth_command(challenge: int, mac: list[int]) -> bytes:
    """Full `01 01 r0 r1 r2 00` auth frame."""
    r = auth_response(challenge, mac)
    return bytes([0x01, 0x01, r[0], r[1], r[2], 0x00])


# ── Self-test ─────────────────────────────────────────────────────────────────
_SM3_ABC_EXPECTED = bytes.fromhex(
    "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
)

if __name__ == "__main__":
    got = sm3(b"abc")
    ok = "PASS" if got == _SM3_ABC_EXPECTED else "FAIL"
    print(f"SM3('abc') KAT: {ok}")
    print(f"  got:      {got.hex()}")
    print(f"  expected: {_SM3_ABC_EXPECTED.hex()}")
