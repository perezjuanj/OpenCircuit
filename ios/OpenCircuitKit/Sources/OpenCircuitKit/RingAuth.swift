// RingConn per-connection auth — the "activation" handshake (PROTOCOL.md §5.8, issue #54).
//
// 🟢 Reverse-engineered 2026-06-16 from the official app's Dart AOT (`libapp.so`, disassembled
// after blutter-decompiling the v3.2.1 build) and VERIFIED against 24 captured challenge→response
// pairs + the canonical SM3 test vector. The ring will not stream data until it receives a correct
// auth response each connection; this is what previously required opening the official app.
//
// Sequence every connect: host `01 00 00` → ring `81 00 <challenge> <xor>`; host must reply
//   `01 01 <r0> <r1> <r2> 00`   where (r0,r1,r2) = SM3( [V, challenge] )[29..31]   (last 3 bytes)
//   and  V = mac[3] ^ mac[4] ^ mac[5]   (XOR of the ring's last 3 BLE-MAC bytes).
//
// The only key material is the ring's own MAC (no cloud key, no app secret), so this is computable
// offline for any RingConn. iOS can't read the MAC via CoreBluetooth, but the ring exposes it via
// the Device Information System ID characteristic (0x2a23, §1) — see `macFromSystemID`.

import Foundation

public enum RingAuth {

    /// Build the `01 01 …` auth response for a ring challenge, given the ring's 6-byte MAC.
    public static func authCommand(challenge: UInt8, mac: [UInt8]) -> [UInt8] {
        let r = response(challenge: challenge, mac: mac)
        return [0x01, 0x01, r[0], r[1], r[2], 0x00]
    }

    /// The 3 response bytes = last 3 bytes of SM3([V, challenge]), V = XOR of the last 3 MAC bytes.
    public static func response(challenge: UInt8, mac: [UInt8]) -> [UInt8] {
        let v = macTailXor(mac)
        let digest = SM3.hash([v, challenge])
        return Array(digest.suffix(3))
    }

    /// V = mac[3] ^ mac[4] ^ mac[5] (XOR of the 3 least-significant / NIC MAC bytes). Returns 0 for
    /// a short array (caller should not auth without a real MAC).
    public static func macTailXor(_ mac: [UInt8]) -> UInt8 {
        guard mac.count >= 6 else { return 0 }
        return mac[3] ^ mac[4] ^ mac[5]
    }

    /// Extract the 6-byte MAC from a Device-Information System ID (0x2a23) value. The BLE System ID
    /// is an 8-byte EUI-64: OUI(3) + `FF FE` + NIC(3), but vendors/stacks may store it reversed, so
    /// we normalise both. Returns nil if we can't recognise a layout. (iOS-only path — CoreBluetooth
    /// hides the raw MAC; this characteristic is how we recover it.)
    public static func macFromSystemID(_ sysid: [UInt8]) -> [UInt8]? {
        // 8-byte EUI-64 with the FF FE marker in the middle (forward order).
        if sysid.count == 8, sysid[3] == 0xFF, sysid[4] == 0xFE {
            return [sysid[0], sysid[1], sysid[2], sysid[5], sysid[6], sysid[7]]
        }
        // Reversed EUI-64 (FF FE in the middle, counting from the end).
        if sysid.count == 8, sysid[4] == 0xFE, sysid[3] == 0xFF {
            return [sysid[0], sysid[1], sysid[2], sysid[5], sysid[6], sysid[7]]
        }
        if sysid.count == 8 {
            let rev = Array(sysid.reversed())
            if rev[3] == 0xFF, rev[4] == 0xFE {
                return [rev[0], rev[1], rev[2], rev[5], rev[6], rev[7]]
            }
        }
        // Raw 6-byte MAC, or take the trailing 6 bytes as a last resort.
        if sysid.count == 6 { return sysid }
        if sysid.count > 6 { return Array(sysid.suffix(6)) }
        return nil
    }
}

/// SM3 — the Chinese national 256-bit cryptographic hash (GB/T 32905-2016). Self-contained; the
/// only crypto OpenCircuit needs (the RingConn auth uses SM3, not SHA/MD5). Verified against the
/// `SM3("abc")` KAT in tests.
public enum SM3 {
    private static let IV: [UInt32] = [
        0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
        0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
    ]

    @inline(__always) private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        let n = n & 31
        return n == 0 ? x : (x << n) | (x >> (32 - n))
    }
    @inline(__always) private static func T(_ j: Int) -> UInt32 { j < 16 ? 0x79cc4519 : 0x7a879d8a }
    @inline(__always) private static func FF(_ x: UInt32, _ y: UInt32, _ z: UInt32, _ j: Int) -> UInt32 {
        j < 16 ? (x ^ y ^ z) : ((x & y) | (x & z) | (y & z))
    }
    @inline(__always) private static func GG(_ x: UInt32, _ y: UInt32, _ z: UInt32, _ j: Int) -> UInt32 {
        j < 16 ? (x ^ y ^ z) : ((x & y) | (~x & z))
    }
    @inline(__always) private static func P0(_ x: UInt32) -> UInt32 { x ^ rotl(x, 9) ^ rotl(x, 17) }
    @inline(__always) private static func P1(_ x: UInt32) -> UInt32 { x ^ rotl(x, 15) ^ rotl(x, 23) }

    public static func hash(_ input: [UInt8]) -> [UInt8] {
        var msg = input
        let bitLen = UInt64(input.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((bitLen >> UInt64(i)) & 0xff)) }

        var V = IV
        var blk = 0
        while blk < msg.count {
            var W = [UInt32](repeating: 0, count: 68)
            for j in 0..<16 {
                let o = blk + j * 4
                W[j] = (UInt32(msg[o]) << 24) | (UInt32(msg[o+1]) << 16) | (UInt32(msg[o+2]) << 8) | UInt32(msg[o+3])
            }
            for j in 16..<68 {
                W[j] = P1(W[j-16] ^ W[j-9] ^ rotl(W[j-3], 15)) ^ rotl(W[j-13], 7) ^ W[j-6]
            }
            var W1 = [UInt32](repeating: 0, count: 64)
            for j in 0..<64 { W1[j] = W[j] ^ W[j+4] }

            var a = V[0], b = V[1], c = V[2], d = V[3], e = V[4], f = V[5], g = V[6], h = V[7]
            for j in 0..<64 {
                let ss1 = rotl((rotl(a, 12) &+ e &+ rotl(T(j), UInt32(j % 32))) & 0xffffffff, 7)
                let ss2 = ss1 ^ rotl(a, 12)
                let tt1 = (FF(a, b, c, j) &+ d &+ ss2 &+ W1[j]) & 0xffffffff
                let tt2 = (GG(e, f, g, j) &+ h &+ ss1 &+ W[j]) & 0xffffffff
                d = c; c = rotl(b, 9); b = a; a = tt1
                h = g; g = rotl(f, 19); f = e; e = P0(tt2)
            }
            V[0] ^= a; V[1] ^= b; V[2] ^= c; V[3] ^= d; V[4] ^= e; V[5] ^= f; V[6] ^= g; V[7] ^= h
            blk += 64
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in V {
            out.append(UInt8((word >> 24) & 0xff)); out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff));  out.append(UInt8(word & 0xff))
        }
        return out
    }
}
