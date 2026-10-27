// A simulated strap, written from ZEPP_PROTOCOL.md for the tests. Its chunk parsing, chunk
// building, message encryption and session derivation are implemented HERE, independently of
// ZeppKit's transport, so a phone ⇄ device run checks the two sides against the spec rather than
// against themselves. It reuses only the primitives that have their own oracles: B163 (OpenSSL
// vectors), ZeppAES (NIST vectors) and ZeppCRC32 (check value).
//
// A library of its own (`ZeppKitTesting`, #215 phase 3) so the ZeppKit tests and the app's tests
// drive the same simulated strap: the app target compiles this one file into OpenCircuitTests
// (ios/project.yml), so it uses ZeppKit's PUBLIC API only. Test-only: nothing ships it.

import Foundation
import ZeppKit

public final class FakeZeppDevice {

    public struct Notification: Equatable {
        public let characteristic: ZeppCharacteristic
        public let bytes: [UInt8]
    }

    // Configuration
    public let authKey: [UInt8]
    public let privateKey: [UInt8]
    public let random: [UInt8]
    public var writeLength: Int
    public var services: [(endpoint: UInt16, flag: UInt8)] = [
        (0x0000, 0), (0x000A, 1), (0x0029, 1), (0x0043, 0), (0x0047, 0), (0x004B, 1), (0x0082, 0),
    ]
    public var batteryReply = hex("04 00 57 01 00 00 00 00 00 00 00 ea 07 09 1d 08 00 00 08 00 64")
    public var configReply: [UInt8] = hex("04 01 08 03 00 02 01 10 ff 13 0b 00")
    /// Fetch data per type: the start reply's first-record time bytes (8) and the data.
    public var fetchData: [ZeppFetchType: (start: [UInt8], data: [UInt8])] = [:]
    /// Data packet size (counter byte included).
    public var dataPacketLength = 20
    public var includeCRC = true
    public var corruptCRC = false
    public var skipPacketIndex: Int?
    public var refuseTypes: Set<ZeppFetchType> = []
    /// Start replies in the 16-byte form, with a trailing `00` (§6.2).
    public var startReplyTrailingZero = false
    /// An empty type answers with an all-zero start instead of echoing the *since* (§6.2).
    public var emptyStartAllZero = false
    /// The start reply's length field per type, instead of the real data's (a strap announcing more
    /// than it sends, e.g. a hostile 4 MiB round).
    public var announcedLengths: [ZeppFetchType: UInt32] = [:]
    /// Types whose ack (`03 xx`) the strap records but never answers with `10 03`, as if it stopped
    /// responding in the middle of a fetch.
    public var unansweredAckTypes: Set<ZeppFetchType> = []

    // Device controls (§11–§13). Only reachable when a test lists their endpoints in `services`.
    /// The find-device capabilities reply (§11.2); nil = the strap never answers `01`.
    public var findCapabilitiesReply: [UInt8]? = hex("02 01 02")
    /// Alarm slot → the 10-byte record as the strap returns it (byte [8] = 01, §12.3).
    public var alarmRecords: [UInt8: [UInt8]] = [:]
    /// Status byte of the alarm create/delete acks; anything but 01 leaves the alarms unchanged.
    public var alarmAckStatus: UInt8 = 0x01
    /// Send `0f` (alarms changed) after each accepted alarm write.
    public var announcesAlarmChanges = false
    public var configCapabilitiesReply = hex("02 03 01 08")
    /// The device-info reply (§5.3) to a `01` on 0x0043; nil = the strap never answers it.
    public var deviceInfoReply: [UInt8]?
    /// Config read replies by exact request payload; any other read gets `configReply`.
    public var configReplies: [[UInt8]: [UInt8]] = [:]
    /// Answers a config read before `configReplies` / `configReply` are consulted. nil = not handled
    /// (fall back to those); an EMPTY array = the strap stays silent, so the phone's read times out.
    public var configReadHandler: (([UInt8]) -> [UInt8]?)?
    /// Status byte of the config write ack (`06 <status>`); nil = the strap never acks a write.
    public var configWriteAckStatus: UInt8? = 0x01
    /// The status byte of the `06 <status> <enabled>` ack to `05 xx` on `0x0016`; nil = no ack.
    public var realtimeStepsAckStatus: UInt8? = 0x01
    /// Called with each config write BEFORE its ack goes out, so a test can make the strap's later
    /// reads reflect it (e.g. by replacing `configReplies`).
    public var onConfigWrite: (([UInt8]) -> Void)?

    // Observed state
    public private(set) var sessionKey: [UInt8]?
    public private(set) var authenticated = false
    public private(set) var receivedAcks: [[UInt8]] = []
    public private(set) var receivedEndpoints: [UInt16] = []
    public private(set) var fetchAcks: [UInt8] = []
    public private(set) var fetchStarts: [[UInt8]] = []
    public private(set) var failures: [String] = []
    /// Opcodes received on the find-device endpoint, in order.
    public private(set) var findOpcodes: [UInt8] = []
    public private(set) var isBuzzing = false
    /// Every payload received on the alarms endpoint, in order.
    public private(set) var alarmCommands: [[UInt8]] = []
    public private(set) var timeSetCount = 0
    public private(set) var configWrites: [[UInt8]] = []
    /// Every payload received on the realtime-steps endpoint `0x0016` (§7.2), in order.
    public private(set) var realtimeStepsCommands: [[UInt8]] = []
    /// Whether the realtime step stream is on (it persists across connections on a real strap, §16.2).
    public private(set) var realtimeStepsOn = false

    private var expectedPhoneSequence: UInt32 = 0
    private var deviceSequence: UInt32 = 0
    private var outgoingHandle: UInt8 = 0
    private var inbox: (endpoint: UInt16, handle: UInt8, encrypted: Bool, declared: Int, body: [UInt8], next: Int)?
    private var currentFetch: ZeppFetchType?

    public init(authKey: [UInt8], privateKey: [UInt8], random: [UInt8], writeLength: Int = 20) {
        self.authKey = authKey
        self.privateKey = privateKey
        self.random = random
        self.writeLength = writeLength
    }

    public var publicKey: [UInt8] { try! B163.publicKey(forPrivateKey: privateKey) }

    // MARK: Phone → device

    public func phoneWrote(_ write: ZeppWrite) -> [Notification] {
        switch write.characteristic {
        case .chunkedWrite: return receiveChunk(write.bytes)
        case .chunkedRead:
            receivedAcks.append(write.bytes)
            return []
        case .activityControl: return fetchControl(write.bytes)
        default:
            failures.append("write to \(write.characteristic)")
            return []
        }
    }

    private func receiveChunk(_ c: [UInt8]) -> [Notification] {
        guard c.count >= 5, c[0] == 0x03 else { failures.append("not a chunk"); return [] }
        let flags = c[1], handle = c[3], index = Int(c[4])
        if flags & 0x01 != 0 {
            guard c.count >= 11, index == 0 else { failures.append("bad first chunk"); return [] }
            let declared = Int(readLE32(c, 5))
            let endpoint = UInt16(c[9]) | (UInt16(c[10]) << 8)
            inbox = (endpoint, handle, flags & 0x08 != 0, declared, Array(c[11...]), 1)
        } else {
            guard var m = inbox, m.handle == handle, m.next == index else { failures.append("bad continuation"); return [] }
            m.body += c[5...]
            m.next += 1
            inbox = m
        }
        guard flags & 0x02 != 0, let m = inbox else { return [] }
        inbox = nil
        guard flags & 0x04 != 0 else { failures.append("last chunk without ack request"); return [] }
        var payload = m.body
        if m.encrypted {
            guard let key = sessionKey, m.body.count % 16 == 0 else { failures.append("cannot decrypt"); return [] }
            let plain = try! ZeppAES.decryptECB(key: key.map { $0 ^ handle }, m.body)
            payload = Array(plain[0..<m.declared])
            // The device checks the phone's trailer: S = its expected sequence, C = CRC32(P ‖ S).
            let s = readLE32(plain, m.declared)
            let crc = readLE32(plain, m.declared + 4)
            if s != expectedPhoneSequence { failures.append("phone sequence \(s) != \(expectedPhoneSequence)") }
            if crc != ZeppCRC32.checksum(plain[0..<(m.declared + 4)]) { failures.append("phone CRC wrong") }
            if plain[(m.declared + 8)...].contains(where: { $0 != 0 }) { failures.append("non-zero padding") }
            expectedPhoneSequence &+= 1
        } else if payload.count != m.declared {
            failures.append("plaintext length mismatch")
            return []
        }
        receivedEndpoints.append(m.endpoint)
        return handleMessage(endpoint: m.endpoint, payload)
    }

    private func handleMessage(endpoint: UInt16, _ p: [UInt8]) -> [Notification] {
        switch endpoint {
        case 0x0082 where p.first == 0x04:
            guard p.count == 52, Array(p[1..<4]) == [0x02, 0x00, 0x02] else { failures.append("bad 04"); return [] }
            let shared = try! B163.sharedSecret(privateKey: privateKey, peerPublicKey: Array(p[4...]))
            sessionKey = (0..<16).map { shared[8 + $0] ^ authKey[$0] }
            let seed = readLE32(shared, 0)
            expectedPhoneSequence = seed
            deviceSequence = seed
            return send(endpoint: 0x0082, [0x10, 0x04, 0x01] + random + publicKey)
        case 0x0082 where p.first == 0x05:
            guard p.count == 33, let key = sessionKey else { failures.append("bad 05"); return [] }
            let ok = Array(p[1..<17]) == (try! ZeppAES.encryptECB(key: authKey, random))
                && Array(p[17..<33]) == (try! ZeppAES.encryptECB(key: key, random))
            authenticated = ok
            return send(endpoint: 0x0082, [0x10, 0x05, ok ? 0x01 : 0x25])
        case 0x0000 where p == [0x03]:
            var reply: [UInt8] = [0x04, UInt8(services.count), 0x00]
            for s in services { reply += [UInt8(s.endpoint & 0xFF), UInt8(s.endpoint >> 8), s.flag] }
            return send(endpoint: 0x0000, reply)
        case 0x0029 where p == [0x03]:
            return send(endpoint: 0x0029, batteryReply)
        case 0x000A where p.first == 0x03:
            if let handled = configReadHandler?(p) {
                return handled.isEmpty ? [] : send(endpoint: 0x000A, handled)
            }
            return send(endpoint: 0x000A, configReplies[p] ?? configReply)
        case 0x000A where p == [0x01]:
            return send(endpoint: 0x000A, configCapabilitiesReply)
        case 0x000A where p.first == 0x05:
            configWrites.append(p)
            onConfigWrite?(p)
            return configWriteAckStatus.map { send(endpoint: 0x000A, [0x06, $0]) } ?? []
        case 0x0047 where p.first == 0x05:
            guard p.count == 12 else { failures.append("bad time set"); return [] }
            timeSetCount += 1
            return send(endpoint: 0x0047, [0x06, 0x01])
        case 0x0043 where p == [0x01]:
            guard let reply = deviceInfoReply else { failures.append("unhandled message on 67"); return [] }
            return send(endpoint: 0x0043, reply)
        case 0x0016 where p.count == 2 && p[0] == 0x05 && p[1] <= 0x01:
            realtimeStepsCommands.append(p)
            realtimeStepsOn = p[1] == 0x01
            return realtimeStepsAckStatus.map { send(endpoint: 0x0016, [0x06, $0, p[1]]) } ?? []
        case 0x001A:
            return findDevice(p)
        case 0x000F:
            return alarms(p)
        default:
            failures.append("unhandled message on \(endpoint)")
            return []
        }
    }

    // MARK: Device controls (§11, §12)

    private func findDevice(_ p: [UInt8]) -> [Notification] {
        guard let opcode = p.first, p.count == 1 || p == [0x12, 0x01] else {
            failures.append("bad find-device payload \(p)")
            return []
        }
        findOpcodes.append(opcode)
        switch opcode {
        case 0x01: return findCapabilitiesReply.map { send(endpoint: 0x001A, $0) } ?? []
        case 0x03:
            isBuzzing = true
            return send(endpoint: 0x001A, [0x04])
        case 0x06:
            isBuzzing = false
            return []
        case 0x12, 0x14: return []
        default:
            failures.append("find-device opcode \(opcode) is never sent by a phone")
            return []
        }
    }

    private func alarms(_ p: [UInt8]) -> [Notification] {
        alarmCommands.append(p)
        var out = [Notification]()
        switch p.first {
        case 0x09 where p.count == 1:
            var reply: [UInt8] = [0x0a, UInt8(alarmRecords.count)]
            for slot in alarmRecords.keys.sorted() { reply += alarmRecords[slot]! }
            return send(endpoint: 0x000F, reply)
        case 0x03 where p.count == 12 && p[1] == 0x01:
            var record = Array(p[2...])
            guard record[1] < 10 else { failures.append("alarm slot \(record[1])"); return [] }
            record[8] = 0x01
            if alarmAckStatus == 0x01 { alarmRecords[record[1]] = record }
            out = send(endpoint: 0x000F, [0x04, alarmAckStatus])
        case 0x05 where p.count == 3 && p[1] == 0x01:
            if alarmAckStatus == 0x01 { alarmRecords[p[2]] = nil }
            out = send(endpoint: 0x000F, [0x06, alarmAckStatus])
        default:
            failures.append("alarm command \(p) is never sent by ZeppKit")
            return []
        }
        if announcesAlarmChanges && alarmAckStatus == 0x01 { out += send(endpoint: 0x000F, [0x0f]) }
        return out
    }

    /// A realtime step frame (§16.2 row 5): `07` + 13 bytes, the counter as u16 LE at offset 1 of the 13.
    public func stepFrame(_ counter: UInt16) -> [Notification] {
        var body = [UInt8](repeating: 0, count: 13)
        body[1] = UInt8(counter & 0xff)
        body[2] = UInt8(counter >> 8)
        return send(endpoint: 0x0016, [0x07] + body)
    }

    /// A strap-originated message (find device `07`, find phone `11`, alarms changed `0f`, …).
    public func unsolicited(endpoint: UInt16, _ payload: [UInt8]) -> [Notification] {
        send(endpoint: endpoint, payload)
    }

    // MARK: Device → phone

    private func isEncrypted(_ endpoint: UInt16) -> Bool {
        authenticated && services.first { $0.endpoint == endpoint }?.flag == 1
    }

    private func send(endpoint: UInt16, _ payload: [UInt8]) -> [Notification] {
        outgoingHandle &+= 1
        let handle = outgoingHandle
        let encrypted = isEncrypted(endpoint)
        var body = payload
        if encrypted, let key = sessionKey {
            var buffer = payload + le32(deviceSequence)
            buffer += le32(ZeppCRC32.checksum(buffer))
            while buffer.count % 16 != 0 { buffer.append(0) }
            body = try! ZeppAES.encryptECB(key: key.map { $0 ^ handle }, buffer)
            deviceSequence &+= 1
        }
        var out = [Notification]()
        var offset = 0
        var index = 0
        repeat {
            let first = index == 0
            let room = writeLength - (first ? 11 : 5)
            let take = min(room, body.count - offset)
            let last = offset + take == body.count
            let flags: UInt8 = (first ? 0x01 : 0) | (last ? 0x06 : 0) | (encrypted ? 0x08 : 0)
            var chunk: [UInt8] = [0x03, flags, 0x00, handle, UInt8(index)]
            if first { chunk += le32(UInt32(payload.count)) + le16(endpoint) }
            chunk += body[offset..<(offset + take)]
            out.append(Notification(characteristic: .chunkedRead, bytes: chunk))
            offset += take
            index += 1
        } while offset < body.count
        return out
    }

    // MARK: History fetch, Path A

    private func fetchControl(_ c: [UInt8]) -> [Notification] {
        func control(_ bytes: [UInt8]) -> Notification { Notification(characteristic: .activityControl, bytes: bytes) }
        switch c.first {
        case 0x01:
            fetchStarts.append(c)
            guard c.count == 10, let type = ZeppFetchType(rawValue: c[1]) else { return [control([0x10, 0x01, 0x02])] }
            if refuseTypes.contains(type) { return [control([0x10, 0x01, 0x04])] }
            currentFetch = type
            let emptyStart = emptyStartAllZero ? [UInt8](repeating: 0, count: 8) : Array(c[2..<10])
            let entry = fetchData[type] ?? (start: emptyStart, data: [])
            // Activity announces 8-byte records, every other type bytes (§6.2).
            let length = announcedLengths[type].map(Int.init) ?? (type == .activity ? entry.data.count / 8 : entry.data.count)
            let trailer: [UInt8] = startReplyTrailingZero ? [0x00] : []
            return [control([0x10, 0x01, 0x01] + le32(UInt32(length)) + entry.start + trailer)]
        case 0x02:
            guard let type = currentFetch else { return [] }
            let data = fetchData[type]?.data ?? []
            var out = [Notification]()
            var counter: UInt8 = 0
            var index = 0
            var offset = 0
            while offset < data.count {
                let take = min(dataPacketLength - 1, data.count - offset)
                if index != skipPacketIndex {
                    out.append(Notification(characteristic: .activityData, bytes: [counter] + data[offset..<(offset + take)]))
                }
                counter &+= 1
                index += 1
                offset += take
            }
            var crc = ZeppCRC32.checksum(data)
            if corruptCRC { crc ^= 1 }
            out.append(control([0x10, 0x02, 0x01] + (includeCRC ? le32(crc) : [])))
            return out
        case 0x03:
            guard c.count == 2 else { return [] }
            fetchAcks.append(c[1])
            let acked = currentFetch
            currentFetch = nil
            if let acked, unansweredAckTypes.contains(acked) { return [] }
            return [control([0x10, 0x03, 0x01])]
        default:
            return []
        }
    }
}

/// Shuttles bytes between a `ZeppLink` and a `FakeZeppDevice` until nothing more happens.
public func pump(_ link: inout ZeppLink, _ device: FakeZeppDevice, _ writes: [ZeppWrite]) -> [ZeppLink.Event] {
    var pending = writes
    var events = [ZeppLink.Event]()
    var guardCount = 0
    while !pending.isEmpty, guardCount < 10_000 {
        guardCount += 1
        let write = pending.removeFirst()
        for n in device.phoneWrote(write) where n.characteristic == .chunkedRead || n.characteristic == .chunkedWrite {
            let out = link.receive(n.bytes)
            pending += out.writes
            events += out.events
        }
    }
    return events
}

// MARK: - Byte helpers (file-private: the test targets keep their own)

private func hex(_ text: String) -> [UInt8] {
    guard let bytes = ZeppHex.bytes(text) else { fatalError("bad hex fixture: \(text)") }
    return bytes
}

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

/// u32 little-endian at `offset`, assembled in a loop (a long shift-or chain times out the
/// type-checker on this project's CI host).
private func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for i in 0..<4 {
        let byte = UInt32(bytes[offset + i])
        value |= byte << UInt32(8 * i)
    }
    return value
}
